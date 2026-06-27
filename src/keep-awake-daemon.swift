// keep-awake-daemon: single-process replacement for caffeinate + clamshell override.
// - IOPMAssertion: prevents idle sleep (display + system)
// - IOKit selector 12 (kPMSetClamshellSleepState): prevents lid-close sleep
// - Polls AppleClamshellState (1 Hz), plays sounds on lid open/close
// - Cleans up on SIGTERM/SIGINT/SIGHUP/exit
//
// Apple Silicon + macOS Sequoia tested. No root, no entitlements.
// Errors are logged, never fatal.

import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import CoreGraphics
import Network

let LOG_PATH = "/tmp/keep-awake-daemon.log"
let SOUND_CLOSE = "/System/Library/Sounds/Bottle.aiff"
let SOUND_OPEN  = "/System/Library/Sounds/Submarine.aiff"
let kPMSetClamshellSleepState: UInt32 = 12

let STATE_DIR = ProcessInfo.processInfo.environment["KEEP_AWAKE_STATE_DIR"]
    ?? "\(NSHomeDirectory())/.claude/keep-awake-state"
let SESSIONS_DIR = "\(STATE_DIR)/sessions"
// pause-awake.sh writes paused/<PID> when a session is blocked waiting for the
// user (permission prompt, AskUserQuestion, plan approval). keep-awake.sh
// removes it on the next hook. A session is "active" only if it has no marker.
let PAUSED_DIR = "\(STATE_DIR)/paused"
// A session PID is honored only while it remains a process of this name. Guards
// against PID reuse: a recycled PID passes kill(0) but is no longer claude.
// Overridable (KEEP_AWAKE_PROC_NAME) for tests and non-native installs.
let SESSION_PROC_NAME = ProcessInfo.processInfo.environment["KEEP_AWAKE_PROC_NAME"] ?? "claude"
let DAEMON_PID_FILE = "\(STATE_DIR)/daemon.pid"
let LID_UNSAFE_FILE = "\(STATE_DIR)/lid-unsafe-until"
let EMPTY_GRACE_SEC: TimeInterval = 300  // exit after 5 min with no sessions
// keep-awake.sh rewrites sessions/<pid> on every UserPromptSubmit/PostToolUse.
// If the newest session file goes untouched this long, the CLI is alive but
// hung (no hooks firing) — release the machine rather than hold it awake forever.
let HOOK_IDLE_LIMIT: TimeInterval = 7200  // 2h
// AC plug-in on Apple Silicon causes a brief forced sleep (kernel bug, no userspace fix).
// Mark the lid as unsafe-to-close for this window so a statusline can warn the user.
let UNSAFE_LID_WINDOW_SEC: TimeInterval = 20
// Claude can't reach the API without internet, so holding sleep-prevention is wasted
// once the route goes away. Wait this long before releasing — survives brief flaps
// (Wi-Fi roam, captive-portal reauth) without thrashing assertions.
let NETWORK_GRACE_SEC: TimeInterval = 30

// ---------- logging ----------
let logFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func log(_ msg: String) {
    let line = "[\(logFmt.string(from: Date())) pid \(getpid())] \(msg)\n"
    let data = line.data(using: .utf8)!
    if let h = FileHandle(forWritingAtPath: LOG_PATH) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        FileManager.default.createFile(atPath: LOG_PATH, contents: data)
    }
    FileHandle.standardError.write(data)
}

// ---------- state ----------
var assertionIDs: [IOPMAssertionID] = []
var pmConnection: io_connect_t = 0
var pmService: io_service_t = 0
// True while we hold sleep-prevention (assertions + clamshell + sleep veto).
// Starts true: main() acquires immediately. Flipped off when every live
// session is paused, back on when any session resumes.
var assertionsHeld = true

// ---------- IOPMAssertion (replaces caffeinate -dis) ----------
func createAssertions() {
    let types: [(CFString, String)] = [
        (kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, "PreventUserIdleSystemSleep"),
        (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, "PreventUserIdleDisplaySleep"),
        (kIOPMAssertionTypePreventSystemSleep as CFString, "PreventSystemSleep")
    ]
    for (type, name) in types {
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "keep-awake-daemon" as CFString,
            &id
        )
        if r == kIOReturnSuccess {
            assertionIDs.append(id)
            log("assertion \(name): ok (id=\(id))")
        } else {
            log("assertion \(name): err 0x\(String(r, radix: 16))")
        }
    }
}

func releaseAssertions() {
    for id in assertionIDs {
        IOPMAssertionRelease(id)
    }
    assertionIDs.removeAll()
}

// ---------- selector 12 ----------
func setClamshellSleep(disable: Bool) {
    if pmConnection == 0 {
        pmService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard pmService != 0 else { log("clamshell: no IOPMrootDomain"); return }
        let kr = IOServiceOpen(pmService, mach_task_self_, 0, &pmConnection)
        guard kr == KERN_SUCCESS else {
            log("clamshell: IOServiceOpen err 0x\(String(kr, radix: 16))")
            IOObjectRelease(pmService); pmService = 0
            return
        }
    }
    var input: UInt64 = disable ? 1 : 0
    let r = IOConnectCallScalarMethod(pmConnection, kPMSetClamshellSleepState, &input, 1, nil, nil)
    log("clamshell disable=\(disable): \(r == kIOReturnSuccess ? "ok" : "err 0x\(String(r, radix: 16))")")
}

func closeClamshellHandles() {
    if pmConnection != 0 { IOServiceClose(pmConnection); pmConnection = 0 }
    if pmService != 0 { IOObjectRelease(pmService); pmService = 0 }
}

// On Apple Silicon, the dark-wake → full-wake cycle that follows an AC plug/unplug
// invalidates the clamshell-disable flag (Apple's pmconfigd preserves it across dark
// wakes but re-evaluates on full wake). Re-apply assertions and selector 12 on AC↔battery
// edges, on system wake, and on a slow heartbeat as a safety net.
func reapplyPower() {
    log("re-applying power assertions and clamshell flag")
    releaseAssertions()
    createAssertions()
    setClamshellSleep(disable: true)
}

// ---------- network availability ----------
// Optimistic default at boot: NWPathMonitor fires its first callback within
// milliseconds of start(), so a real `false` overrides this almost immediately;
// the `true` default just avoids a release→reacquire flicker on cold start.
// Mutated only on the main queue (network handler dispatches there).
var networkPathSatisfied: Bool = true
var networkLostSince: Date? = nil
var pathMonitor: NWPathMonitor? = nil

// Available iff currently satisfied OR the unsatisfied-for window hasn't elapsed.
// Lazy grace: no separate timer — pollTimer's 1 Hz updateHold() picks up the
// expiry edge within ≤1 s.
func isNetworkAvailable() -> Bool {
    if networkPathSatisfied { return true }
    guard let since = networkLostSince else { return true }
    return Date().timeIntervalSince(since) < NETWORK_GRACE_SEC
}

// A PID counts as a live session only if it's still a SESSION_PROC_NAME process.
// A bare kill(pid,0) also passes after the OS recycles a dead session's PID to an
// unrelated process (observed: AudioComponentRegistrar), which would pin the
// daemon forever — and since bash hooks only run while a real session is active,
// the daemon itself must reject the phantom.
//
// Identity is `ps -o comm=` (argv[0]), matching the bash hooks' check exactly so
// there is one definition of "a claude process". proc_name()/p_comm is unusable:
// the claude CLI overwrites p_comm with its version (e.g. "2.1.193"), which never
// equals SESSION_PROC_NAME, so the daemon self-exited while real sessions ran.
func pidIsClaude(_ pid: pid_t) -> Bool {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-p", "\(pid)", "-o", "comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let comm = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return comm == SESSION_PROC_NAME || comm.hasSuffix("/\(SESSION_PROC_NAME)")
}

// ---------- per-session pause ----------
// A session is active iff its PID is alive AND it has no paused/<PID> marker.
// Session filename == PID string (keep-awake.sh); marker filename matches.
func hasActiveSession() -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: SESSIONS_DIR)) ?? []
    for f in files {
        guard let content = try? String(contentsOfFile: "\(SESSIONS_DIR)/\(f)", encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if kill(pid, 0) != 0 || !pidIsClaude(pid) { continue }                      // dead or PID reused
        if FileManager.default.fileExists(atPath: "\(PAUSED_DIR)/\(f)") { continue } // paused
        return true
    }
    return false
}

// Hold sleep-prevention iff some session is working AND the route is up
// (or within the offline grace). Releasing also drops the active sleep veto
// (see kIOMessageCanSystemSleep_raw) so the OS may sleep.
func updateHold() {
    let activeSession = hasActiveSession()
    let netUp = isNetworkAvailable()
    let want = activeSession && netUp
    if want == assertionsHeld { return }
    assertionsHeld = want
    if want {
        log("hold acquired (session active, network up) → re-acquiring")
        reapplyPower()
    } else {
        let reason = !activeSession ? "all sessions paused" : "network offline >\(Int(NETWORK_GRACE_SEC))s"
        log("\(reason) → releasing")
        releaseAssertions()
        setClamshellSleep(disable: false)
    }
}

// ---------- AC plug-in detection (for "unsafe lid" statusline countdown) ----------
var wasOnAC: Bool = false

func isOnAC() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
    guard let typeCF = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (typeCF as String) == kIOPSACPowerValue
}

func markLidUnsafe() {
    let until = Int(Date().timeIntervalSince1970 + UNSAFE_LID_WINDOW_SEC)
    do {
        try "\(until)\n".write(toFile: LID_UNSAFE_FILE, atomically: true, encoding: .utf8)
        log("AC plugged → marking lid unsafe until \(until) (\(Int(UNSAFE_LID_WINDOW_SEC))s)")
    } catch {
        log("markLidUnsafe write err: \(error)")
    }
}

func clearLidUnsafe() {
    guard FileManager.default.fileExists(atPath: LID_UNSAFE_FILE) else { return }
    try? FileManager.default.removeItem(atPath: LID_UNSAFE_FILE)
    log("lid unsafe cleared (wake completed)")
}

// IOPS callback wrapper: detect plug-in edge, mark unsafe, then re-apply state.
func handlePowerSourceChange() {
    let cur = isOnAC()
    if cur && !wasOnAC {
        markLidUnsafe()
    }
    wasOnAC = cur
    if assertionsHeld { reapplyPower() }
}

// ---------- IORegisterForSystemPower (active sleep veto) ----------
// Catches CanSystemSleep (we can refuse) and SystemHasPoweredOn (re-apply state after
// a full wake — covers the AC-plug dark-wake race that IOPS misses).
// Message constants are #define macros not exported to Swift — use raw values.
// iokit_common_msg(0xNNN) = 0xE0000000 | 0xNNN.
let kIOMessageCanSystemSleep_raw: UInt32 = 0xE0000270
let kIOMessageSystemWillSleep_raw: UInt32 = 0xE0000280
let kIOMessageSystemHasPoweredOn_raw: UInt32 = 0xE0000300

var rootPowerPort: io_connect_t = 0
var rootPowerNotifier: io_object_t = 0
var rootPowerNotifyPort: IONotificationPortRef? = nil

let systemPowerCallback: IOServiceInterestCallback = { _, _, messageType, argument in
    let arg = Int(bitPattern: argument)
    switch messageType {
    case kIOMessageCanSystemSleep_raw:
        if assertionsHeld {
            log("system asking permission to sleep → cancel")
            IOCancelPowerChange(rootPowerPort, arg)
            reapplyPower()
        } else {
            log("system asking permission to sleep → allow (all sessions paused)")
            IOAllowPowerChange(rootPowerPort, arg)
        }
    case kIOMessageSystemWillSleep_raw:
        log("system will sleep (mandatory ack)")
        IOAllowPowerChange(rootPowerPort, arg)
    case kIOMessageSystemHasPoweredOn_raw:
        log("system has powered on → re-apply")
        clearLidUnsafe()
        if assertionsHeld { reapplyPower() }
    default:
        break
    }
}

func setupSystemPowerNotifications() {
    rootPowerPort = IORegisterForSystemPower(nil, &rootPowerNotifyPort, systemPowerCallback, &rootPowerNotifier)
    guard rootPowerPort != 0, let port = rootPowerNotifyPort else {
        log("system power notifications: register failed")
        return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), CFRunLoopMode.defaultMode)
    log("system power notifications: subscribed")
}

func closeSystemPowerNotifications() {
    if rootPowerNotifier != 0 { IODeregisterForSystemPower(&rootPowerNotifier); rootPowerNotifier = 0 }
    if let port = rootPowerNotifyPort { IONotificationPortDestroy(port); rootPowerNotifyPort = nil }
    if rootPowerPort != 0 { IOServiceClose(rootPowerPort); rootPowerPort = 0 }
}

// ---------- NWPathMonitor (route availability) ----------
// Event-driven default-route observer — no polling, no ICMP. Callback runs on
// its own queue; bounce to main so all network/hold state is touched from one
// thread. On loss we don't release immediately: the pollTimer's updateHold()
// detects the grace expiry on the next tick. On restore we trigger updateHold()
// inline so re-acquisition is instant.
func setupNetworkMonitor() {
    let monitor = NWPathMonitor()
    pathMonitor = monitor
    monitor.pathUpdateHandler = { path in
        let satisfied = (path.status == .satisfied)
        DispatchQueue.main.async {
            if satisfied == networkPathSatisfied { return }
            networkPathSatisfied = satisfied
            if satisfied {
                networkLostSince = nil
                log("network: up")
                updateHold()
            } else {
                networkLostSince = Date()
                log("network: down — grace \(Int(NETWORK_GRACE_SEC))s")
            }
        }
    }
    monitor.start(queue: DispatchQueue(label: "network-monitor"))
    log("network monitor: started")
}

func closeNetworkMonitor() {
    pathMonitor?.cancel()
    pathMonitor = nil
}

// ---------- DisplayServices brightness (private framework via dlopen) ----------
// API used by `brightness`, `nightlight` CLI. Works on Apple Silicon, no root, no entitlements.
typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

let DIM_BRIGHTNESS: Float = 0.0
let MIN_RESTORE_BRIGHTNESS: Float = 0.05  // floor for restore target when saved was very low
let RESTORE_FADE_MS: Int = 500
let RESTORE_FADE_STEPS: Int = 20
let POWER_HEARTBEAT_SEC: Double = 30.0
var dsGetBrightness: DSGetBrightnessFn? = nil
var dsSetBrightness: DSSetBrightnessFn? = nil
var builtinDisplayID: CGDirectDisplayID? = nil
var savedBrightness: Float? = nil  // nil = not currently dimmed by us

func loadDisplayServices() {
    let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    guard let h = dlopen(path, RTLD_LAZY) else {
        let err = dlerror().map { String(cString: $0) } ?? "unknown"
        log("DisplayServices: dlopen failed: \(err)")
        return
    }
    guard let getSym = dlsym(h, "DisplayServicesGetBrightness"),
          let setSym = dlsym(h, "DisplayServicesSetBrightness")
    else {
        log("DisplayServices: dlsym failed")
        return
    }
    dsGetBrightness = unsafeBitCast(getSym, to: DSGetBrightnessFn.self)
    dsSetBrightness = unsafeBitCast(setSym, to: DSSetBrightnessFn.self)
    log("DisplayServices: loaded")
}

func findBuiltinDisplay() {
    var count: UInt32 = 0
    var err = CGGetActiveDisplayList(0, nil, &count)
    guard err == .success, count > 0 else {
        log("builtin display: CGGetActiveDisplayList err=\(err.rawValue) count=\(count)")
        return
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    err = CGGetActiveDisplayList(count, &ids, &count)
    guard err == .success else {
        log("builtin display: CGGetActiveDisplayList(2) err=\(err.rawValue)")
        return
    }
    for id in ids where CGDisplayIsBuiltin(id) != 0 {
        builtinDisplayID = id
        log("builtin display id=\(id)")
        return
    }
    log("builtin display: not found (external-only setup)")
}

func dimBuiltin() {
    guard let id = builtinDisplayID, let getFn = dsGetBrightness, let setFn = dsSetBrightness else { return }
    var cur: Float = 0
    let gr = getFn(id, &cur)
    guard gr == 0 else { log("dim: get err=\(gr)"); return }
    savedBrightness = cur
    let sr = setFn(id, DIM_BRIGHTNESS)
    log("dim: saved=\(cur), set=\(DIM_BRIGHTNESS), ret=\(sr)")
}

func restoreBuiltin(immediate: Bool = false) {
    guard let id = builtinDisplayID, let setFn = dsSetBrightness, let saved = savedBrightness else { return }
    let target = max(saved, MIN_RESTORE_BRIGHTNESS)
    savedBrightness = nil
    if immediate {
        let sr = setFn(id, target)
        log("restore (immediate): set=\(target) (saved=\(saved)), ret=\(sr)")
        return
    }
    log("restore: fading from \(DIM_BRIGHTNESS) to \(target) over \(RESTORE_FADE_MS)ms (saved=\(saved))")
    let stepSec = Double(RESTORE_FADE_MS) / 1000.0 / Double(RESTORE_FADE_STEPS)
    for i in 1...RESTORE_FADE_STEPS {
        let frac = Float(i) / Float(RESTORE_FADE_STEPS)
        let v = DIM_BRIGHTNESS + (target - DIM_BRIGHTNESS) * frac
        DispatchQueue.main.asyncAfter(deadline: .now() + stepSec * Double(i)) {
            if savedBrightness != nil { return }  // re-dimmed mid-fade → abort
            _ = setFn(id, v)
        }
    }
}

// ---------- read lid state ----------
func readLidClosed() -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return false }
    defer { IOObjectRelease(svc) }
    let prop = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    if let b = prop as? Bool { return b }
    if let n = prop as? Int { return n != 0 }
    return false
}

// ---------- sound ----------
func playSound(_ path: String) {
    let task = Process()
    task.launchPath = "/usr/bin/afplay"
    task.arguments = [path]
    do { try task.run() } catch { log("afplay: \(error)") }
}

// ---------- cleanup ----------
var cleanedUp = false
func cleanup() {
    if cleanedUp { return }
    cleanedUp = true
    setClamshellSleep(disable: false)
    restoreBuiltin(immediate: true)
    clearLidUnsafe()
    releaseAssertions()
    closeClamshellHandles()
    closeSystemPowerNotifications()
    closeNetworkMonitor()
    // remove our pid file if it still points to us
    if let pidStr = try? String(contentsOfFile: DAEMON_PID_FILE, encoding: .utf8),
       Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() {
        try? FileManager.default.removeItem(atPath: DAEMON_PID_FILE)
    }
    log("cleanup done")
}
atexit { cleanup() }

// ---------- signals ----------
let signalQueue = DispatchQueue(label: "signals")
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler {
        log("signal \(sig) → exit")
        cleanup()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// ---------- main ----------
log("daemon starting")
loadDisplayServices()
findBuiltinDisplay()
wasOnAC = isOnAC()
log("initial AC state: \(wasOnAC)")
createAssertions()
setClamshellSleep(disable: true)
setupSystemPowerNotifications()
setupNetworkMonitor()

var lastLidClosed = readLidClosed()
log("initial lid closed: \(lastLidClosed)")

let pollTimer = DispatchSource.makeTimerSource(queue: .main)
pollTimer.schedule(deadline: .now() + 1.0, repeating: 1.0)
pollTimer.setEventHandler {
    let cur = readLidClosed()
    if cur != lastLidClosed {
        // Chime + dim/restore are keep-awake-mode workarounds (audible confirmation
        // that the override is active; brightness=0 nudges macOS to actually sleep
        // on battery). When released, the system is taking the normal sleep path —
        // they would just startle the user mid-sleep.
        if cur {
            if assertionsHeld {
                log("lid closed → Bottle")
                playSound(SOUND_CLOSE)
                dimBuiltin()
            } else {
                log("lid closed (released, skipping chime/dim)")
            }
        } else {
            if assertionsHeld {
                log("lid opened → Submarine")
                playSound(SOUND_OPEN)
                restoreBuiltin()
            } else {
                log("lid opened (released, skipping chime/restore)")
            }
        }
    }
    lastLidClosed = cur
    updateHold()
}
pollTimer.resume()

// Re-apply power state on AC↔battery transitions (workaround for Apple Silicon
// dark-wake bug that invalidates the clamshell-disable flag).
let psCallback: IOPowerSourceCallbackType = { _ in handlePowerSourceChange() }
if let psSource = IOPSCreateLimitedPowerNotification(psCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), psSource, CFRunLoopMode.defaultMode)
    log("limited power notification: subscribed")
} else {
    log("limited power notification: subscribe failed")
}

// Heartbeat: re-issue selector 12 periodically as a safety net for events we don't catch.
let heartbeatTimer = DispatchSource.makeTimerSource(queue: .main)
heartbeatTimer.schedule(deadline: .now() + POWER_HEARTBEAT_SEC, repeating: POWER_HEARTBEAT_SEC)
heartbeatTimer.setEventHandler {
    if assertionsHeld { setClamshellSleep(disable: true) }
}
heartbeatTimer.resume()

// Self-monitor: exit when all registered sessions are dead.
// Sessions dir empty for >EMPTY_GRACE_SEC also triggers exit (covers manual launch with no hook).
var emptyDirSince: Date? = nil
let monitorTimer = DispatchSource.makeTimerSource(queue: .main)
monitorTimer.schedule(deadline: .now() + 30.0, repeating: 30.0)
monitorTimer.setEventHandler {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: SESSIONS_DIR)) ?? []
    if files.isEmpty {
        if emptyDirSince == nil {
            emptyDirSince = Date()
        } else if Date().timeIntervalSince(emptyDirSince!) > EMPTY_GRACE_SEC {
            log("sessions dir empty for >\(Int(EMPTY_GRACE_SEC))s → self-exit")
            cleanup(); exit(0)
        }
        return
    }
    emptyDirSince = nil

    // Watchdog: a hung-but-alive CLI passes the kill(0) check forever. Bail if
    // no hook has touched any session file within HOOK_IDLE_LIMIT.
    var newestTouch: Date? = nil
    for f in files {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: "\(SESSIONS_DIR)/\(f)"))?[.modificationDate] as? Date
        else { continue }
        if newestTouch == nil || m > newestTouch! { newestTouch = m }
    }
    if let n = newestTouch, Date().timeIntervalSince(n) > HOOK_IDLE_LIMIT {
        log("no hook activity for >\(Int(HOOK_IDLE_LIMIT))s (CLI hung) → self-exit")
        cleanup(); exit(0)
    }

    var anyAlive = false
    for f in files {
        guard let content = try? String(contentsOfFile: "\(SESSIONS_DIR)/\(f)", encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if kill(pid, 0) == 0 && pidIsClaude(pid) { anyAlive = true }
        else { try? FileManager.default.removeItem(atPath: "\(PAUSED_DIR)/\(f)") }  // dead/reused → reap marker
    }
    if anyAlive { return }
    log("all registered sessions dead → self-exit")
    cleanup(); exit(0)
}
monitorTimer.resume()

// CFRunLoopRun (not dispatchMain) — required so IOPSCreateLimitedPowerNotification
// callbacks fire. dispatchMain pumps GCD only, not CFRunLoop sources.
CFRunLoopRun()
