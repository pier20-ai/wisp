// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WispCommon

// Stall detection shared by the host and the viewer: fault injection for tests, one summary line
// per stall episode, and a watch on the main thread. What each side checks is in Host/Health.swift
// (the host's pipelines), Viewer/Client.swift (reassembly, decoding, the UDP path) and
// Viewer/ViewerWindow.swift (decoded frames reaching the screen). How to read the lines:
// docs/testing.md "Stalls".

/// Faults a test can inject, from WISP_FAULT: a comma-separated list of `name` or `name=value`, e.g.
/// `WISP_FAULT=encoder-stall` (host) or `WISP_FAULT=udp-drop-all-for=5,decoder-fail-once` (viewer).
/// Read once at start-up; phantoms inherit it. Each fault logs a warning when it fires, so a log
/// never hides that it was injected.
enum Fault {
    private static let items: [String: String] = {
        guard let v = ProcessInfo.processInfo.environment["WISP_FAULT"], !v.isEmpty else { return [:] }
        var d: [String: String] = [:]
        for part in v.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let k = kv.first, !k.isEmpty { d[k] = kv.count > 1 ? kv[1] : "" }
        }
        if !d.isEmpty { Log.warning(.app, "fault injection on (WISP_FAULT=\(v))") }
        return d
    }()

    static func has(_ name: String) -> Bool { items[name] != nil }
    /// The fault's number (`name=5`), `fallback` if it's set without one, nil if it isn't set.
    static func number(_ name: String, default fallback: Double) -> Double? {
        guard let v = items[name] else { return nil }
        return Double(v) ?? fallback
    }
}

/// One stall of one thing (a stream, an encoder, the video path, the main thread): a warning when
/// it starts (what is stuck and the evidence), each recovery step taken, and one line when it ends
/// (how long, and what fixed it). Details go to debug. Not thread-safe: use it on one queue.
struct StallEpisode {
    let subject: String
    let category: LogCategory
    private(set) var since: Date?
    private(set) var actions: [String] = []
    private var lastStartLog = Date.distantPast
    private var suppressed = 0

    init(_ subject: String, _ category: LogCategory) { self.subject = subject; self.category = category }

    var active: Bool { since != nil }
    var duration: TimeInterval { since.map { Date().timeIntervalSince($0) } ?? 0 }

    /// The stall started (`at`: when it really began, if that was earlier than now). Logs once per
    /// episode, and at most one start line every 10 s per subject (a flapping stall is counted).
    mutating func begin(_ what: String, at: Date = Date()) {
        guard since == nil else { return }
        since = at
        actions = []
        if Date().timeIntervalSince(lastStartLog) < 10 { suppressed += 1; return }
        lastStartLog = Date()
        let more = suppressed > 0 ? " (\(suppressed) shorter stalls in the last few seconds not logged)" : ""
        suppressed = 0
        Log.warning(category, "STALL \(subject): \(what)\(more)")
    }

    /// A recovery step taken during the stall.
    mutating func act(_ step: String) {
        guard since != nil else { return }
        actions.append(step)
        Log.info(category, "STALL \(subject): recovering: \(step)")
    }

    /// The stall is over: logs its length and what ended it (`how`), with the steps taken.
    mutating func end(_ how: String) {
        guard let s = since else { return }
        let took = Date().timeIntervalSince(s)
        let steps = actions.isEmpty ? "" : " (steps taken: \(actions.joined(separator: "; ")))"
        Log.info(category, String(format: "STALL %@: over after %.1f s: %@%@", subject, took, how, steps))
        since = nil
        actions = []
    }
}

/// Notices when the main thread stops answering (a stuck main thread means no frame reaches the
/// screen and no input is read): pings it every 0.25 s from a background queue, logs a STALL line
/// once it has been silent 1 s and one more when it answers. Start it once per process.
enum MainThreadWatch {
    private static let q = DispatchQueue(label: "wisp.mainwatch")
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var pingSent: UInt64 = 0 // q; 0 = none outstanding
    nonisolated(unsafe) private static var episode = StallEpisode("main thread", .app)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answeredAt: UInt64 = nowMicros()

    /// When the main thread last answered (µs, nowMicros clock). Any thread.
    static var lastAnswer: UInt64 { lock.lock(); defer { lock.unlock() }; return answeredAt }
    /// How long the main thread has been unresponsive, if it is (seconds; 0 when it's fine). Any thread.
    static var blockedFor: Double {
        let a = lastAnswer, now = nowMicros()
        return now > a + 300_000 ? Double(now - a) / 1_000_000 : 0
    }

    static func start() {
        q.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25)
            t.setEventHandler { tick() }
            t.resume()
            timer = t
        }
    }

    private static func tick() {
        let now = nowMicros()
        if pingSent != 0 {
            let waited = Double(now - pingSent) / 1_000_000
            if waited > 1, !episode.active {
                episode.begin(String(format: "the main thread hasn't answered for %.1f s: nothing reaches the screen, no input is read", waited),
                              at: Date(timeIntervalSinceNow: -waited))
            }
            return
        }
        pingSent = now
        DispatchQueue.main.async {
            let answered = nowMicros()
            lock.lock(); answeredAt = answered; lock.unlock()
            q.async {
                pingSent = 0
                if episode.active { episode.end("the main thread answers again") }
            }
        }
    }
}

/// "1.2 s ago" for a µs timestamp (nowMicros clock), "never" for 0.
func ago(_ t: UInt64, now: UInt64 = nowMicros()) -> String {
    guard t > 0 else { return "never" }
    return String(format: "%.1f s ago", Double(now > t ? now - t : 0) / 1_000_000)
}
