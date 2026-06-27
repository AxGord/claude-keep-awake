// Regression test for the daemon-side process-identity check (pidIsClaude).
//
// The daemon self-exits when no registered session passes its identity check.
// The original check used proc_name() (p_comm), but the claude CLI overwrites
// p_comm with its version string (e.g. "2.1.193"), so a REAL claude session was
// rejected and the daemon self-exited mid-work — letting the Mac sleep. The fix
// reads `ps -o comm=` (argv[0]) instead, matching the bash hooks.
//
// Red-green: oldImpl (proc_name) must FAIL for a live claude process; newImpl
// (ps) must PASS for it and still reject a non-matching phantom.
//
// Build + run:
//   swiftc -O test/repro-pid-reuse-daemon.swift -o /tmp/repro-pid-reuse-daemon
//   /tmp/repro-pid-reuse-daemon
// Exit 0 = pass.

import Foundation

let PROC = ProcessInfo.processInfo.environment["KEEP_AWAKE_PROC_NAME"] ?? "claude"

// OLD (buggy): identity via proc_name / p_comm.
func oldImpl(_ pid: pid_t) -> Bool {
    var buf = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    return String(cString: buf) == PROC
}

// NEW (fixed): identity via `ps -o comm=` (argv[0]), mirroring the bash hooks.
func newImpl(_ pid: pid_t) -> Bool {
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
    return comm == PROC || comm.hasSuffix("/\(PROC)")
}

func psComm(_ pid: pid_t) -> String {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-p", "\(pid)", "-o", "comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : "<none>"
}

// Find a live claude CLI process (the real-world divergence: comm=claude but
// p_comm=<version>). pgrep -x matches the exact comm.
func liveClaudePid() -> pid_t? {
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments = ["-x", PROC]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") {
        if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) { return pid }
    }
    return nil
}

var fail = false
func check(_ desc: String, _ cond: Bool) {
    print(cond ? "  PASS: \(desc)" : "  FAIL: \(desc)")
    if !cond { fail = true }
}

// ---- Scenario A: real claude session (divergent comm vs p_comm) ----
if let pid = liveClaudePid() {
    print("live \(PROC) pid \(pid): ps-comm=[\(psComm(pid))] proc_name=[\(procName(pid))]")
    check("RED: old proc_name() rejects a real \(PROC) session (the bug)", oldImpl(pid) == false)
    check("GREEN: new ps -o comm= accepts a real \(PROC) session", newImpl(pid) == true)
} else {
    print("SKIP scenario A: no live '\(PROC)' process to exercise the divergence")
}

// ---- Scenario B: phantom (recycled PID -> unrelated process) still rejected ----
// A `sleep` child stands in for the unrelated process the OS recycled the PID to.
let phantom = Process()
phantom.launchPath = "/bin/sleep"
phantom.arguments = ["30"]
try? phantom.run()
let phantomPid = phantom.processIdentifier
let phantomComm = psComm(phantomPid)
print("phantom pid \(phantomPid): ps-comm=[\(phantomComm)]")
// Only a genuine non-match is a phantom. Under a KEEP_AWAKE_PROC_NAME override
// that happens to equal the stand-in's name, sleep IS valid — skip, not fail.
if (phantomComm as NSString).lastPathComponent == PROC {
    print("SKIP scenario B: phantom comm '\(phantomComm)' matches PROC '\(PROC)'")
} else {
    check("phantom (comm=\(phantomComm)) rejected by new impl", newImpl(phantomPid) == false)
}
phantom.terminate()

print(fail ? "RESULT: FAIL" : "RESULT: PASS")
exit(fail ? 1 : 0)
