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

let LOG_PATH = "/tmp/keep-awake-daemon.log"
let SOUND_CLOSE = "/System/Library/Sounds/Submarine.aiff"
let SOUND_OPEN  = "/System/Library/Sounds/Bottle.aiff"
let kPMSetClamshellSleepState: UInt32 = 12

let STATE_DIR = ProcessInfo.processInfo.environment["KEEP_AWAKE_STATE_DIR"]
    ?? "\(NSHomeDirectory())/.claude/keep-awake-state"
let SESSIONS_DIR = "\(STATE_DIR)/sessions"
let DAEMON_PID_FILE = "\(STATE_DIR)/daemon.pid"
let EMPTY_GRACE_SEC: TimeInterval = 300  // exit after 5 min with no sessions

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
        log("system asking permission to sleep → cancel")
        IOCancelPowerChange(rootPowerPort, arg)
        reapplyPower()
    case kIOMessageSystemWillSleep_raw:
        log("system will sleep (mandatory ack)")
        IOAllowPowerChange(rootPowerPort, arg)
    case kIOMessageSystemHasPoweredOn_raw:
        log("system has powered on → re-apply")
        reapplyPower()
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
    releaseAssertions()
    closeClamshellHandles()
    closeSystemPowerNotifications()
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
createAssertions()
setClamshellSleep(disable: true)
setupSystemPowerNotifications()

var lastLidClosed = readLidClosed()
log("initial lid closed: \(lastLidClosed)")

let pollTimer = DispatchSource.makeTimerSource(queue: .main)
pollTimer.schedule(deadline: .now() + 1.0, repeating: 1.0)
pollTimer.setEventHandler {
    let cur = readLidClosed()
    if cur != lastLidClosed {
        if cur {
            log("lid closed → Submarine")
            playSound(SOUND_CLOSE)
            dimBuiltin()
        } else {
            log("lid opened → Bottle")
            playSound(SOUND_OPEN)
            restoreBuiltin()
        }
    }
    lastLidClosed = cur
}
pollTimer.resume()

// Re-apply power state on AC↔battery transitions (workaround for Apple Silicon
// dark-wake bug that invalidates the clamshell-disable flag).
let psCallback: IOPowerSourceCallbackType = { _ in reapplyPower() }
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
    setClamshellSleep(disable: true)
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
    for f in files {
        guard let content = try? String(contentsOfFile: "\(SESSIONS_DIR)/\(f)", encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if kill(pid, 0) == 0 { return }  // at least one alive
    }
    log("all registered sessions dead → self-exit")
    cleanup(); exit(0)
}
monitorTimer.resume()

// CFRunLoopRun (not dispatchMain) — required so IOPSCreateLimitedPowerNotification
// callbacks fire. dispatchMain pumps GCD only, not CFRunLoop sources.
CFRunLoopRun()
