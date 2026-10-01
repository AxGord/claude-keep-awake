// keep-awake-daemon: single-process replacement for caffeinate + clamshell override.
// - IOPMAssertion: prevents idle sleep (display + system)
// - IOKit selector 12 (kPMSetClamshellSleepState): prevents lid-close sleep
// - Polls AppleClamshellState (1 Hz), plays sounds on lid open/close
// - Holds across a usage-limit stop until the reset (when the CLI's auto-continue is on)
//   and re-prompts the session through its messaging socket if the CLI did not
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
// keep-awake.sh records each session's transcript path here (transcripts/<PID>).
// Used to detect an aborted turn (Esc interrupt, usage-limit/API-error stop):
// neither fires Stop or Notification, so the session stays registered+unpaused,
// but Claude Code appends a recognizable final message to the transcript.
let TRANSCRIPTS_DIR = "\(STATE_DIR)/transcripts"
// Prefix (no closing bracket): Claude Code writes both "[Request interrupted by
// user]" (Esc while idle/generating) and "[Request interrupted by user for tool
// use]" (Esc while a tool runs). Matching the prefix catches both.
let INTERRUPT_MARKER = "[Request interrupted by user"
let TRANSCRIPT_TAIL_BYTES = 65536  // only the tail is scanned; the marker is the last line
// limit-awake.sh writes limit/<PID> when a turn ended on a usage-limit stop
// (StopFailure, error=rate_limit) and the CLI's own autoContinueAtUsageLimit is
// on. Lines: reset epoch, messaging socket path, messaging token, optional
// "injected". While the marker is pending the session counts as active — over the
// paused marker, the API-error transcript rule and the hook-idle watchdog — so
// the CLI's built-in auto-continue can fire at reset. Any hook firing removes the
// marker (keep-awake.sh); if it is still there at reset+grace the CLI did not
// resume, and the daemon sends the continue prompt itself through the session's
// messaging socket (the channel SendMessage uses between sessions; undocumented,
// peer protocol 1 — any failure just releases the Mac as before).
let LIMIT_DIR = "\(STATE_DIR)/limit"
let LIMIT_RESUME_GRACE_SEC: TimeInterval =
    max(0, Double(ProcessInfo.processInfo.environment["KEEP_AWAKE_LIMIT_GRACE_SEC"] ?? "") ?? 90)
let LIMIT_INJECT_REPLY_WAIT_MS: Int32 = 2000
let LIMIT_MAX_HOLD_SEC: TimeInterval = 6 * 3600  // a 5h window plus slack; longer = weekly limit or a misparse
let LIMIT_CONTINUE_PROMPT = "Usage limit has reset. Continue the task that was interrupted by the limit stop. If nothing was in progress, reply with one line saying so."
// stop-awake.sh writes bg/<PID> when the turn ended with background work still
// running (async subagents, workflows, run_in_background shell tasks). Lines:
// first_seen epoch<TAB>type<TAB>id<TAB>path (shell: output file, subagent:
// transcript). While any entry holds, the session counts as active — over the
// paused marker (the 60s idle_prompt Notification fires regardless of running
// tasks) and the aborted-turn rule — since the work runs whether or not Claude
// waits for the user.
let BG_DIR = "\(STATE_DIR)/bg"
let BGOUT_DIR = "\(STATE_DIR)/bgout"
let BG_SHELL_MAX_HOLD_SEC: TimeInterval = 3600  // a longer-running process is suspect; mirrors stop-awake.sh
// A live subagent appends to its transcript at least every tool call (the Bash
// tool caps a foreground command at 10 min); this long silent = it is gone.
let BG_SUBAGENT_SILENT_SEC: TimeInterval = 1800
let BG_RECHECK_SEC: TimeInterval = 15    // shell entries cost two lsof runs; updateHold ticks at 1 Hz
let BG_SERVER_CONFIRM_SEC: TimeInterval = 30  // listening this long before a shell task counts as a server
// A subagent's final text line may carry stop_reason null (a streaming
// snapshot); mid-message such a line is followed by its tool_use within ms.
let BG_SUBAGENT_QUIET_SEC: TimeInterval = 90
let PROBE_TIMEOUT_SEC: TimeInterval = 3  // lsof can hang on a stale network mount
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
// A backgrounded session runs straight from the installer's versioned binary
// (…/claude/versions/<ver>) rather than via the `claude` symlink — same CLI.
// An unanswered ps (spawn failure, timeout) counts as claude: kill(0) already
// saw the PID alive, and a false "not claude" reaps a live session's markers.
func pidIsClaude(_ pid: pid_t) -> Bool {
    guard let out = runCapture("/bin/ps", ["-p", "\(pid)", "-o", "comm="]) else { return true }
    let comm = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return comm == SESSION_PROC_NAME || comm.hasSuffix("/\(SESSION_PROC_NAME)")
        || comm.contains("/\(SESSION_PROC_NAME)/versions/")
}

// ---------- aborted-turn detection ----------
// Two turn endings fire no Stop and no Notification, so the session stays
// registered and unpaused and would hold the Mac until the 2h watchdog:
//  - Esc interrupt: Claude Code records the abort in the transcript as a final
//    user message "[Request interrupted by user]".
//  - API-error stop (usage limit / 429 / overloaded / auth): the CLI appends a
//    synthetic assistant message ("You've hit your session limit · resets ...")
//    whose transcript line carries top-level "isApiErrorMessage": true. Matching
//    that flag instead of the banner text covers every error wording. (The 60s
//    idle Notification does fire after some limit stops, but not after a
//    limit-refused prompt — observed 2026-07-15 — so it can't be relied on.)
// A genuinely running foreground tool is NOT confused for either: its tool_use
// line is written at tool START, so a live tool leaves a trailing tool_use with
// no matching tool_result — never an abort marker. So this never releases the
// Mac out from under a real long-running tool.
func messageIsInterrupt(_ msg: [String: Any]) -> Bool {
    if let s = msg["content"] as? String { return s.contains(INTERRUPT_MARKER) }
    if let parts = msg["content"] as? [[String: Any]] {
        for p in parts where (p["type"] as? String) == "text" {
            if let t = p["text"] as? String, t.contains(INTERRUPT_MARKER) { return true }
        }
    }
    return false
}

// The transcript's last complete user/assistant line (parsed), or nil. Reads only
// the tail; metadata/partial lines are skipped, so the first complete message
// scanned from the end decides.
func lastTranscriptMessage(_ path: String) -> [String: Any]? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
          let fh = FileHandle(forReadingAtPath: path)
    else { return nil }
    defer { try? fh.close() }
    if size > TRANSCRIPT_TAIL_BYTES { fh.seek(toFileOffset: UInt64(size - TRANSCRIPT_TAIL_BYTES)) }
    // Lossy decode: the tail may start mid-codepoint, which would make a strict
    // decode return nil for the whole buffer. The mangled leading partial line
    // fails JSON parse and is skipped anyway.
    let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let ld = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant",
              obj["message"] is [String: Any]
        else { continue }                                    // metadata / partial line → skip
        return obj
    }
    return nil
}

// True iff the session's transcript ends with an aborted turn: the last
// user/assistant message is an Esc-interrupt marker or an API-error stop.
func sessionTurnAborted(_ name: String) -> Bool {
    guard let raw = try? String(contentsOfFile: "\(TRANSCRIPTS_DIR)/\(name)", encoding: .utf8)
    else { return false }
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, let obj = lastTranscriptMessage(path),
          let msg = obj["message"] as? [String: Any]
    else { return false }
    if obj["isApiErrorMessage"] as? Bool == true { return true } // limit/API-error stop
    return messageIsInterrupt(msg)                               // last real message decides
}

// ---------- usage-limit hold ----------
struct LimitMarker {
    let epoch: Date
    let socket: String
    let token: String
    let injected: Bool
}

// Sessions whose hold was already logged; cleared when the marker goes away.
var announcedLimitHolds = Set<String>()

// nil if absent or malformed; validity (pid, cap, expiry) is the caller's call.
func readLimitMarker(_ name: String) -> LimitMarker? {
    guard let raw = try? String(contentsOfFile: "\(LIMIT_DIR)/\(name)", encoding: .utf8) else {
        announcedLimitHolds.remove(name)  // gone (hook removed it) → a later hold logs again
        return nil
    }
    let lines = raw.components(separatedBy: "\n")
    guard lines.count >= 3, let secs = TimeInterval(lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }
    return LimitMarker(epoch: Date(timeIntervalSince1970: secs), socket: lines[1], token: lines[2],
                       injected: lines.dropFirst(3).contains("injected"))
}

func writeLimitMarker(_ name: String, _ m: LimitMarker) -> Bool {
    let text = "\(Int(m.epoch.timeIntervalSince1970))\n\(m.socket)\n\(m.token)\n" + (m.injected ? "injected\n" : "")
    return (try? text.write(toFile: "\(LIMIT_DIR)/\(name)", atomically: true, encoding: .utf8)) != nil
}

func dropLimitMarker(_ name: String) {
    try? FileManager.default.removeItem(atPath: "\(LIMIT_DIR)/\(name)")
    announcedLimitHolds.remove(name)
}

// A hold is pending while the marker is well-formed, within the cap and before
// reset+grace. Read-only apart from the one-time log; processLimitMarkers()
// owns dropping and injecting.
func pendingLimitMarker(_ name: String) -> LimitMarker? {
    guard let m = readLimitMarker(name),
          m.epoch.timeIntervalSinceNow <= LIMIT_MAX_HOLD_SEC,
          Date() < m.epoch.addingTimeInterval(LIMIT_RESUME_GRACE_SEC)
    else { return nil }
    if !announcedLimitHolds.contains(name) {
        announcedLimitHolds.insert(name)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        log("limit stop: holding session \(name) until \(fmt.string(from: m.epoch))")
    }
    return m
}

func jsonEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Two newline-terminated JSON lines — the auth frame, then a user message — over
// the session's messaging socket. Blocks the main queue for at most the reply
// wait (the CLI reads the lines before the peer goes away), once per reset.
// Success means the bytes were accepted, not that the CLI honoured them — the
// transcript rule settles that afterwards. Returns nil on success, else a reason.
func injectContinue(_ m: LimitMarker) -> String? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard m.socket.utf8.count < cap else { return "socket path too long" }
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: cap) { _ = strlcpy($0, m.socket, cap) }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "socket: \(String(cString: strerror(errno)))" }
    defer { close(fd) }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return "connect: \(String(cString: strerror(errno)))" }
    let payload = "{\"type\":\"auth\",\"token\":\"\(jsonEscaped(m.token))\"}\n"
        + "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(jsonEscaped(LIMIT_CONTINUE_PROMPT))\"}}\n"
    let bytes = Array(payload.utf8)
    var sent = 0
    let written: Bool = bytes.withUnsafeBytes { buf in
        while sent < buf.count {
            let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
            if n <= 0 { return false }
            sent += Int(n)
        }
        return true
    }
    guard written else { return "write: \(String(cString: strerror(errno)))" }
    shutdown(fd, SHUT_WR)
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    _ = poll(&pfd, 1, LIMIT_INJECT_REPLY_WAIT_MS)
    return nil
}

// 1 Hz. A marker is over early when the session moved on without any hook: a
// local command (/rate-limit-options "Don't continue", /low-priority), a typed
// prompt or the CLI's own auto-continue all land as a newer user/assistant
// message, so the transcript no longer ends in the API error. Otherwise it is
// settled once reset+grace has passed: the CLI resumed on its own (a hook
// touched sessions/<PID> after the reset — keep-awake.sh normally removes the
// marker outright), or it did not and the continue prompt is injected. The injection is this session's next user prompt, so the paused
// marker goes the way keep-awake.sh clears it on UserPromptSubmit; the marker is
// then rewritten as "injected" with epoch=now so the hold bridges the seconds
// until the CLI appends the prompt to the transcript. After that the ordinary
// rules decide: a transcript no longer ending in the API error is a live turn,
// one still ending in it means the CLI ignored us and the Mac is released.
func processLimitMarkers() {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: LIMIT_DIR)) ?? []
    for f in files {
        guard let pid = Int32(f), kill(pid, 0) == 0,
              let m = readLimitMarker(f), m.epoch.timeIntervalSinceNow <= LIMIT_MAX_HOLD_SEC
        else {
            log("limit marker for session \(f) invalid/expired → dropped")
            dropLimitMarker(f); continue
        }
        // Judged only once the marker has aged past the grace: at the stop itself
        // the error line and the StopFailure hook race by milliseconds.
        let written = (try? FileManager.default.attributesOfItem(atPath: "\(LIMIT_DIR)/\(f)"))?[.modificationDate] as? Date ?? Date()
        if !m.injected, Date().timeIntervalSince(written) > LIMIT_RESUME_GRACE_SEC, !sessionTurnAborted(f) {
            log("limit reset: session \(f) moved on (transcript) → no inject")
            dropLimitMarker(f); continue
        }
        if Date() < m.epoch.addingTimeInterval(LIMIT_RESUME_GRACE_SEC) { continue }
        // Process identity only at settle time: pidIsClaude forks ps, and a
        // transient spawn failure must not cost a pending hold.
        guard pidIsClaude(pid) else {
            log("limit marker for session \(f) invalid/expired → dropped")
            dropLimitMarker(f); continue
        }
        if m.injected {
            log("limit reset: injected hold for session \(f) over → transcript decides")
            dropLimitMarker(f); continue
        }
        let touched = (try? FileManager.default.attributesOfItem(atPath: "\(SESSIONS_DIR)/\(f)"))?[.modificationDate] as? Date
        if let t = touched, t > m.epoch {
            log("limit reset: session \(f) resumed on its own → no inject")
            dropLimitMarker(f); continue
        }
        if m.socket.isEmpty || m.token.isEmpty {
            log("limit reset: inject into session \(f) failed (no messaging socket) → releasing")
            dropLimitMarker(f); continue
        }
        if let err = injectContinue(m) {
            log("limit reset: inject into session \(f) failed (\(err)) → releasing")
            dropLimitMarker(f); continue
        }
        log("limit reset: injected continue into session \(f)")
        try? FileManager.default.removeItem(atPath: "\(PAUSED_DIR)/\(f)")
        if !writeLimitMarker(f, LimitMarker(epoch: Date(), socket: m.socket, token: m.token, injected: true)) {
            log("limit reset: could not rewrite marker for session \(f) → releasing")
            dropLimitMarker(f)
        }
    }
}

// ---------- background work ----------
// stdout of a short-lived tool, or nil on spawn failure or PROBE_TIMEOUT_SEC.
func runCapture(_ path: String, _ args: [String]) -> String? {
    let task = Process()
    task.launchPath = path
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in exited.signal() }
    do { try task.run() } catch {
        log("spawn \(path) failed: \(error)")
        return nil
    }
    // Drain concurrently so a large output can't block the child on a full pipe.
    var data = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    if exited.wait(timeout: .now() + PROBE_TIMEOUT_SEC) == .timedOut {
        kill(task.processIdentifier, SIGKILL)
        log("\(path) timed out after \(Int(PROBE_TIMEOUT_SEC))s → killed")
        return nil
    }
    // Reading `data` before the drain finished would race the closure.
    guard drained.wait(timeout: .now() + 1) == .success else { return nil }
    return String(data: data, encoding: .utf8) ?? ""
}

enum ShellTaskState { case done, listening, running, unknown }

// A shell task's own processes (its shell and every child that inherited
// stdout) hold its output file open while it runs — so the holders are the
// task's process tree. None left → it finished (its revival Stop may lag). A
// holder listening on TCP → likely a server whose command stop-awake.sh didn't
// recognize. lsof failing or hanging (stale network mount) → unknown.
func shellTaskState(_ outPath: String) -> ShellTaskState {
    guard let holders = runCapture("/usr/sbin/lsof", ["-t", "--", outPath]) else { return .unknown }
    let pids = holders.split(separator: "\n").map(String.init)
    if pids.isEmpty { return .done }
    guard let listening = runCapture("/usr/sbin/lsof",
        ["-nP", "-a", "-p", pids.joined(separator: ","), "-iTCP", "-sTCP:LISTEN", "-t"])
    else { return .unknown }
    return listening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .running : .listening
}

// A subagent is done once its transcript ends with its final assistant message
// (text, no tool_use: stop_reason end_turn, or null once quiet
// BG_SUBAGENT_QUIET_SEC), an API error or an interrupt, or has gone silent
// BG_SUBAGENT_SILENT_SEC. Without a transcript (no path in the Stop payload, a
// session since /clear'd, not written yet) it holds only within the silence
// window from first_seen.
func subagentRunning(_ path: String, firstSeen: Double, now: Date) -> Bool {
    guard !path.isEmpty,
          let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    else { return now.timeIntervalSince1970 - firstSeen < BG_SUBAGENT_SILENT_SEC }
    let quiet = now.timeIntervalSince(mtime)
    if quiet >= BG_SUBAGENT_SILENT_SEC { return false }
    guard let obj = lastTranscriptMessage(path), let msg = obj["message"] as? [String: Any]
    else { return true }
    if obj["isApiErrorMessage"] as? Bool == true { return false }
    if obj["type"] as? String == "user" { return !messageIsInterrupt(msg) }
    let parts = msg["content"] as? [[String: Any]] ?? []
    let kinds = Set(parts.compactMap { $0["type"] as? String })
    if kinds.contains("tool_use") || !kinds.contains("text") { return true }  // tool call / thinking only
    if let stop = msg["stop_reason"] as? String { return stop == "tool_use" }
    return quiet < BG_SUBAGENT_QUIET_SEC
}

var bgHoldCache: [String: (at: Date, mtime: Date, holds: Bool)] = [:]
// Per "<session>/<task id>": when a shell task was first seen listening (a test
// binding a port in-process listens briefly; a server keeps listening), and the
// tasks settled for good — confirmed servers, and ones whose probe hung — so
// they cost no more lsof runs.
var bgListenSince: [String: Date] = [:]
var bgServers: Set<String> = []
var bgProbeStuck: Set<String> = []

func forgetBgWork(_ name: String) {
    let prefix = "\(name)/"
    bgHoldCache.removeValue(forKey: name)
    bgListenSince = bgListenSince.filter { !$0.key.hasPrefix(prefix) }
    bgServers = bgServers.filter { !$0.hasPrefix(prefix) }
    bgProbeStuck = bgProbeStuck.filter { !$0.hasPrefix(prefix) }
}

// True iff the session's bg marker names background work that should keep the
// Mac awake: a live subagent, a workflow/teammate, or a shell task within
// BG_SHELL_MAX_HOLD_SEC that is still running and not a server.
func bgWorkHolds(_ name: String) -> Bool {
    let path = "\(BG_DIR)/\(name)"
    guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
          let raw = try? String(contentsOfFile: path, encoding: .utf8)
    else {
        forgetBgWork(name)
        return false
    }
    let now = Date()
    if let c = bgHoldCache[name], c.mtime == mtime, now.timeIntervalSince(c.at) < BG_RECHECK_SEC {
        return c.holds
    }
    var holding: [String] = []
    for line in raw.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 3, let first = Double(cols[0]) else { continue }
        let (type, id) = (cols[1], cols[2])
        let taskPath = cols.count >= 4 ? cols[3] : ""
        switch type {
        case "shell":
            if now.timeIntervalSince1970 - first >= BG_SHELL_MAX_HOLD_SEC { continue }
            let key = "\(name)/\(id)"
            if bgServers.contains(key) { continue }
            if !taskPath.isEmpty && !bgProbeStuck.contains(key) {
                switch shellTaskState(taskPath) {
                case .done:
                    bgListenSince.removeValue(forKey: key)
                    continue
                case .listening:
                    let since = bgListenSince[key] ?? now
                    bgListenSince[key] = since
                    if now.timeIntervalSince(since) >= BG_SERVER_CONFIRM_SEC {
                        bgServers.insert(key)
                        continue
                    }
                case .running: bgListenSince.removeValue(forKey: key)
                case .unknown: bgProbeStuck.insert(key)  // hold, bounded by the shell cap
                }
            }
        case "subagent":
            if !subagentRunning(taskPath, firstSeen: first, now: now) { continue }
        default: break  // workflow / teammate: no liveness probe; next Stop re-decides
        }
        holding.append("\(type) \(id)")
    }
    let holds = !holding.isEmpty
    if holds != (bgHoldCache[name]?.holds ?? false) {
        log(holds ? "background work holds session \(name): \(holding.joined(separator: ", "))"
                  : "background work of session \(name) no longer holds (done, server or over the cap)")
    }
    bgHoldCache[name] = (at: now, mtime: mtime, holds: holds)
    return holds
}

// ---------- per-session pause ----------
// A session is active iff its PID is alive AND (background work holds it OR it
// has no paused/<PID> marker and its turn wasn't aborted).
// Session filename == PID string (keep-awake.sh); marker filename matches.
func hasActiveSession() -> Bool {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: SESSIONS_DIR)) ?? []
    for f in files {
        guard let content = try? String(contentsOfFile: "\(SESSIONS_DIR)/\(f)", encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if kill(pid, 0) != 0 || !pidIsClaude(pid) { continue }                      // dead or PID reused
        if pendingLimitMarker(f) != nil { return true }                              // limit stop: hold for the reset
        if bgWorkHolds(f) { return true }                                            // background work still running
        if FileManager.default.fileExists(atPath: "\(PAUSED_DIR)/\(f)") { continue } // paused
        if sessionTurnAborted(f) { continue }                                        // turn aborted (Esc / API error)
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
        let reason = !activeSession ? "no active session (paused/interrupted)" : "network offline >\(Int(NETWORK_GRACE_SEC))s"
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
    processLimitMarkers()
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
    // A pending usage-limit hold is legitimate hook silence (bounded by LIMIT_MAX_HOLD_SEC).
    let limitPending = files.contains { pendingLimitMarker($0) != nil }
    if let n = newestTouch, !limitPending, Date().timeIntervalSince(n) > HOOK_IDLE_LIMIT {
        log("no hook activity for >\(Int(HOOK_IDLE_LIMIT))s (CLI hung) → self-exit")
        cleanup(); exit(0)
    }

    var anyAlive = false
    for f in files {
        guard let content = try? String(contentsOfFile: "\(SESSIONS_DIR)/\(f)", encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { continue }
        if kill(pid, 0) == 0 && pidIsClaude(pid) { anyAlive = true }
        else {  // dead/reused → reap markers
            try? FileManager.default.removeItem(atPath: "\(PAUSED_DIR)/\(f)")
            try? FileManager.default.removeItem(atPath: "\(BG_DIR)/\(f)")
            try? FileManager.default.removeItem(atPath: "\(BGOUT_DIR)/\(f)")
            forgetBgWork(f)
            dropLimitMarker(f)
        }
    }
    if anyAlive { return }
    log("all registered sessions dead → self-exit")
    cleanup(); exit(0)
}
monitorTimer.resume()

// CFRunLoopRun (not dispatchMain) — required so IOPSCreateLimitedPowerNotification
// callbacks fire. dispatchMain pumps GCD only, not CFRunLoop sources.
CFRunLoopRun()
