// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// `wisp e2e <host>`: the end-to-end input and freshness test (docs/testing.md "End-to-end input
// and freshness"). The viewer side, in this process: it connects as the viewer, opens the test
// windows in ordinary in-process viewer windows (ViewerController, RemoteView: the code a user's
// events go through) and feeds them NSEvents as AppKit would deliver them: trackpad and Magic
// Mouse scroll gestures with their phases and momentum, smooth-scrolling mice, wheel ticks in
// lines, fast flicks, clicks, double clicks, drags, typing, shortcuts, local resizes. Then it
// reads what the host's test windows received (WispProbe.app on a real host, the synthetic host's
// WISP_INPUT_LOG over loopback: InputRecord lines) and checks every gesture, click and key arrived
// as sent. All along it reads the frame counter the test windows draw (FrameCode) from the frames
// put on screen, and fails on a frozen picture, a STALL line or an error. Main queue only.

struct E2EOptions {
    var host = ""
    var windows: [UInt32] = []
    var app: String?
    var maxWindows = 3
    var scenarios: Set<String> = ["scroll", "click", "key", "resize"]
    var soakMinutes = 0.0
    var seed = UInt64.random(in: 1 ... 999_999)
    var hostLog: String?
    var hostLogCmd: String?
    var maxFreeze = 1.0
    var settle = 2.0
    var verbose = false
}

/// The test's NSApplication: input that doesn't come from the test (someone using this Mac, whose
/// pointer crosses the test windows or who types while they're in front) is dropped before any
/// window sees it, so it can't be taken for a fidelity bug.
final class E2EApp: NSApplication {
    private static var injecting = false
    private(set) static var ignored = 0
    private static let userInput: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        .magnify, .swipe, .rotate, .gesture, .smartMagnify, .pressure,
    ]

    /// The test's own events go through here.
    static func inject(_ e: NSEvent) {
        injecting = true
        defer { injecting = false }
        NSApp.sendEvent(e)
    }

    override func sendEvent(_ e: NSEvent) {
        if !Self.injecting, Self.userInput.contains(e.type) {
            if Self.ignored == 0 { Log.info(.cli, "e2e: ignoring input from this Mac's own mouse and keyboard while the test runs") }
            Self.ignored += 1
            return
        }
        super.sendEvent(e)
    }
}

/// A small seeded generator, so a failing soak can be run again exactly (`--seed`).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func runE2E(_ arguments: [String]) -> Never {
    var o = E2EOptions()
    var args = arguments[...]
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("\(flag) needs a value\n\n\(usage)") }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--windows": o.windows = value(a).split(separator: ",").compactMap { UInt32($0) }
        case "--app": o.app = value(a)
        case "--max-windows": o.maxWindows = max(1, Int(value(a)) ?? 3)
        case "--scenarios": o.scenarios = Set(value(a).split(separator: ",").map(String.init))
        case "--soak": o.soakMinutes = Double(value(a)) ?? 1
        case "--seed": o.seed = UInt64(value(a)) ?? o.seed
        case "--host-log": o.hostLog = value(a)
        case "--host-log-cmd": o.hostLogCmd = value(a)
        case "--max-freeze": o.maxFreeze = Double(value(a)) ?? 1
        case "--settle": o.settle = Double(value(a)) ?? 2
        case "-v", "--verbose": o.verbose = true
        default:
            guard !a.hasPrefix("-"), o.host.isEmpty else { fail(usage) }
            o.host = a
        }
    }
    guard !o.host.isEmpty else { fail(usage) }
    if o.hostLog == nil, o.hostLogCmd == nil { o.hostLog = ProcessInfo.processInfo.environment["WISP_INPUT_LOG"] }
    guard o.hostLog != nil || o.hostLogCmd != nil else {
        fail("e2e needs the host's input log: --host-log <file> (loopback), --host-log-cmd \"ssh … cat …\", or WISP_INPUT_LOG")
    }
    Log.echoToStderr = false // the runner prints its own lines; the log file has everything
    let app = E2EApp.shared // first use: this class becomes NSApp
    app.setActivationPolicy(.regular)
    let runner = E2ERunner(o)
    withExtendedLifetime(runner) {
        DispatchQueue.main.async { runner.start() }
        app.run()
    }
    exit(0)
}

// MARK: - What was sent

/// One scroll gesture (or wheel burst) as sent: where, what kind, what its events said.
final class SentGesture {
    let kind: String
    let window: UInt32
    let at: CGPoint // remote points, top-left origin
    /// When its first event was sent, in seconds from the round's start.
    var start = 0.0
    var precise = true
    var sum = CGPoint.zero
    var events = 0
    /// The (phase, momentum) of every event that isn't a plain "changed", in order.
    var boundaries: [[Int]] = []
    init(kind: String, window: UInt32, at: CGPoint) { self.kind = kind; self.window = window; self.at = at }
    func add(_ e: NSEvent) {
        precise = e.hasPreciseScrollingDeltas
        sum.x += e.scrollingDeltaX; sum.y += e.scrollingDeltaY
        events += 1
        let p = Int(e.phase.rawValue), m = Int(e.momentumPhase.rawValue)
        if (p != 0 && p != 4) || (m != 0 && m != 4) { boundaries.append([p, m]) }
    }
}

/// A click, drag or key as the host should see it, in order per window.
enum SentInput: CustomStringConvertible {
    case button(ev: String, button: Int, clicks: Int, at: CGPoint)
    case drag(to: CGPoint)
    case key(ev: String, code: Int, mods: Int, chars: String?)
    var description: String {
        switch self {
        case .button(let ev, let b, let n, let p): "\(ev) button \(b) ×\(n) at \(Int(p.x)),\(Int(p.y))"
        case .drag(let p): "drag to \(Int(p.x)),\(Int(p.y))"
        case .key(let ev, let c, let m, let ch): "\(ev) \(c) mods 0x\(String(m, radix: 16))" + (ch.map { " \"\($0)\"" } ?? "")
        }
    }
}

/// Everything one round sends, per host window.
final class Round {
    let name: String
    var gestures: [UInt32: [SentGesture]] = [:]
    var inputs: [UInt32: [SentInput]] = [:]
    var resized: [UInt32: CGSize] = [:]
    var steps: [(t: Double, run: () -> Void)] = []
    /// When scrolling (and nothing else) was being sent: raises then were caused by scrolling.
    var scrollSpans: [(window: UInt32, from: Double, to: Double)] = []
    var length = 0.0
    var startedAt = Date()
    init(_ name: String) { self.name = name }
}

// MARK: - Freshness

/// Frames shown in one window and the counter read from them.
final class Freshness {
    var shown = 0, decoded = 0, unreadable = 0, advances = 0
    var last: Int?
    var lastAdvance = Date()
    var maxFreeze = 0.0
    var freezeAt: Date?
    func frame(_ value: Int?) {
        shown += 1
        guard let v = value else { unreadable += 1; return }
        decoded += 1
        if let l = last, FrameCode.advance(from: l, to: v) == 0 { return }
        if last != nil { advances += 1 }
        last = v
        tick()
        lastAdvance = Date()
    }
    func tick() {
        let f = Date().timeIntervalSince(lastAdvance)
        if f > maxFreeze { maxFreeze = f; freezeAt = lastAdvance }
    }
}

// MARK: - The runner

final class E2ERunner {
    let o: E2EOptions
    var rng: SeededRandom
    private var session: ViewerSession!
    private var targets: [ViewerController] = []
    private var fresh: [UInt32: Freshness] = [:]
    private var failures: [String] = []
    private var warnings: [String] = []
    private var logProblems: [String] = []
    private var watch: DispatchSourceTimer?
    private var startedAt = Date()
    private var roundNo = 0
    private var soakUntil: Date?
    private var totals = (gestures: 0, inputs: 0, rounds: 0)

    init(_ o: E2EOptions) {
        self.o = o
        rng = SeededRandom(state: o.seed)
    }

    private func say(_ s: String) { print(s); fflush(stdout); Log.info(.cli, "e2e: \(s)") }
    private func fail(_ s: String) { failures.append(s); say("FAIL " + s) }
    private func warn(_ s: String) { warnings.append(s); say("warn " + s) }

    func start() {
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        say("e2e: \(o.host), seed \(o.seed)" + (o.soakMinutes > 0 ? ", soak \(o.soakMinutes) min" : "") + ", host log: \(o.hostLogCmd ?? o.hostLog ?? "?")")
        // Any STALL or error line in this process fails the run.
        Log.hook = { [weak self] level, _, line in
            guard line.contains("STALL") && level == .warning || level == .error else { return }
            DispatchQueue.main.async { self?.logProblems.append(line) }
        }
        let s = ViewerSession(host: o.host, phantoms: false, ownMenu: false)
        s.onClose = { [weak self] why in self?.finish("the session ended" + (why.map { ": \($0)" } ?? "")) }
        session = s
        s.show()
        watch = every(0.25) { [weak self] in self?.fresh.values.forEach { $0.tick() } }
        wait("the host's window list", timeout: 15, until: { [weak self] in self?.session.isConnected == true && self?.session.windowList != nil },
             then: { [weak self] in self?.openTargets() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.session.client.requestWindowList() }
    }

    /// Polls `until` every 0.1 s; fails the run after `timeout`.
    private func wait(_ what: String, timeout: Double, until: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if until() { then(); return }
            if Date() > deadline { finish("timed out waiting for \(what)"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private func openTargets() {
        let list = session.windowList ?? []
        var ids = o.windows
        if ids.isEmpty {
            let app = o.app ?? (list.contains { $0.entry.appName == "WispProbe" } ? "WispProbe" : nil)
            ids = list.filter { app == nil || $0.entry.appName == app }.prefix(o.maxWindows).map(\.entry.id)
        }
        guard !ids.isEmpty else { finish("no test windows on the host (is WispProbe open and shared?)"); return }
        say("windows: " + ids.map { id in "\(id) (\(list.first { $0.entry.id == id }.map { "\($0.entry.appName): \($0.entry.title)" } ?? "?"))" }.joined(separator: ", "))
        ids.forEach { session.open(windowID: $0) }
        wait("the test windows to show frames", timeout: 20, until: { [weak self] in
            guard let self else { return false }
            let shown = session.windows.filter { c in c.stream.map { ids.contains($0.windowID) } ?? false }
            for c in shown { self.tap(c) }
            return ids.allSatisfy { id in self.fresh[id].map { $0.decoded > 0 } ?? false }
        }, then: { [weak self] in
            guard let self else { return }
            targets = ids.compactMap { id in self.session.windows.first { $0.stream?.windowID == id } }
            say("all \(targets.count) windows show frames with a readable counter; warming up 2 s (this app is \(NSApp.isActive ? "active: the key window gets pointer moves" : "not active: no window is key, as when scrolling in the background"))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.nextRound() }
        })
    }

    private func tap(_ c: ViewerController) {
        guard let id = c.stream?.windowID, fresh[id] == nil else { return }
        let f = Freshness()
        fresh[id] = f
        let view = c.view
        view.frameTap = { pb in
            let ppp = view.pixelsPerPoint > 0 ? view.pixelsPerPoint : 2
            f.frame(FrameCode.decode(pb, pointsWidth: CGFloat(CVPixelBufferGetWidth(pb)) / ppp))
        }
    }

    // MARK: Rounds

    private func nextRound() {
        roundNo += 1
        let round: Round
        if o.soakMinutes > 0 {
            if soakUntil == nil { soakUntil = Date().addingTimeInterval(o.soakMinutes * 60) }
            guard Date() < soakUntil! else { finish(nil); return }
            round = randomRound()
        } else {
            guard roundNo == 1 else { finish(nil); return }
            round = scriptedRound()
        }
        fetchHostLog { [weak self] before in
            guard let self else { return }
            guard let before else { finish("can't read the host's input log"); return }
            play(round) {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.o.settle + self.rtt * 2) {
                    self.fetchHostLog { after in
                        guard let after else { self.finish("can't read the host's input log"); return }
                        self.verify(round, Array(after.dropFirst(before.count)))
                        self.nextRound()
                    }
                }
            }
        }
    }

    private var rtt: Double { Double(session.client.latency.rttMin ?? 0) / 1_000_000 }

    private func play(_ r: Round, done: @escaping () -> Void) {
        say("round \(roundNo) (\(r.name)): \(r.steps.count) events over \(String(format: "%.1f", r.length)) s")
        let t0 = DispatchTime.now()
        r.startedAt = Date()
        var late = 0.0
        for s in r.steps {
            let due = t0 + s.t
            DispatchQueue.main.asyncAfter(deadline: due) {
                late = max(late, Double(DispatchTime.now().uptimeNanoseconds &- due.uptimeNanoseconds) / 1e9)
                s.run()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: t0 + r.length + 0.05) { [self] in
            // Events that go out late are still checked, but a busy Mac is worth knowing about when something fails.
            if late > 0.25 { warn(String(format: "round %d: events went out up to %.2f s late (this Mac's main thread was busy)", roundNo, late)) }
            done()
        }
    }

    /// Every scenario once in each window, one window after the other.
    private func scriptedRound() -> Round {
        let r = Round("scripted")
        var t = 0.0
        for (i, c) in targets.enumerated() {
            // First in the background (another window is key, as when scrolling a window beside the
            // one being worked in), later as the key window, whose pointer moves reach the host.
            let other = targets[(i + 1) % targets.count]
            r.steps.append((t, { [self] in
                if other !== c { other.window.makeKeyAndOrderFront(nil) }
                say("  window \(id(c)): scrolling \(c.window.isKeyWindow ? "as the key window" : "in the background")")
            }))
            t += 0.1
            if o.scenarios.contains("scroll") {
                let s0 = t
                t = trackpad(r, c, at: (0.5, 0.45), t: t, dy: -900, mayBegin: true)
                t = trackpad(r, c, at: (0.3, 0.6), t: t + 0.3, dy: 700, mayBegin: false, rate: 90, momentum: true, kind: "magic-mouse")
                t = smoothMouse(r, c, at: (0.6, 0.5), t: t + 0.3, dy: -400)
                t = wheel(r, c, at: (0.4, 0.7), t: t + 0.3, ticks: [1, 1, 1, -1, 1, 2, 3.5, 6, 0.5, 0.25])
                t = trackpad(r, c, at: (0.7, 0.4), t: t + 0.3, dy: -12000, mayBegin: false, rate: 120, momentum: true, kind: "flick")
                t = trackpad(r, c, at: (0.35, 0.35), t: t + 0.3, dy: 1_000_000, mayBegin: false, rate: 120, momentum: false, kind: "extreme-flick")
                t = trackpad(r, c, at: (0.55, 0.65), t: t + 0.3, dy: 300, dx: -200, mayBegin: true, rate: 120, momentum: true, kind: "diagonal")
                r.scrollSpans.append((id(c), s0, t + 0.2))
                t += 0.4
            }
            if o.scenarios.contains("click") {
                t = click(r, c, at: (0.3, 0.5), t: t)
                t = click(r, c, at: (0.6, 0.55), t: t + 0.25, count: 2)
                t = click(r, c, at: (0.45, 0.6), t: t + 0.25, count: 3)
                t = click(r, c, at: (0.5, 0.5), t: t + 0.4, button: 1)
                t = drag(r, c, from: (0.3, 0.4), to: (0.7, 0.75), t: t + 0.3)
                t += 0.4
            }
            if o.scenarios.contains("scroll") {
                r.steps.append((t, { [self] in
                    c.window.makeKeyAndOrderFront(nil)
                    say("  window \(id(c)): scrolling \(c.window.isKeyWindow ? "as the key window" : "in the background (this app isn't active)")")
                }))
                let s0 = t + 0.1
                t = trackpad(r, c, at: (0.45, 0.55), t: s0, dy: 500, mayBegin: true, kind: "trackpad-key")
                t = wheel(r, c, at: (0.65, 0.45), t: t + 0.3, ticks: [-1, -1, -2, -3.5])
                r.scrollSpans.append((id(c), s0, t + 0.2))
                t += 0.4
            }
            if o.scenarios.contains("key") {
                t = type(r, c, "hello wisp", t: t)
                t = shortcut(r, c, code: 0, chars: "a", mods: .command, t: t + 0.2)
                t = shortcut(r, c, code: 6, chars: "z", mods: [.command, .shift], t: t + 0.2)
                t = shortcut(r, c, code: 3, chars: "f", mods: [.command, .option], t: t + 0.2)
                t = shortcut(r, c, code: 0, chars: "a", mods: .control, t: t + 0.2)
                t = type(r, c, "Wisp", t: t + 0.2)
                t += 0.4
            }
        }
        if o.scenarios.contains("resize") {
            for (i, c) in targets.enumerated() {
                let cur = c.view.remoteSize
                t = resize(r, c, to: CGSize(width: max(420, cur.width - 60 - CGFloat(i) * 20), height: max(320, cur.height - 40)), t: t)
            }
            t += 1.0
        }
        r.length = t
        return r
    }

    /// About 20 s of random input across the windows; a resize now and then, at the end.
    private func randomRound() -> Round {
        let r = Round("random")
        var t = 0.0
        // Places on a grid, each used once per window and round: gestures are told apart by where they happen.
        var used: [UInt32: Set<Int>] = [:]
        while t < 18 {
            let c = targets.randomElement(using: &rng)!
            let p = { [self] () -> (Double, Double) in
                var cell = 0
                repeat { cell = Int.random(in: 0 ..< 15 * 11, using: &rng) } while used[id(c), default: []].contains(cell) && used[id(c)]!.count < 15 * 11
                used[id(c), default: []].insert(cell)
                return (0.15 + Double(cell % 15) * 0.05, 0.35 + Double(cell / 15) * 0.05)
            }
            let s0 = t
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0, 1:
                let dy = Double.random(in: -3000 ... 3000, using: &rng)
                t = trackpad(r, c, at: p(), t: t, dy: dy, dx: Double.random(in: -200 ... 200, using: &rng), mayBegin: Bool.random(using: &rng),
                             rate: 120, momentum: Bool.random(using: &rng))
                r.scrollSpans.append((id(c), s0, t + 0.2))
            case 2:
                t = trackpad(r, c, at: p(), t: t, dy: Double.random(in: -2000 ... 2000, using: &rng), mayBegin: false, rate: 90, momentum: true,
                             kind: "magic-mouse")
                r.scrollSpans.append((id(c), s0, t + 0.2))
            case 3:
                let ticks = (0 ..< Int.random(in: 2 ... 12, using: &rng)).map { _ in [1, 1, 1, 2, -1, 0.5, 3.5, 6][Int.random(in: 0 ..< 8, using: &rng)] }
                t = wheel(r, c, at: p(), t: t, ticks: ticks)
                r.scrollSpans.append((id(c), s0, t + 0.2))
            case 4:
                t = trackpad(r, c, at: p(), t: t, dy: Double.random(in: -30000 ... 30000, using: &rng), mayBegin: false, rate: 120, momentum: true,
                             kind: "flick")
                r.scrollSpans.append((id(c), s0, t + 0.2))
            case 5:
                t = smoothMouse(r, c, at: p(), t: t, dy: (Bool.random(using: &rng) ? 1 : -1) * Double.random(in: 40 ... 800, using: &rng))
                r.scrollSpans.append((id(c), s0, t + 0.2))
            case 6:
                t = click(r, c, at: p(), t: t, count: Int.random(in: 1 ... 3, using: &rng), button: Int.random(in: 0 ..< 6, using: &rng) == 0 ? 1 : 0)
            case 7:
                t = drag(r, c, from: p(), to: p(), t: t)
            case 8:
                let words = ["wisp", "scroll", "probe", "Hello", "abc def"]
                t = type(r, c, words.randomElement(using: &rng)!, t: t)
            default:
                let s: [(UInt16, String, NSEvent.ModifierFlags)] = [(0, "a", .command), (6, "z", [.command, .shift]), (3, "f", [.command, .option]),
                                                                   (8, "c", .control), (11, "b", .command)]
                let k = s.randomElement(using: &rng)!
                t = shortcut(r, c, code: k.0, chars: k.1, mods: k.2, t: t)
            }
            t += Double.random(in: 0.05 ... 0.5, using: &rng)
        }
        if o.scenarios.contains("resize"), Int.random(in: 0 ..< 3, using: &rng) == 0, let c = targets.randomElement(using: &rng) {
            let size = CGSize(width: Double.random(in: 450 ... 800, using: &rng).rounded(), height: Double.random(in: 330 ... 560, using: &rng).rounded())
            t = resize(r, c, to: size, t: t + 0.3) + 1.0
        }
        r.length = t
        return r
    }

    // MARK: Event generators (each returns the time after its last event)

    private func id(_ c: ViewerController) -> UInt32 { c.stream?.windowID ?? 0 }

    /// A point given as fractions of the window, in remote points (top-left origin), kept clear of
    /// the title bar and the frame code.
    private func remote(_ c: ViewerController, _ f: (Double, Double)) -> CGPoint {
        let s = c.view.remoteSize
        return CGPoint(x: (s.width * f.0).rounded(), y: max(80, (s.height * f.1).rounded()))
    }

    /// Remote point → this window's coordinates.
    private func local(_ c: ViewerController, _ p: CGPoint) -> NSPoint {
        let v = c.view, s = v.scale
        return v.convert(NSPoint(x: p.x * s, y: v.bounds.maxY - p.y * s), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ c: ViewerController, _ p: CGPoint, clicks: Int = 0, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        let e = NSEvent.mouseEvent(with: type, location: local(c, p), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                   pressure: [.leftMouseDown, .rightMouseDown, .leftMouseDragged].contains(type) ? 1 : 0)!
        // NSEvent.mouseEvent leaves buttonNumber 0; a real right click says 1.
        guard [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(type), let cg = e.cgEvent?.copy() else { return e }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 1)
        return NSEvent(cgEvent: cg) ?? e
    }

    /// A scroll event at `p` as AppKit delivers one: precise (points) or not (lines), with CG phases
    /// (began 1, changed 2, ended 4, cancelled 8, mayBegin 128) and momentum (begin 1, continue 2, end 3).
    private func scroll(_ c: ViewerController, _ p: CGPoint, dx: Double, dy: Double, precise: Bool, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent {
        // An event made for the window carries its window and location; scroll fields go on a copy of it.
        let cg = mouse(.mouseMoved, c, p).cgEvent!.copy()!
        cg.type = .scrollWheel
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        if precise {
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((dy / 10).rounded()))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((dx / 10).rounded()))
        } else {
            func whole(_ v: Double) -> Int64 { v == 0 ? 0 : Int64(v > 0 ? max(1, v.rounded()) : min(-1, v.rounded())) }
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: whole(dy))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: whole(dx))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((dy * 10).rounded()))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64((dx * 10).rounded()))
        }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }

    /// The pointer moves to `p` first, as a user's does before scrolling there. Moves reach a view
    /// through its tracking area, from the real pointer, never through sendEvent: hand them to the
    /// view as its tracking area would.
    private func moveTo(_ r: Round, _ c: ViewerController, _ p: CGPoint, t: Double) {
        r.steps.append((t, { [self] in c.view.mouseMoved(with: mouse(.mouseMoved, c, p)) }))
    }

    /// A scroll event, as AppKit delivers it: through the window (hit-tested); momentum events go to
    /// the view the gesture latched onto, which AppKit does itself for real ones but drops when they're
    /// made up, so they're handed to that view directly.
    private func deliver(_ e: NSEvent, _ c: ViewerController) {
        if e.momentumPhase != [] { c.view.scrollWheel(with: e) } else { E2EApp.inject(e) }
    }

    /// A trackpad (or Magic Mouse) gesture: [mayBegin,] began, changed…, ended, then momentum
    /// (begin, continue…, end) if `momentum`. Deltas ease in and out over the finger part; momentum decays.
    @discardableResult
    private func trackpad(_ r: Round, _ c: ViewerController, at f: (Double, Double), t start: Double, dy: Double, dx: Double = 0,
                          mayBegin: Bool, rate: Double = 120, momentum: Bool = true, kind: String = "trackpad") -> Double {
        let p = remote(c, f)
        let g = SentGesture(kind: kind, window: id(c), at: p)
        r.gestures[id(c), default: []].append(g)
        g.start = start
        var t = start
        moveTo(r, c, p, t: t); t += 0.03
        let step = 1 / rate
        func emit(_ ddx: Double, _ ddy: Double, _ ph: Int64, _ mo: Int64) {
            r.steps.append((t, { [self] in
                let e = scroll(c, p, dx: ddx, dy: ddy, precise: true, phase: ph, momentum: mo)
                g.add(e)
                deliver(e, c)
            }))
        }
        if mayBegin { emit(0, 0, 128, 0); t += 0.05 }
        let n = 24
        let fingerShare = momentum ? 0.6 : 1.0
        let weights = (0 ..< n).map { i in sin(Double(i + 1) / Double(n + 1) * .pi) }
        let wsum = weights.reduce(0, +)
        var sentY = 0.0, sentX = 0.0
        for (i, w) in weights.enumerated() {
            // Integer deltas whose running total tracks the curve (a trackpad's are fractional, but CGEvent's are whole points).
            let wantY = (dy * fingerShare * weights[0 ... i].reduce(0, +) / wsum).rounded(), wantX = (dx * fingerShare * weights[0 ... i].reduce(0, +) / wsum).rounded()
            _ = w
            emit(wantX - sentX, wantY - sentY, i == 0 ? 1 : 2, 0)
            sentY = wantY; sentX = wantX
            t += step
        }
        emit(0, 0, 4, 0)
        t += 0.03
        if momentum {
            let m = 40
            let restY = dy - sentY, restX = dx - sentX
            let decay = (0 ..< m).map { pow(0.9, Double($0)) }
            let dsum = decay.reduce(0, +)
            var mY = 0.0, mX = 0.0
            for i in 0 ..< m {
                let wantY = (restY * decay[0 ... i].reduce(0, +) / dsum).rounded(), wantX = (restX * decay[0 ... i].reduce(0, +) / dsum).rounded()
                emit(wantX - mX, wantY - mY, 0, i == 0 ? 1 : 2)
                mY = wantY; mX = wantX
                t += 1.0 / 60
            }
            emit(0, 0, 0, 3)
        }
        return t + 0.01
    }

    /// A mouse with smooth scrolling (precise deltas, no phases), as some third-party mice and
    /// scroll utilities send.
    private func smoothMouse(_ r: Round, _ c: ViewerController, at f: (Double, Double), t start: Double, dy: Double) -> Double {
        let p = remote(c, f)
        let g = SentGesture(kind: "smooth-mouse", window: id(c), at: p)
        r.gestures[id(c), default: []].append(g)
        g.start = start
        var t = start
        moveTo(r, c, p, t: t); t += 0.03
        let n = 20
        var sent = 0.0
        for i in 0 ..< n {
            let want = (dy * Double(i + 1) / Double(n)).rounded()
            let d = want - sent
            sent = want
            r.steps.append((t, { [self] in let e = scroll(c, p, dx: 0, dy: d, precise: true); g.add(e); deliver(e, c) }))
            t += 1.0 / 60
        }
        return t
    }

    /// A classic wheel mouse: non-precise ticks in lines (fractional once macOS accelerates them).
    private func wheel(_ r: Round, _ c: ViewerController, at f: (Double, Double), t start: Double, ticks: [Double]) -> Double {
        let p = remote(c, f)
        let g = SentGesture(kind: "wheel", window: id(c), at: p)
        r.gestures[id(c), default: []].append(g)
        g.start = start
        var t = start
        moveTo(r, c, p, t: t); t += 0.03
        for (i, d) in ticks.enumerated() {
            r.steps.append((t, { [self] in let e = scroll(c, p, dx: 0, dy: d, precise: false); g.add(e); deliver(e, c) }))
            t += i < 4 ? 0.08 : 0.012 // slow clicks, then a fast spin
        }
        return t
    }

    private func click(_ r: Round, _ c: ViewerController, at f: (Double, Double), t start: Double, count: Int = 1, button: Int = 0) -> Double {
        let p = remote(c, f)
        var t = start
        moveTo(r, c, p, t: t); t += 0.03
        for n in 1 ... count {
            r.inputs[id(c), default: []].append(.button(ev: "down", button: button, clicks: n, at: p))
            r.inputs[id(c), default: []].append(.button(ev: "up", button: button, clicks: n, at: p))
            let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == 1 ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
            r.steps.append((t, { [self] in E2EApp.inject(mouse(down, c, p, clicks: n)) })); t += 0.06
            r.steps.append((t, { [self] in E2EApp.inject(mouse(up, c, p, clicks: n)) })); t += 0.1
        }
        return t
    }

    private func drag(_ r: Round, _ c: ViewerController, from a: (Double, Double), to b: (Double, Double), t start: Double) -> Double {
        let p = remote(c, a), q = remote(c, b)
        var t = start
        moveTo(r, c, p, t: t); t += 0.03
        r.inputs[id(c), default: []].append(.button(ev: "down", button: 0, clicks: 1, at: p))
        r.steps.append((t, { [self] in E2EApp.inject(mouse(.leftMouseDown, c, p, clicks: 1)) })); t += 0.05
        let n = 30
        for i in 1 ... n {
            let k = Double(i) / Double(n)
            let m = CGPoint(x: (p.x + (q.x - p.x) * k).rounded(), y: (p.y + (q.y - p.y) * k).rounded())
            r.steps.append((t, { [self] in E2EApp.inject(mouse(.leftMouseDragged, c, m)) })); t += 1.0 / 120
        }
        r.inputs[id(c), default: []].append(.drag(to: q))
        r.inputs[id(c), default: []].append(.button(ev: "up", button: 0, clicks: 1, at: q))
        t += 0.05
        r.steps.append((t, { [self] in E2EApp.inject(mouse(.leftMouseUp, c, q, clicks: 1)) }))
        return t + 0.1
    }

    // US keyboard virtual key codes for what the tests type.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
    ]
    private static let modifierKeys: [(NSEvent.ModifierFlags, UInt16)] = [(.control, 59), (.option, 58), (.shift, 56), (.command, 55)]

    private func key(_ c: ViewerController, code: UInt16, chars: String, ignoring: String, down: Bool, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: c.window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                         isARepeat: false, keyCode: code)!
    }

    /// A modifier key going down or up: flagsChanged, as AppKit sends it (made from a mouse event for
    /// the window, like the scroll events).
    private func flags(_ c: ViewerController, code: UInt16, mods: NSEvent.ModifierFlags) -> NSEvent {
        let cg = mouse(.mouseMoved, c, CGPoint(x: 100, y: 100)).cgEvent!.copy()!
        cg.type = .flagsChanged
        cg.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        cg.flags = CGEventFlags(rawValue: UInt64(mods.rawValue))
        return NSEvent(cgEvent: cg)!
    }

    private func modsBits(_ m: NSEvent.ModifierFlags) -> Int { Int(m.intersection(InputRecord.modifierMask).rawValue) }

    /// Keys pressed and released with `mods` held (the modifiers go down first, in order, and up last).
    private func press(_ r: Round, _ c: ViewerController, code: UInt16, chars: String, mods: NSEvent.ModifierFlags, t start: Double) -> Double {
        var t = start
        var held: NSEvent.ModifierFlags = []
        let w = id(c)
        for (m, mcode) in Self.modifierKeys where mods.contains(m) {
            held.insert(m)
            let now = held
            r.inputs[w, default: []].append(.key(ev: "flags", code: Int(mcode), mods: modsBits(now), chars: nil))
            r.steps.append((t, { [self] in E2EApp.inject(flags(c, code: mcode, mods: now)) })); t += 0.03
        }
        let shown = mods.contains(.shift) ? chars.uppercased() : chars
        // Characters are the host's keyboard layout's: only compared for plain and shifted letters.
        let compare: String? = mods.isSubset(of: .shift) ? shown : nil
        let typed = mods.intersection([.control, .option, .command]).isEmpty ? shown : chars
        r.inputs[w, default: []].append(.key(ev: "keyDown", code: Int(code), mods: modsBits(mods), chars: compare))
        r.inputs[w, default: []].append(.key(ev: "keyUp", code: Int(code), mods: modsBits(mods), chars: compare))
        r.steps.append((t, { [self] in E2EApp.inject(key(c, code: code, chars: typed, ignoring: chars, down: true, mods: mods)) })); t += 0.05
        r.steps.append((t, { [self] in E2EApp.inject(key(c, code: code, chars: typed, ignoring: chars, down: false, mods: mods)) })); t += 0.03
        for (m, mcode) in Self.modifierKeys.reversed() where mods.contains(m) {
            held.remove(m)
            let now = held
            r.inputs[w, default: []].append(.key(ev: "flags", code: Int(mcode), mods: modsBits(now), chars: nil))
            r.steps.append((t, { [self] in E2EApp.inject(flags(c, code: mcode, mods: now)) })); t += 0.03
        }
        return t
    }

    private func type(_ r: Round, _ c: ViewerController, _ text: String, t start: Double) -> Double {
        var t = start
        for ch in text {
            let lower = Character(ch.lowercased())
            guard let code = Self.keyCodes[lower] else { continue }
            t = press(r, c, code: code, chars: String(lower), mods: ch.isUppercase ? .shift : [], t: t) + 0.02
        }
        return t
    }

    private func shortcut(_ r: Round, _ c: ViewerController, code: UInt16, chars: String, mods: NSEvent.ModifierFlags, t: Double) -> Double {
        press(r, c, code: code, chars: chars, mods: mods, t: t)
    }

    /// Resizes the window here (content, local points, keeping its top-left), as a user's drag of a
    /// corner ends; the host should follow.
    private func resize(_ r: Round, _ c: ViewerController, to size: CGSize, t: Double) -> Double {
        r.resized[id(c)] = size
        r.steps.append((t, {
            let w = c.window, old = w.frame
            let f = w.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: size.width * c.view.scale, height: size.height * c.view.scale)))
            w.setFrame(NSRect(x: old.minX, y: old.maxY - f.height, width: f.width, height: f.height), display: true)
        }))
        return t + 0.5
    }

    // MARK: Reading the host's log

    private func fetchHostLog(_ done: @escaping ([[String: Any]]?) -> Void) {
        let cmd = o.hostLogCmd ?? "cat \"\(o.hostLog ?? "")\""
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.standardError
            var data = Data()
            do {
                try p.run()
                data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let ok = p.terminationStatus == 0
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            let records = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            DispatchQueue.main.async { done(ok ? records : nil) }
        }
    }

    // MARK: Checking

    private func verify(_ r: Round, _ got: [[String: Any]]) {
        totals.rounds += 1
        let before = failures.count
        func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? -1 }
        func dbl(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? .nan }
        func pt(_ d: [String: Any]) -> CGPoint { CGPoint(x: dbl(d, "x"), y: dbl(d, "y")) }
        func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 3) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }
        let tag = "round \(roundNo)"

        for c in targets {
            let w = id(c)
            let mine = got.filter { int($0, "win") == Int(w) }
            // Scrolling: every record is matched to a sent gesture by where it happened, in order.
            let sent = r.gestures[w] ?? []
            let scrolls = mine.filter { $0["ev"] as? String == "scroll" }
            var buckets = Array(repeating: [[String: Any]](), count: sent.count)
            var gi = 0, stray = 0
            for s in scrolls {
                let p = pt(s)
                if gi < sent.count, near(p, sent[gi].at) { buckets[gi].append(s); continue }
                if let next = sent.indices.dropFirst(gi + 1).first(where: { near(p, sent[$0].at) }) { gi = next; buckets[gi].append(s); continue }
                stray += 1
                if stray <= 3 { fail("\(tag) window \(w): a scroll at \(Int(p.x)),\(Int(p.y)) matches no gesture sent there (sent at: \(sent.map { "\(Int($0.at.x)),\(Int($0.at.y))" }.joined(separator: " ")))") }
            }
            if stray > 3 { fail("\(tag) window \(w): \(stray - 3) more scrolls at the wrong place") }
            if stray > 0, !sent.isEmpty {
                // Still check what arrived, gesture by gesture: each record goes with the last gesture
                // sent before it arrived (the host's clock; the same Mac over loopback).
                say("  window \(w): \(stray) of \(scrolls.count) scrolls arrived at the wrong place; grouping them by time instead")
                buckets = Array(repeating: [], count: sent.count)
                let t0 = r.startedAt.timeIntervalSince1970
                for s in scrolls {
                    let at = dbl(s, "t") - t0
                    let g = sent.lastIndex { $0.start <= at + 0.01 } ?? 0
                    buckets[g].append(s)
                }
            }
            for (g, recs) in zip(sent, buckets) {
                totals.gestures += 1
                let name = "\(tag) window \(w) \(g.kind) at \(Int(g.at.x)),\(Int(g.at.y))"
                guard !recs.isEmpty else {
                    if abs(g.sum.x) < 1, abs(g.sum.y) < 1, g.boundaries.isEmpty { continue } // nothing to send
                    fail(String(format: "%@: nothing arrived (%d events sent, Σdy %.2f, Σdx %.2f)", name, g.events, g.sum.y, g.sum.x)); continue
                }
                let precise = recs.map { $0["precise"] as? Bool ?? false }
                if precise.contains(!g.precise) {
                    fail("\(name): sent \(g.precise ? "precise (points)" : "line (wheel)") deltas, \(precise.filter { $0 != g.precise }.count) of \(recs.count) arrived as \(g.precise ? "lines" : "precise points")")
                }
                let sx = recs.reduce(0.0) { $0 + dbl($1, "dx") }, sy = recs.reduce(0.0) { $0 + dbl($1, "dy") }
                let tol = (g.precise ? 1.0 : 1.0 / 16 + 0.01) + 0.002 * max(abs(g.sum.y), abs(g.sum.x))
                let dist = String(format: "Σdy sent %.2f, received %.2f; Σdx sent %.2f, received %.2f %@", g.sum.y, sy, g.sum.x, sx, g.precise ? "pt" : "lines")
                if abs(sy - g.sum.y) > tol || abs(sx - g.sum.x) > tol { fail("\(name): distance: \(dist)") }
                let bounds = recs.compactMap { d -> [Int]? in
                    let p = int(d, "phase"), m = int(d, "momentum")
                    return (p != 0 && p != 4) || (m != 0 && m != 4) ? [p, m] : nil
                }
                if bounds != g.boundaries { fail("\(name): phases: sent \(g.boundaries), received \(bounds)") }
                if let problem = Self.phaseProblem(recs.map { (int($0, "phase"), int($0, "momentum")) }) { fail("\(name): \(problem)") }
                if o.verbose { say("ok \(name): \(recs.count) records for \(g.events) events; \(dist)") }
            }
            // Clicks, drags and keys: exactly what was sent, in order.
            let want = r.inputs[w] ?? []
            let recv = mine.filter { ["down", "up", "drag", "keyDown", "keyUp", "flags"].contains($0["ev"] as? String ?? "") }
            var i = 0
            var problems: [String] = []
            for e in want {
                totals.inputs += 1
                switch e {
                case .button(let ev, let b, let n, let p):
                    while i < recv.count, recv[i]["ev"] as? String == "drag" { i += 1 } // drags beyond the sent ones (a move before the press)
                    guard i < recv.count else { problems.append("missing \(e)"); continue }
                    let d = recv[i]; i += 1
                    if d["ev"] as? String != ev || int(d, "button") != b || int(d, "clicks") != n || !near(pt(d), p, 2) {
                        problems.append("expected \(e), got \(d["ev"] ?? "?") button \(int(d, "button")) ×\(int(d, "clicks")) at \(Int(pt(d).x)),\(Int(pt(d).y))")
                    }
                case .drag(let q):
                    var drags: [[String: Any]] = []
                    while i < recv.count, recv[i]["ev"] as? String == "drag" { drags.append(recv[i]); i += 1 }
                    if drags.isEmpty { problems.append("no drag arrived (expected \(e))") }
                    else if !near(pt(drags.last!), q, 2) { problems.append("drag ended at \(Int(pt(drags.last!).x)),\(Int(pt(drags.last!).y)), expected \(Int(q.x)),\(Int(q.y))") }
                case .key(let ev, let code, let mods, let chars):
                    guard i < recv.count else { problems.append("missing \(e)"); continue }
                    let d = recv[i]; i += 1
                    if d["ev"] as? String != ev || int(d, "code") != code || int(d, "mods") != mods {
                        problems.append("expected \(e), got \(d["ev"] ?? "?") \(int(d, "code")) mods 0x\(String(int(d, "mods"), radix: 16))")
                    } else if let chars, let got = d["chars"] as? String, got != chars {
                        warn("\(tag) window \(w): \(e) arrived as \"\(got)\" (the host's keyboard layout?)")
                    }
                }
                if problems.count > 5 { break }
            }
            let extra = recv.dropFirst(i).filter { $0["ev"] as? String != "drag" }
            if !extra.isEmpty { problems.append("\(extra.count) unexpected: " + extra.prefix(3).map { "\($0["ev"] ?? "?") \($0["code"] ?? $0["button"] ?? "")" }.joined(separator: ", ")) }
            for p in problems.prefix(6) { fail("\(tag) window \(w) input: \(p)") }
            // Resize: the host's window ends at the size asked for.
            if let size = r.resized[w] {
                let rs = mine.filter { $0["ev"] as? String == "resize" }
                let last = rs.last.map { CGSize(width: dbl($0, "w"), height: dbl($0, "h")) }
                if let last, abs(last.width - size.width) <= 1, abs(last.height - size.height) <= 1 {
                    if o.verbose { say("ok \(tag) window \(w) resized to \(Int(size.width))x\(Int(size.height))") }
                } else {
                    fail("\(tag) window \(w): asked for \(Int(size.width))x\(Int(size.height)) pt, the host's window ended at \(last.map { "\(Int($0.width))x\(Int($0.height))" } ?? "no resize at all")")
                }
                let shown = c.view.remoteSize
                if abs(shown.width - size.width) > 1 || abs(shown.height - size.height) > 1 {
                    fail("\(tag) window \(w): the viewer shows \(Int(shown.width))x\(Int(shown.height)) pt after asking for \(Int(size.width))x\(Int(size.height))")
                }
            }
            // Raises while only scrolling: a scroll shouldn't take the focus.
            let raises = mine.filter { $0["ev"] as? String == "raise" }
            if !raises.isEmpty { say("  window \(w): \(raises.count) raises (\(Set(raises.compactMap { $0["why"] as? String }).joined(separator: "; ")))") }
        }
        // A raise (the synthetic host logs them with WISP_FAULT=focus-hold) while only scrolling was
        // being sent: scrolling took the focus. Host and viewer clocks are the same Mac's over loopback.
        let slack = 0.15 + rtt
        let scrollRaises = got.filter { d in
            guard d["ev"] as? String == "raise", let t = (d["t"] as? NSNumber)?.doubleValue else { return false }
            // The host says when a scroll made it raise; older hosts don't, and then only the scripted
            // pass (scrolling apart from clicks and keys) can tell by the time.
            if (d["why"] as? String)?.contains("scroll") == true { return true }
            guard r.name == "scripted" else { return false }
            let at = t - r.startedAt.timeIntervalSince1970
            let w = UInt32((d["win"] as? NSNumber)?.intValue ?? -1)
            return r.scrollSpans.contains { $0.window == w && at >= $0.from && at <= $0.to + slack }
        }
        if !scrollRaises.isEmpty {
            fail("\(tag): scrolling raised a window \(scrollRaises.count) times (\(Set(scrollRaises.compactMap { $0["why"] as? String }).joined(separator: "; ")))")
        }
        checkFreshness(tag)
        checkLog(tag)
        let n = failures.count - before
        say("\(tag): " + (n == 0 ? "PASS" : "\(n) failures") + " (\(r.gestures.values.map(\.count).reduce(0, +)) gestures, \(r.inputs.values.map(\.count).reduce(0, +)) clicks/keys, \(got.count) host records)")
    }

    /// What's wrong with a sequence of (phase, momentum), if anything: a gesture is
    /// [mayBegin] began changed… ended|cancelled (or mayBegin cancelled), momentum begin changed… end,
    /// and nothing is left mid-gesture.
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func phaseProblem(_ seq: [(Int, Int)]) -> String? {
        enum S { case idle, may, touch, momentum }
        var s = S.idle
        for (i, (p, m)) in seq.enumerated() {
            let at = "event \(i + 1) (phase \(p), momentum \(m))"
            if p != 0, m != 0 { return "\(at): phase and momentum both set" }
            switch (s, p, m) {
            case (_, 0, 0): if s != .idle { return "\(at): a phaseless scroll in the middle of a gesture" }
            case (.idle, 32, 0): s = .may
            case (.idle, 1, 0), (.may, 1, 0): s = .touch
            case (.may, 16, 0): s = .idle
            case (.touch, 4, 0), (.touch, 2, 0): break
            case (.touch, 8, 0), (.touch, 16, 0): s = .idle
            case (.idle, 0, 1): s = .momentum
            case (.momentum, 0, 4): break
            case (.momentum, 0, 8): s = .idle
            default: return "\(at) out of place"
            }
        }
        return s == .idle ? nil : "the gesture never ended (left \(s))"
    }

    private var softFreezes = 0

    private func checkFreshness(_ tag: String) {
        for c in targets {
            let w = id(c)
            guard let f = fresh[w] else { continue }
            f.tick()
            let line = "window \(w): \(f.shown) frames shown, counter read in \(f.decoded) (\(f.unreadable) unreadable), advanced \(f.advances) times, longest freeze \(String(format: "%.2f", f.maxFreeze)) s" + (f.maxFreeze > 0.5 ? " (from \(Self.clock.string(from: f.freezeAt ?? Date())))" : "")
            // One short hiccup (up to twice the limit) is a warning the first two times in a run, so a
            // single start-up blip in an 8-hour soak doesn't fail it; a third, or anything longer, fails.
            if f.maxFreeze > o.maxFreeze * 2 || (f.maxFreeze > o.maxFreeze && softFreezes >= 2) {
                fail("\(tag) \(line) (more than \(o.maxFreeze) s)")
            } else if f.maxFreeze > o.maxFreeze {
                softFreezes += 1
                warn("\(tag) \(line) (more than \(o.maxFreeze) s, short hiccup #\(softFreezes): a warning)")
            } else {
                say("  \(line)")
            }
            if f.decoded == 0 { fail("\(tag) window \(w): no frame counter could be read") }
            f.maxFreeze = 0
        }
    }

    private func checkLog(_ tag: String) {
        for l in logProblems { fail("\(tag) log: \(l)") }
        logProblems = []
    }

    private func finish(_ error: String?) {
        if let error { fail(error) }
        checkLog("end")
        let took = Date().timeIntervalSince(startedAt)
        if E2EApp.ignored > 0 { say("(ignored \(E2EApp.ignored) events from this Mac's own mouse and keyboard)") }
        say(String(format: "e2e %@ after %.0f s: %d rounds, %d gestures, %d clicks/keys checked; %d failures, %d warnings (seed %llu)",
                   failures.isEmpty ? "PASSED" : "FAILED", took, totals.rounds, totals.gestures, totals.inputs, failures.count, warnings.count, o.seed))
        Log.flush()
        exit(failures.isEmpty ? 0 : 1)
    }
}
