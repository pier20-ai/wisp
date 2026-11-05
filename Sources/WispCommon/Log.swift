// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import os

/// How much a log line matters. Debug is off unless verbose logging is on (Settings > Verbose
/// logging, `defaults write <domain> verboseLogging -bool YES`, or WISP_VERBOSE=1).
public enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warning, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// The column in the log file (five wide, so the columns after it line up).
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warning: return "WARN "
        case .error: return "ERROR"
        }
    }

    var osType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// What a log line is about. Also the unified log's category (`log stream --predicate
/// 'subsystem == "<bundle ID>" && category == "viewer"'`).
public enum LogCategory: String, CaseIterable, Sendable {
    /// Launch, settings, the menu bar item, windows of the app itself.
    case app
    /// The viewer: sessions, connecting, windows, decoding.
    case viewer
    /// The host: sharing, sessions, streams.
    case host
    /// Sockets: connection states, paths, listeners, datagrams.
    case net
    /// Tailscale: the LocalAPI or CLI used, peers, whois.
    case tailnet
    /// The host's decision on who may connect.
    case access
    /// Phantom apps: making, launching, their windows.
    case phantom
    /// The Unix socket between the app and its phantoms.
    case ipc
    /// Mirrored menu bars: reading and pressing menus.
    case menu
    /// ScreenCaptureKit.
    case capture
    /// VideoToolbox encoders and rate control.
    case encode
    /// Virtual displays.
    case vdisplay
    /// Replayed input, raising, moving and resizing windows.
    case input
    /// Finding the tailnet's Macs and probing them.
    case discovery
    /// The command line (`wisp send`, `wisp view`, …).
    case cli
    /// Clipboard sync between viewer and host (types and sizes only, never contents).
    case clipboard
}

/// The log: one line per event, `<date> <time.ms> [pid] LEVEL category  message`, appended to this
/// process's file in the log directory (`Log.fileName`), mirrored to the unified log (subsystem
/// Brand.bundleID, category = the category) and to stderr, and handed to `Log.hook` (the host
/// window's log view). Thread-safe: call it from any queue; the file is written on its own queue.
///
/// Files (Brand.logDirectory): `wisp.log` (the app: viewer, host and UI), `phantom-<App>.log` (each
/// phantom app), `cli.log` (the CLI commands), `latency.log` (the viewer's 5 s latency lines),
/// `stats.csv` (the host's 5 s stats). Each rotates at 5 MB, keeping three old files (`.1` … `.3`).
public enum Log {
    /// The file this process logs to, in the log directory. Set it once, first thing (main.swift).
    nonisolated(unsafe) public static var fileName = "wisp.log"
    /// Also write each line to stderr (the CLI's terminal; nowhere when the app is opened from Finder).
    nonisolated(unsafe) public static var echoToStderr = true
    /// Called with every line that's logged (on the caller's queue), after it's been formatted.
    nonisolated(unsafe) public static var hook: ((LogLevel, LogCategory, String) -> Void)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _verbose: Bool = {
        if let v = ProcessInfo.processInfo.environment["WISP_VERBOSE"], !v.isEmpty { return v != "0" }
        return Brand.defaults.bool(forKey: verboseKey)
    }()

    /// The defaults key of the "Verbose logging" setting.
    public static let verboseKey = "verboseLogging"

    /// Whether debug lines are logged. Starts from WISP_VERBOSE (if set) or the setting.
    public static var verbose: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _verbose }
        set { lock.lock(); _verbose = newValue; lock.unlock() }
    }

    public static func debug(_ c: LogCategory, _ m: @autoclosure () -> String) { if verbose { write(.debug, c, m()) } }
    public static func info(_ c: LogCategory, _ m: @autoclosure () -> String) { write(.info, c, m()) }
    public static func warning(_ c: LogCategory, _ m: @autoclosure () -> String) { write(.warning, c, m()) }
    public static func error(_ c: LogCategory, _ m: @autoclosure () -> String) { write(.error, c, m()) }

    /// A failed `try`, at warning: "<what>: <error>".
    public static func failed(_ c: LogCategory, _ what: String, _ e: Error) {
        write(.warning, c, "\(what): \(describe(e))")
    }

    /// An error's description with its domain and code, which `"\(e)"` alone often hides.
    public static func describe(_ e: Error) -> String {
        let ns = e as NSError
        let text = ns.localizedDescription
        return "\(text) [\(ns.domain) \(ns.code)]"
    }

    public static func write(_ level: LogLevel, _ c: LogCategory, _ m: String) {
        let line = "\(timestamp()) [\(pid)] \(level.label) \(c.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(m)"
        loggers[c]?.log(level: level.osType, "\(m, privacy: .public)")
        if echoToStderr { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        hook?(level, c, line)
        LogFile.append(fileName, line)
    }

    /// Waits until every line logged so far is in its file (before exit).
    public static func flush() { LogFile.flush() }

    /// The log directory and this process's file.
    public static var fileURL: URL { LogFile.dir.appendingPathComponent(fileName) }

    /// The last `n` lines of a log file (default: this process's), with its rotated files before it
    /// if it's short. Empty if there's none.
    public static func tail(_ n: Int, file: String? = nil) -> [String] {
        flush()
        let name = file ?? fileName
        var lines: [String] = []
        for i in 0 ... LogFile.keep {
            let url = LogFile.dir.appendingPathComponent(i == 0 ? name : "\(name).\(i)")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) + lines
            if lines.count >= n { break }
        }
        return Array(lines.suffix(n))
    }

    private static let pid = getpid()
    private static let loggers: [LogCategory: Logger] = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
        ($0, Logger(subsystem: Brand.bundleID, category: $0.rawValue))
    })

    /// "2026-11-04 12:34:56.789", local time. Cheaper than a DateFormatter on every line.
    public static func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var t = tv.tv_sec
        var tm = tm()
        localtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, Int(tv.tv_usec / 1000))
    }
}

/// Appends lines to files in the log directory (Brand.logDirectory), on one serial queue. Each file
/// rotates at `maxBytes` (name → name.1 → … → name.<keep>, the oldest dropped). Several processes
/// may append to one file: writes use O_APPEND, and a file another process rotated is reopened.
public enum LogFile {
    private static let q = DispatchQueue(label: "wisp.logfile")
    public static let dir = Brand.logDirectory
    public static let maxBytes: off_t = 5 << 20
    /// Rotated files kept per log; `WISP_LOG_KEEP` raises it (tests and soaks keep everything).
    public static let keep = max(1, Int(ProcessInfo.processInfo.environment["WISP_LOG_KEEP"] ?? "") ?? 3)
    nonisolated(unsafe) private static var files: [String: RotatingFile] = [:] // on q
    nonisolated(unsafe) private static var reportedFailure = false // on q

    /// Appends `line` to `name`. A new file (also after a rotation) starts with `header`, if any.
    public static func append(_ name: String, _ line: String, header: String? = nil) {
        q.async {
            let f: RotatingFile
            if let existing = files[name] { f = existing } else {
                f = RotatingFile(url: dir.appendingPathComponent(name), header: header)
                files[name] = f
            }
            if let failure = f.write(line + "\n"), !reportedFailure {
                // Can't use Log here (it writes here). Once, so a full disk doesn't flood stderr.
                reportedFailure = true
                FileHandle.standardError.write(Data("log: can't write \(f.url.path): \(failure)\n".utf8))
            }
        }
    }

    /// Waits until everything appended so far is written.
    public static func flush() { q.sync {} }
}

/// One log file, its descriptor kept open. Only used on LogFile's queue.
private final class RotatingFile {
    let url: URL
    let header: String?
    private var fd: Int32 = -1
    private var size: off_t = 0
    private var writes = 0

    init(url: URL, header: String?) {
        self.url = url
        self.header = header
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Writes `text`; returns why it couldn't, if it couldn't.
    func write(_ text: String) -> String? {
        writes += 1
        // Every 64 writes: has another process rotated (renamed) the file under us?
        if fd >= 0, writes % 64 == 0, movedAway() { close(fd); fd = -1 }
        if fd < 0, let e = open() { return e }
        if size >= LogFile.maxBytes {
            rotate()
            if let e = open() { return e }
        }
        let data = Array(text.utf8)
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n < 0 { return String(cString: strerror(errno)) }
        size += off_t(n)
        return nil
    }

    private func open() -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return "\(error.localizedDescription)"
        }
        fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return String(cString: strerror(errno)) }
        var st = stat()
        size = fstat(fd, &st) == 0 ? st.st_size : 0
        if size == 0, let header {
            let h = Array((header + "\n").utf8)
            let n = h.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { size += off_t(n) }
        }
        return nil
    }

    private func movedAway() -> Bool {
        var mine = stat(), there = stat()
        guard fstat(fd, &mine) == 0 else { return true }
        guard stat(url.path, &there) == 0 else { return true }
        return mine.st_ino != there.st_ino || mine.st_dev != there.st_dev
    }

    private func rotate() {
        if fd >= 0 { close(fd); fd = -1 }
        let path = url.path
        // Another process may have just rotated it: only rotate a file that's still big.
        var st = stat()
        guard stat(path, &st) == 0, st.st_size >= LogFile.maxBytes else { return }
        unlink("\(path).\(LogFile.keep)")
        for i in stride(from: LogFile.keep - 1, through: 1, by: -1) { rename("\(path).\(i)", "\(path).\(i + 1)") }
        rename(path, "\(path).1")
    }
}
