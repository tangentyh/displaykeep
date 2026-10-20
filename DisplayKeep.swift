// displaykeep — hold kIOPMAssertionTypePreventUserIdleDisplaySleep while some other
// process holds kIOPMAssertionTypePreventUserIdleSystemSleep (e.g. an audio player),
// and drop it again when that assertion disappears.
//
// Single process: poll loop + menu bar indicator + state file.
//
//   ./displaykeep                   # daemon: watch, hold, show a menu bar icon
//   ./displaykeep -m NeteaseMusic   # only for matching processes
//   ./displaykeep -i 5 -v           # poll 5s, verbose
//   ./displaykeep -n                # dry run: report only, never assert
//   ./displaykeep status            # exit 0 holding / 1 armed / 2 paused / 3 dead / 4 failed
//   ./displaykeep pause 30m         # pause (bare number = minutes); no arg = indefinitely
//   ./displaykeep resume | toggle
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
//  * proc_name(3) fails for other users' processes (powerd, coreaudiod -> empty name),
//    so names come from sysctl(KERN_PROC_PID). p_comm is truncated to 16 chars.
//
// FILES (all under ~/Library/Application Support/displaykeep/)
//   state.json  written every tick; the CLI and any widget read it
//   paused      present = paused; contents = epoch deadline, or "forever"
//   lock        flock, so a second instance does not add a second menu bar icon
// plus ~/Library/Logs/displaykeep.log, which the app opens itself (see openLogFile) so the
// log works the same whether we were started by a launchd agent or as a login item.
//
// START AT LOGIN: one user-facing switch, two possible supervisors behind it.
//   * SMAppService.mainApp — the release/drag-install path, visible under System
//     Settings > General > Login Items, no plist to write.
//   * a LaunchAgent plist in ~/Library/LaunchAgents — what `make install` sets up for
//     source users (KeepAlive restart, launchctl disable to persist "off").
// The menu never offers the choice: it shows whether *a* supervisor exists and leaves
// the existing one alone instead of stacking a second one on top.

import Foundation
import IOKit.pwr_mgt
import AppKit
import ServiceManagement

let displaykeepVersion = "1.3"
let bundleID = Bundle.main.bundleIdentifier ?? "com.tangentyh.displaykeep"

// MARK: - paths

let supportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("displaykeep", isDirectory: true)
let stateURL = supportDir.appendingPathComponent("state.json")
let pauseURL = supportDir.appendingPathComponent("paused")
let lockURL = supportDir.appendingPathComponent("lock")
let optionsURL = supportDir.appendingPathComponent("options.json")
let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")

// Logs belong in ~/Library/Logs, not /tmp: per-user, not world-readable, and not
// reaped by the periodic /tmp clean-out while launchd still holds the fd.
let logDir = FileManager.default
    .urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs", isDirectory: true)
let logPath = logDir.appendingPathComponent("displaykeep.log").path

func ensureSupportDir() {
    try? FileManager.default.createDirectory(
        at: supportDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
}

/// Own the log ourselves instead of leaning on launchd's StandardOutPath: a login-item
/// launch has no plist, so stdout goes nowhere and "Open log" would sit empty forever.
/// Truncate, never unlink — a re-exec'd launchd instance may still hold the fd, and an
/// unlink would send the rest of its output to a deleted inode.
var logFD: Int32 = -1

// NB: no `openLog` here — the NSMenu action of that name would shadow it inside Daemon.
func openLogFile() {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? NSNumber, size.intValue > 1 << 20,
       let fh = FileHandle(forWritingAtPath: logPath) {
        try? fh.truncate(atOffset: 0)
        try? fh.close()
    }
    logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    // Crash traces (and anything AppKit prints) belong in the same file; without this
    // they are only visible when a supervisor happens to redirect stderr for us.
    if logFD >= 0 { dup2(logFD, STDERR_FILENO) }
}

// MARK: - state file

struct TriggerRec: Codable {
    var pid: Int32
    var proc: String
    var assertion: String
}

struct State: Codable {
    var version: String
    var pid: Int32
    var holding: Bool
    var verified: Bool
    var paused: Bool
    var pausedUntil: Double?
    var interval: Double
    var match: String?
    var anyMode: Bool
    var dryRun: Bool
    var triggers: [TriggerRec]
    var holdingSince: Double?
    var startedAt: Double
    var updatedAt: Double
    var tick: Int
    var lastError: String?
}

func loadState() -> State? {
    guard let d = try? Data(contentsOf: stateURL) else { return nil }
    return try? JSONDecoder().decode(State.self, from: d)
}

func saveState(_ s: State) {
    ensureSupportDir()
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let d = try? enc.encode(s) else { return }
    try? d.write(to: stateURL, options: .atomic)   // temp + rename
}

// MARK: - pause file

struct PauseFile {
    var active = false
    var until: Double?
}

func readPause(now: Double = Date().timeIntervalSince1970) -> PauseFile {
    guard let raw = try? String(contentsOf: pauseURL, encoding: .utf8) else { return PauseFile() }
    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let ts = Double(t), ts > 0 {
        return PauseFile(active: ts > now, until: ts)
    }
    return PauseFile(active: true, until: nil)     // "forever" / empty file
}

func writePause(until: Double?) {
    ensureSupportDir()
    let text = until.map { String(format: "%.0f\n", $0) } ?? "forever\n"
    try? text.data(using: .utf8)?.write(to: pauseURL, options: .atomic)
}

func removePauseFile() {
    try? FileManager.default.removeItem(at: pauseURL)
}

/// "30" -> 30 min, "45s", "2h", "1h30m".
func parseDuration(_ s: String) -> Double? {
    var rest = Substring(s.lowercased())
    var total: Double = 0
    var parts = 0
    while !rest.isEmpty {
        var num = ""
        while let c = rest.first, c.isNumber { num.append(c); rest = rest.dropFirst() }
        guard let n = Double(num) else { return nil }
        var unit: Character = "m"
        if let c = rest.first, "smh".contains(c) { unit = c; rest = rest.dropFirst() }
        total += n * (unit == "s" ? 1 : unit == "m" ? 60 : 3600)
        parts += 1
        if parts > 2 { return nil }
    }
    return parts == 0 ? nil : total
}

// MARK: - formatting

func fmtDuration(_ s: Double) -> String {
    let t = max(0, s.rounded())
    if t < 60 { return "\(Int(t))s" }
    let m = Int(t) / 60, sec = Int(t) % 60
    if m < 60 { return sec == 0 ? "\(m)m" : "\(m)m\(String(format: "%02d", sec))s" }
    let h = m / 60, mm = m % 60
    return mm == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", mm))m"
}

func fmtClock(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = Data("[\(f.string(from: Date()))] \(s)\n".utf8)
    if logFD >= 0 {
        line.withUnsafeBytes { _ = write(logFD, $0.baseAddress, $0.count) }
    } else {
        FileHandle.standardOutput.write(line)   // CLI paths, or a log we could not open
    }
}

// MARK: - assertion scanning

typealias Trigger = (pid: pid_t, proc: String, assertion: String)

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
/// usernoted: a pending notification banner holds a system-sleep assertion; counting it
/// would flash the display on for every notification.
let relays: Set<String> = ["runningboardd", "launchd", "logd", "syslogd", "usernoted"]

struct Options {
    var interval: Double = 3
    var matchRE: NSRegularExpression?
    var anyMode = false
    var dryRun = false
    var verbose = false
    var headless = false
}

/// Persisted settings. A login-item launch has no argv (SMAppService starts the bundle,
/// not a command line), so a configured interval or filter only survives a reboot if it
/// comes from this file. Command line flags still override it.
struct SavedOptions: Codable {
    var interval: Double?
    var match: String?
    var anyMode: Bool?
    var dryRun: Bool?
}

func loadSavedOptions() -> SavedOptions? {
    guard let d = try? Data(contentsOf: optionsURL) else { return nil }
    return try? JSONDecoder().decode(SavedOptions.self, from: d)
}

func isTrigger(pid: pid_t, proc: String, assertion: String, opts: Options) -> Bool {
    if pid == ownPid { return false }
    if selfSustaining.contains(proc) { return false }
    if !opts.anyMode {
        if relays.contains(proc) { return false }
        if assertion.hasPrefix("osservice<") || assertion.hasPrefix("xpcservice<")
            || assertion.hasPrefix("extension<") { return false }
    }
    if let re = opts.matchRE {
        let ns = (proc.isEmpty ? assertion : proc) as NSString
        return re.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) != nil
    }
    return true
}

/// One IOKit read gives both the trigger list and whether *our* display assertion is
/// really there — the difference between "claims to hold" and "in effect".
struct Scan {
    var triggers: [Trigger] = []
    var ownDisplayHeld = false
}

func scan(_ opts: Options) -> Scan {
    var out = Scan()
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let byProc = raw?.takeRetainedValue() as? [Int32: [[String: Any]]] else { return out }
    let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String
    for (pid32, list) in byProc {
        let pid = pid_t(pid32)
        if pid == ownPid {
            out.ownDisplayHeld = list.contains { ($0["AssertType"] as? String) == displayType }
            continue
        }
        let proc = procName(pid)
        if selfSustaining.contains(proc) { continue }
        for a in list {
            guard (a["AssertType"] as? String) == (kIOPMAssertionTypePreventUserIdleSystemSleep as String),
                  let name = a["AssertName"] as? String,
                  isTrigger(pid: pid, proc: proc, assertion: name, opts: opts) else { continue }
            out.triggers.append((pid, proc, name))
        }
    }
    return out
}

/// Fresh single-purpose check, used right after acquiring so state.json never lies.
func ownDisplayAssertionPresent() -> Bool {
    scan(Options(interval: 0, matchRE: nil, anyMode: true)).ownDisplayHeld
}

// MARK: - start at login

/// One user-facing switch, several internal answers. The menu shows *whether* a
/// supervisor exists and never offers a choice of mechanism.
enum LoginState {
    case enabled             // registered with macOS, runs at login
    case needsApproval       // registered, but System Settings wants a human
    case off
    case launchdAgent        // a LaunchAgent plist owns us (make install); hands off
    case unavailable(String)  // cannot register from where we are running
}

func loginStateIsOn() -> Bool {
    switch loginState() {
    case .enabled, .needsApproval, .launchdAgent: return true
    case .off, .unavailable: return false
    }
}

/// Checked before touching SMAppService. A quarantined download runs from a randomized
/// read-only path (App Translocation), so registering it produces a login item whose
/// target disappears at the next reboot — fail loudly instead of registering garbage.
func loginBlocker() -> String? {
    let path = Bundle.main.bundlePath
    if path.contains("/AppTranslocation/") { return "move it to Applications first" }
    if path.contains("/.build/") { return "this is a dev build — use make install" }
    return nil
}

func loginState() -> LoginState {
    // A launchd agent and a login item are two supervisors for one binary: registering
    // both makes "Quit" mean different things depending on which one wins the race.
    // Whichever already exists wins; we do not stack a second one on top.
    if FileManager.default.fileExists(atPath: launchAgentURL.path) { return .launchdAgent }
    if let why = loginBlocker() { return .unavailable(why) }
    guard #available(macOS 13.0, *) else { return .unavailable("login items need macOS 13") }
    switch SMAppService.mainApp.status {
    case .enabled: return .enabled
    case .requiresApproval: return .needsApproval
    case .notRegistered, .notFound: return .off   // .notFound simply means "not registered yet"
    @unknown default: return .off
    }
}

/// nil on success, otherwise the text to show the user.
func setLoginItem(_ on: Bool) -> String? {
    // Never stack a login item on top of a LaunchAgent: two supervisors for one binary
    // means "Quit" behaves differently depending on which one wins the race.
    if FileManager.default.fileExists(atPath: launchAgentURL.path) {
        return "a LaunchAgent already starts displaykeep at login (make uninstall to remove it)"
    }
    guard #available(macOS 13.0, *) else { return "login items need macOS 13" }
    if let why = loginBlocker() { return why }
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
        let msg = (error as NSError).localizedDescription
        if logFD >= 0 { log("login item \(on ? "registration" : "removal") failed: \(msg)") }
        return msg
    }
    if logFD >= 0 { log("login item \(on ? "registered" : "removed")") }
    // register() can land in .requiresApproval and report success
    if on, case .needsApproval = loginState() {
        return "registered — approve displaykeep in System Settings > General > Login Items"
    }
    return nil
}

func openLoginItemsSettings() {
    let s = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    if let u = URL(string: s) { NSWorkspace.shared.open(u) }
}

func loginSummary() -> String {
    switch loginState() {
    case .enabled: return "on  — login item, registered with macOS"
    case .needsApproval: return "on  — approve it in System Settings > General > Login Items"
    case .off: return "off — \"Start at login\" in the menu bar, or: displaykeep login on"
    case .launchdAgent: return "on  — LaunchAgent \(launchAgentURL.path)"
    case .unavailable(let why): return "unavailable — \(why)"
    }
}

// MARK: - CLI

enum Status: Int32 {
    case holding = 0, armed = 1, paused = 2, notRunning = 3, failed = 4

    var label: String {
        switch self {
        case .holding: return "holding"
        case .armed: return "armed"
        case .paused: return "paused"
        case .notRunning: return "not running"
        case .failed: return "failed"
        }
    }
}

func pidAlive(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func nudgeDaemon() {
    guard let s = loadState(), pidAlive(s.pid), s.pid != ownPid else { return }
    kill(s.pid, SIGUSR1)
}

func triggerSummary(_ s: State) -> String {
    let names = s.triggers.prefix(3).map { t -> String in
        let p = t.proc.isEmpty ? "pid \(t.pid)" : "\(t.proc)(\(t.pid))"
        return p
    }
    let more = s.triggers.count > 3 ? " +\(s.triggers.count - 3) more" : ""
    return names.joined(separator: ", ") + more
}

func cliStatus(json: Bool) -> Never {
    guard let s = loadState() else {
        if json { print("{}") } else {
            print("not running  no state file at \(stateURL.path)")
        }
        exit(Status.notRunning.rawValue)
    }
    if json { print((try? String(contentsOf: stateURL, encoding: .utf8)) ?? "{}"); exit(Status.holding.rawValue) }

    let now = Date().timeIntervalSince1970
    let age = now - s.updatedAt
    let staleAfter = max(15, s.interval * 3)

    let status: Status
    let detail: String
    if !pidAlive(s.pid) {
        status = .notRunning
        detail = "pid \(s.pid) is gone (last update \(fmtDuration(age)) ago)"
    } else if age > staleAfter {
        status = .notRunning
        detail = "stalled — no update for \(fmtDuration(age)) (pid \(s.pid), interval \(fmtDuration(s.interval)))"
    } else if s.paused {
        status = .paused
        if let u = s.pausedUntil {
            detail = "display may sleep — resumes \(fmtClock(u)) (in \(fmtDuration(u - now)))"
        } else {
            detail = "display may sleep — until you resume"
        }
    } else if s.holding {
        status = .holding
        let held = fmtDuration(now - (s.holdingSince ?? now))
        let ver = s.verified ? "verified" : "UNVERIFIED — assertion missing from IOKit"
        detail = "display awake \(held), \(ver); triggers: \(triggerSummary(s))"
    } else if let err = s.lastError {
        status = .failed
        detail = err
    } else {
        status = .armed
        detail = "watching, no system-sleep assertions (display free to sleep)"
    }

    var line = status.label
    while line.count < 12 { line += " " }
    print(line + detail + (s.dryRun ? "  [dry run]" : ""))
    exit(status.rawValue)
}

func setPauseCLI(_ until: Double?) {
    writePause(until: until)
    nudgeDaemon()
    usleep(150_000)          // let the daemon release/acquire before reporting
}

func runCLI(_ cmd: String, _ args: [String]) -> Never {
    switch cmd {
    case "status", "stat":
        cliStatus(json: args.contains("--json") || args.contains("-j"))
    case "pause", "off":
        if let a = args.first(where: { !$0.hasPrefix("-") }) {
            guard let secs = parseDuration(a) else {
                FileHandle.standardError.write("displaykeep: bad duration '\(a)' (try 30, 30m, 45s, 1h30m)\n".data(using: .utf8)!)
                exit(64)
            }
            setPauseCLI(Date().timeIntervalSince1970 + secs)
        } else {
            setPauseCLI(nil)
        }
        cliStatus(json: false)
    case "resume", "on":
        removePauseFile()
        nudgeDaemon()
        usleep(150_000)
        cliStatus(json: false)
    case "toggle":
        if readPause().active { removePauseFile() } else { writePause(until: nil) }
        nudgeDaemon()
        usleep(150_000)
        cliStatus(json: false)
    case "login":
        switch args.first(where: { !$0.hasPrefix("-") }) ?? "status" {
        case "on", "off":
            if let err = setLoginItem(args.contains("on")) {
                FileHandle.standardError.write("displaykeep: \(err)\n".data(using: .utf8)!)
                exit(69)
            }
            print(loginSummary())
            exit(loginStateIsOn() ? 0 : 1)
        case "status":
            print(loginSummary())
            exit(loginStateIsOn() ? 0 : 1)
        default:
            FileHandle.standardError.write("displaykeep: login takes on|off|status\n".data(using: .utf8)!)
            exit(64)
        }
    default:
        FileHandle.standardError.write("displaykeep: unknown command '\(cmd)'\n".data(using: .utf8)!)
        exit(64)
    }
}

// MARK: - daemon

final class Daemon: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let opts: Options
    private var statusItem: NSStatusItem?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var lockFD: Int32 = -1

    private var heldID: IOPMAssertionID = 0
    private var holding = false
    private var verified = false
    private var paused = false
    private var pausedUntil: Double?
    private var triggers: [Trigger] = []
    private var wantsHold = false
    private var lastError: String?
    private var holdingSince: Double?
    private let startedAt = Date().timeIntervalSince1970
    private var tickCount = 0
    private var lastSignature = ""
    private var lastVisual = ""
    /// Result of the last login-item action, shown under the menu item. Kept separate
    /// from lastError: a failed registration is not a failed assertion.
    private var loginNote: String?

    init(opts: Options) {
        self.opts = opts
        super.init()
    }

    // MARK: lifecycle

    func start() {
        guard acquireLock() else {
            if let s = loadState(), pidAlive(s.pid) {
                log("already running as pid \(s.pid) — exiting")
            } else {
                log("could not take lock at \(lockURL.path) — exiting")
            }
            exit(0)
        }

        installSignalHandlers()
        openLogFile()

        if !opts.headless {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.imagePosition = .imageOnly
            let menu = NSMenu()
            menu.delegate = self
            statusItem?.menu = menu
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: opts.interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // one statement per flag: as a single concatenation this times out the type-checker
        // on the older Swift in the CI runner image
        var watching = "displaykeep \(displaykeepVersion) — watching (interval \(fmtDuration(opts.interval))"
        if opts.dryRun { watching += ", dry run" }
        if let re = opts.matchRE { watching += ", match /\(re.pattern)/" }
        if opts.anyMode { watching += ", any mode" }
        if opts.headless { watching += ", headless" }
        log(watching + ")")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        release()
        try? FileManager.default.removeItem(at: stateURL)
        log("stopped — display may sleep again")
    }

    private func acquireLock() -> Bool {
        ensureSupportDir()
        lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return false }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            close(lockFD)
            lockFD = -1
            return false
        }
        return true
    }

    private func installSignalHandlers() {
        for sig in [SIGUSR1, SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGUSR1 {
                    self.tick()
                } else {
                    log("signal \(sig) — shutting down")
                    if self.opts.headless {
                        self.release()
                        try? FileManager.default.removeItem(at: stateURL)
                        exit(0)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
            src.resume()
            signals.append(src)
        }
    }

    // MARK: assertion

    private func acquire() {
        let r = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "displaykeep: another process holds a system-sleep assertion" as CFString,
            &heldID)
        if r == kIOReturnSuccess {
            holding = true
            holdingSince = Date().timeIntervalSince1970
            lastError = nil
            log("display ON-hold taken (assertion \(heldID))")
        } else {
            holding = false
            lastError = "IOPMAssertionCreateWithName failed: 0x\(String(r, radix: 16))"
            log(lastError!)
        }
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(heldID)
        holding = false
        verified = false
        holdingSince = nil
        log("display assertion released — display may sleep again")
    }

    // MARK: tick

    private func tick() {
        let now = Date().timeIntervalSince1970
        tickCount += 1

        // pause file: an expired deadline resumes by itself
        let wasPaused = paused
        var p = readPause(now: now)
        if !p.active && p.until != nil {
            removePauseFile()
            if wasPaused { log("pause expired — resuming") }
            p = PauseFile()
        }
        if p.active != wasPaused {
            log(p.active ? "paused" : "resumed")
        }
        paused = p.active
        pausedUntil = p.until

        let s = scan(opts)
        triggers = s.triggers.sorted { $0.pid < $1.pid }
        wantsHold = !paused && !triggers.isEmpty

        // an assertion that silently vanished gets re-taken on the next pass
        if holding && !s.ownDisplayHeld {
            holding = false
            heldID = 0
            verified = false
            holdingSince = nil
            lastError = "display assertion disappeared — re-acquiring"
            log(lastError!)
        }

        if wantsHold && !holding {
            if opts.dryRun {
                lastError = nil
            } else {
                acquire()
                if holding { verified = ownDisplayAssertionPresent() }
            }
        } else if !wantsHold && holding {
            release()
            lastError = nil
        }

        if verboseEmit(signature: s.triggers) {
            for t in triggers {
                log("trigger \(t.pid)(\(t.proc)): \(t.assertion)")
            }
            if wantsHold && opts.dryRun { log("would hold display awake") }
        }

        writeState()
        refreshUI()
    }

    private func verboseEmit(signature hits: [Trigger]) -> Bool {
        let sig = hits.map { "\($0.pid):\($0.assertion)" }.sorted().joined(separator: "|")
        defer { lastSignature = sig }
        return opts.verbose || sig != lastSignature
    }

    private func writeState() {
        saveState(State(
            version: displaykeepVersion,
            pid: getpid(),
            holding: holding,
            verified: verified,
            paused: paused,
            pausedUntil: pausedUntil,
            interval: opts.interval,
            match: opts.matchRE?.pattern,
            anyMode: opts.anyMode,
            dryRun: opts.dryRun,
            triggers: triggers.map { TriggerRec(pid: $0.pid, proc: $0.proc, assertion: $0.assertion) },
            holdingSince: holdingSince,
            startedAt: startedAt,
            updatedAt: Date().timeIntervalSince1970,
            tick: tickCount,
            lastError: lastError))
    }

    // MARK: UI

    private enum Visual: String, CaseIterable {
        case holding, armed, paused, failed

        var symbol: String {
            switch self {
            case .holding: return "cup.and.saucer.fill"
            case .armed: return "cup.and.saucer"
            case .paused: return "pause.circle"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    private func visual() -> Visual {
        if paused { return .paused }
        if lastError != nil && !holding { return .failed }
        if opts.dryRun { return wantsHold ? .holding : .armed }
        return holding ? .holding : .armed
    }

    private func stateLine() -> String {
        switch visual() {
        case .paused:
            if let u = pausedUntil {
                return "Paused — resumes \(fmtClock(u)) (in \(fmtDuration(u - Date().timeIntervalSince1970)))"
            }
            return "Paused until you resume"
        case .failed:
            return "Failed: \(lastError ?? "unknown")"
        case .holding:
            if opts.dryRun { return "Dry run — would keep the display awake" }
            let held = fmtDuration(Date().timeIntervalSince1970 - (holdingSince ?? startedAt))
            let ver = verified ? "verified" : "unverified"
            return "Keeping display awake — \(held), \(ver)"
        case .armed:
            return "Watching — nothing is holding the system awake"
        }
    }

    /// The four states are four different SF Symbols, and so four different widths: 20pt for
    /// the cup, 17 for the warning triangle, 15 for `pause.circle`. A variable-length status
    /// item takes its width from its image, so left alone the item — and with it every menu
    /// bar item to its left — shifted 4pt every time the state changed. Each glyph is drawn
    /// into a canvas as wide as the widest of them; its ink is already centred inside the
    /// symbol's own bounds, so the glyph stays put and the item keeps one width.
    private lazy var statusGlyphs: [Visual: NSImage] = {
        var symbols: [(Visual, NSImage)] = []
        for v in Visual.allCases {
            guard let img = NSImage(systemSymbolName: v.symbol,
                                    accessibilityDescription: "displaykeep: \(v.rawValue)") else { continue }
            img.isTemplate = true
            symbols.append((v, img))
        }
        let width = symbols.map { $0.1.size.width }.max() ?? 0
        var padded: [Visual: NSImage] = [:]
        for (v, img) in symbols {
            let size = NSSize(width: width, height: img.size.height)
            let canvas = NSImage(size: size, flipped: false) { _ in
                img.draw(in: NSRect(x: (size.width - img.size.width) / 2,
                                    y: (size.height - img.size.height) / 2,
                                    width: img.size.width, height: img.size.height))
                return true
            }
            canvas.isTemplate = true
            padded[v] = canvas
        }
        return padded
    }()

    private func iconImage(_ v: Visual) -> NSImage? {
        statusGlyphs[v]
    }

    private func refreshUI() {
        guard let button = statusItem?.button else { return }
        let v = visual()
        let line = stateLine()
        let key = "\(v.rawValue)|\(line)"
        guard key != lastVisual else { return }
        lastVisual = key

        button.image = iconImage(v)
        // Leave the template tint alone so the glyph follows the menu bar appearance; an
        // explicit .secondaryLabelColor reads as near-black on a dark/translucent bar.
        // "Not currently doing anything" is expressed by the disabled look, which is how
        // macOS dims status items in either appearance.
        button.contentTintColor = (v == .failed) ? .systemOrange : nil
        button.appearsDisabled = (v == .armed || v == .paused)
        var tip = "displaykeep — " + line
        if let reason = triggers.first {
            tip += "\n" + reason.proc + ": " + reason.assertion
        }
        button.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: stateLine(), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        for t in triggers.prefix(4) {
            var name = t.assertion
            if name.count > 48 { name = String(name.prefix(47)) + "…" }
            let item = NSMenuItem(title: "   \(t.proc)(\(t.pid)) — \(name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if triggers.count > 4 {
            let more = NSMenuItem(title: "   +\(triggers.count - 4) more", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: paused ? "Resume keeping display awake" : "Pause keeping display awake",
            action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)

        let forItem = NSMenuItem(title: "Pause for…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, secs) in [("15 minutes", 900.0), ("30 minutes", 1800.0),
                              ("1 hour", 3600.0), ("4 hours", 14400.0)] {
            let item = NSMenuItem(title: label, action: #selector(pauseFor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            sub.addItem(item)
        }
        forItem.submenu = sub
        menu.addItem(forItem)

        menu.addItem(.separator())

        menu.addItem(loginMenuItem())
        if let note = loginNote {
            let n = NSMenuItem(title: "   \(note)", action: nil, keyEquivalent: "")
            n.isEnabled = false
            menu.addItem(n)
        }

        menu.addItem(.separator())

        var info = "poll \(fmtDuration(opts.interval)) · "
        info += opts.matchRE.map { "filter /\($0.pattern)/" } ?? (opts.anyMode ? "any process" : "user processes")
        if opts.dryRun { info += " · dry run" }
        info += " · ticks \(tickCount)"
        let infoItem = NSMenuItem(title: info, action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        let logItem = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        // No About window, and no About item either: this is a menu bar extra with no
        // windows to put one in, and the whole point of an About box here is the version
        // number — which a bug report also needs the OS release next to, since the filters
        // follow IOKit internals that move between macOS releases.
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let versionItem = NSMenuItem(
            title: "displaykeep \(displaykeepVersion) · macOS \(osv.majorVersion).\(osv.minorVersion)",
            action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quit = NSMenuItem(title: "Quit displaykeep", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// One item, no mechanism choice. The state tells the truth about who is supervising
    /// us: unchecked (nothing), checked (macOS login item), checked+disabled (a launchd
    /// agent wrote a plist), or disabled with a reason we cannot register from here.
    private func loginMenuItem() -> NSMenuItem {
        let item: NSMenuItem
        switch loginState() {
        case .enabled:
            item = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
            item.state = .on
        case .needsApproval:
            // Clicking must not silently unregister what the user just asked for; send
            // them to the only place that can actually fix it.
            item = NSMenuItem(title: "Start at login — approve in System Settings…",
                              action: #selector(openLoginItems), keyEquivalent: "")
            item.state = .on
        case .off:
            item = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
            item.state = .off
        case .launchdAgent:
            item = NSMenuItem(title: "Start at login — launchd agent", action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
        case .unavailable(let why):
            item = NSMenuItem(title: "Start at login — \(why)", action: nil, keyEquivalent: "")
            item.state = .off
            item.isEnabled = false
        }
        item.target = self
        return item
    }

    @objc private func toggleLogin() {
        loginNote = setLoginItem(!loginStateIsOn())
        if loginNote != nil { NSSound.beep() }
    }

    @objc private func openLoginItems() {
        openLoginItemsSettings()
    }

    @objc private func togglePause() {
        if paused {
            removePauseFile()
        } else {
            writePause(until: nil)
        }
        tick()
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        writePause(until: Date().timeIntervalSince1970 + secs)
        tick()
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - main

func usage() -> Never {
    print("""
    usage:
      displaykeep [options]              run the watcher and the menu bar icon
      displaykeep status [--json]        exit 0 holding / 1 armed / 2 paused / 3 dead / 4 failed
      displaykeep pause [duration]       pause (default indefinitely; 30 = minutes, 45s, 1h30m)
      displaykeep resume                 resume
      displaykeep toggle                 flip paused state
      displaykeep login [on|off|status]  start at login (login item / launchd agent)

    options:
      -i <secs>   poll interval (default 3)
      -m <regexp> only processes whose name (or assertion) matches
      -a          any process, no filtering (noisy)
      -n          dry run: report only, never take the assertion
      -v          verbose
      -x          headless: no menu bar icon
      -V          print the version
      -h          this help

    files: \(supportDir.path)
           options.json  interval / match, read when launched with no arguments
    log:   \(logPath)   (~1 MiB, truncated at startup)
    """)
    exit(0)
}

var opts = Options()
// Saved settings first, explicit flags on top: a login-item launch has no argv, so
// options.json is the only way interval/match can survive a reboot.
if let saved = loadSavedOptions() {
    if let i = saved.interval { opts.interval = max(1, i) }
    if let m = saved.match { opts.matchRE = try? NSRegularExpression(pattern: m) }
    if saved.anyMode == true { opts.anyMode = true }
    if saved.dryRun == true { opts.dryRun = true }
}

var argv = Array(CommandLine.arguments.dropFirst())
while let a = argv.first {
    argv.removeFirst()
    switch a {
    case "-i": if let v = argv.first, let d = Double(v) { opts.interval = max(1, d); argv.removeFirst() }
    case "-m": if let v = argv.first { opts.matchRE = try? NSRegularExpression(pattern: v); argv.removeFirst() }
    case "-a": opts.anyMode = true
    case "-n": opts.dryRun = true
    case "-v": opts.verbose = true
    case "-x", "--headless": opts.headless = true
    case "-V", "--version", "version": print("displaykeep \(displaykeepVersion)"); exit(0)
    case "status", "stat", "pause", "off", "resume", "on", "toggle", "login":
        runCLI(a, argv)                     // never returns; does not touch AppKit
    case "-h", "--help": usage()
    default:
        FileHandle.standardError.write("displaykeep: unknown option \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

let daemon = Daemon(opts: opts)

if opts.headless {
    daemon.start()
    dispatchMain()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = daemon
    daemon.start()
    app.run()
}
