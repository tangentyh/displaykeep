// displaykeep — hold kIOPMAssertionTypePreventUserIdleDisplaySleep while some other
// process holds kIOPMAssertionTypePreventUserIdleSystemSleep (e.g. an audio player),
// and drop it again when that assertion disappears.
//
//   swiftc -O -o displaykeep DisplayKeep.swift
//   ./displaykeep                 # keep display awake whenever a user app blocks system sleep
//   ./displaykeep -m NeteaseMusic # only for apps matching this regexp
//   ./displaykeep -m . -a         # "any process, no filtering" (noisy, see NOTES)
//   ./displaykeep -i 5 -v         # poll every 5s, verbose
//
// NOTES
//  * macOS exposes no API to promote somebody else's PreventUserIdleSystemSleep into a
//    display assertion, and no notification when assertions change -> this must poll
//    IOPMCopyAssertionsByProcess(). It is a cheap in-process call, no fork/exec.
//  * Never count these as triggers, or the tool latches itself on forever:
//      - powerd's "Prevent sleep while display is on"  (a *consequence* of our assertion)
//      - our own pid, and caffeinate's assertion
//  * In default (non -a) mode, system-daemon noise is filtered: runningboardd relays
//    xpc/extension/service assertions (CFNetwork.StorageDB, dataaccess, Time Machine
//    extensions, ...) that hold PreventUserIdleSystemSleep constantly and would pin the
//    display on 24/7.
import Foundation
import IOKit.pwr_mgt

var interval: Double = 3
var dryRun = false
var verbose = false
var anyMode = false
var matchRE: NSRegularExpression?

var argv = Array(CommandLine.arguments.dropFirst())
while let a = argv.first {
    argv.removeFirst()
    switch a {
    case "-i": if let v = argv.first, let d = Double(v) { interval = d; argv.removeFirst() }
    case "-m": if let v = argv.first { matchRE = try? NSRegularExpression(pattern: v); argv.removeFirst() }
    case "-a": anyMode = true
    case "-n": dryRun = true
    case "-v": verbose = true
    case "-h", "--help":
        print("usage: displaykeep [-i secs] [-m regexp] [-a] [-n] [-v]"); exit(0)
    default:
        FileHandle.standardError.write("displaykeep: unknown option \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

let ownPid = getpid()

func procName(_ pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "" }
    return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Processes whose system-sleep assertions must never keep the display on.
let selfSustaining: Set<String> = ["powerd", "displaykeep", "caffeinate"]
/// Noise relays for assertions this tool has no business acting on.
let relays: Set<String> = ["runningboardd", "launchd", "logd", "syslogd"]

func isTrigger(pid: pid_t, proc: String, assertion: String) -> Bool {
    if pid == ownPid { return false }
    if selfSustaining.contains(proc) { return false }
    if !anyMode {
        if relays.contains(proc) { return false }
        if assertion.hasPrefix("osservice<") || assertion.hasPrefix("xpcservice<")
            || assertion.hasPrefix("extension<") { return false }
    }
    if let re = matchRE {
        let ns = (proc.isEmpty ? assertion : proc) as NSString
        return re.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) != nil
    }
    return true
}

typealias Trigger = (pid: pid_t, proc: String, assertion: String)

func currentTriggers() -> [Trigger] {
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let byProc = raw?.takeRetainedValue() as? [Int32: [[String: Any]]] else { return [] }
    var out: [Trigger] = []
    for (pid32, list) in byProc {
        let pid = pid_t(pid32)
        if pid == ownPid { continue }
        let proc = procName(pid)
        if selfSustaining.contains(proc) { continue }
        for a in list {
            guard (a["AssertType"] as? String) == (kIOPMAssertionTypePreventUserIdleSystemSleep as String),
                  let name = a["AssertName"] as? String,
                  isTrigger(pid: pid, proc: proc, assertion: name) else { continue }
            out.append((pid, proc, name))
        }
    }
    return out
}

var heldID: IOPMAssertionID = 0
var holding = false

func acquire() {
    let r = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "displaykeep: another process holds a system-sleep assertion" as CFString,
        &heldID)
    if r == kIOReturnSuccess { holding = true; log("display ON-hold taken (assertion \(heldID))") }
    else { log("IOPMAssertionCreateWithName failed: 0x\(String(r, radix: 16))") }
}

func release() {
    guard holding else { return }
    IOPMAssertionRelease(heldID)
    holding = false
    log("display assertion released — display may sleep again")
}

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    FileHandle.standardOutput.write("[\(f.string(from: Date()))] \(s)\n".data(using: .utf8)!)
}

for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in release(); exit(0) } }

log("watching (interval \(interval)s\(dryRun ? ", dry run" : "")"
    + (matchRE.map { ", match /\($0.pattern)/" } ?? "") + (anyMode ? ", any mode" : "") + ")")

var last: String = ""
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(500))
timer.setEventHandler {
    let hits = currentTriggers()
    let sig = hits.map { "\($0.pid):\($0.assertion)" }.sorted().joined(separator: "|")
    if verbose || sig != last {
        for h in hits { log("trigger \(h.pid)(\(h.proc)): \(h.assertion)") }
    }
    if hits.isEmpty {
        release()
    } else if dryRun {
        if sig != last { log("would hold display awake") }
    } else if !holding {
        acquire()
    }
    last = sig
}
timer.resume()
dispatchMain()
