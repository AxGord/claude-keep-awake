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
    releaseAssertions()
    closeClamshellHandles()
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
createAssertions()
setClamshellSleep(disable: true)

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
        } else {
            log("lid opened → Bottle")
            playSound(SOUND_OPEN)
        }
    }
    lastLidClosed = cur
}
pollTimer.resume()

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

dispatchMain()
