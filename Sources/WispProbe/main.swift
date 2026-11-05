// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// WispProbe: the host side of the end-to-end test (docs/testing.md "End-to-end input and
// freshness"). A plain AppKit app with up to three windows, each a scroll view of numbered rows
// under a frame counter that is redrawn every display frame: as digits and a timestamp for people,
// and as FrameCode squares at the top left for `wisp e2e`, which reads them from the frames it
// decodes. Every event its windows receive is appended as an InputRecord JSON line to
// ~/Library/Logs/WispProbe/events.jsonl (or --log <file>): scrolls as its scroll view gets them
// (deltas, precise, phases, where, and how far the view scrolled), clicks with their click counts,
// drags, keys with characters and modifiers, resizes, key-window changes. Needs no permission: it
// only receives what Wisp injects. Share one of its windows from Wisp; `wisp e2e` opens the others.
//
//   WispProbe.app/Contents/MacOS/WispProbe [--windows 1…3] [--log <file>] [--keep]   (--keep: append to the log)

let args = Array(CommandLine.arguments.dropFirst())
func arg(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let windowCount = min(3, max(1, Int(arg("--windows") ?? "3") ?? 3))
let logPath = arg("--log") ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/WispProbe/events.jsonl")
let inputLog = InputLog(path: logPath, truncate: !args.contains("--keep"))

/// The numbered rows (24 pt each), drawn as needed.
final class RowsView: NSView {
    static let rowHeight: CGFloat = 24
    let rows = 5000
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {} // recorded by the monitor; no beep
    override func keyUp(with e: NSEvent) {}
    override func draw(_ dirty: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirty.fill()
        let first = max(0, Int(dirty.minY / Self.rowHeight)), last = min(rows - 1, Int(dirty.maxY / Self.rowHeight))
        guard first <= last else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor]
        for i in first ... last {
            let y = CGFloat(i) * Self.rowHeight
            if i % 2 == 1 { NSColor.alternatingContentBackgroundColors.last?.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).fill() }
            ("Row \(i)" as NSString).draw(at: NSPoint(x: 16, y: y + 4), withAttributes: attrs)
        }
    }
}

/// The scroll view records what it is given, as the app would see it, then scrolls.
final class ProbeScrollView: NSScrollView {
    var record: ((NSEvent, CGFloat) -> Void)?
    override func scrollWheel(with e: NSEvent) {
        super.scrollWheel(with: e)
        record?(e, contentView.bounds.origin.y)
    }
}

/// The frame counter, over everything, letting all input through.
final class CounterView: NSView {
    var counter = 0
    var titleBar: CGFloat = 28
    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) {
        // FrameCode positions are window points from the window's top-left; this view starts below the title bar.
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: FrameCode.origin.x - 4, y: FrameCode.origin.y - titleBar - 4, width: FrameCode.size.width + 8, height: FrameCode.size.height + 8).fill()
        for (r, white) in FrameCode.cells(counter) {
            (white ? NSColor.white : NSColor.black).setFill()
            r.offsetBy(dx: 0, dy: -titleBar).fill()
        }
        let text = String(format: "frame %d   %@", counter, Self.clock.string(from: Date()))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
                                                    .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)]
        (text as NSString).draw(at: NSPoint(x: FrameCode.origin.x + FrameCode.size.width + 16, y: FrameCode.origin.y - titleBar - 6), withAttributes: attrs)
    }
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
}

final class ProbeWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let scroll = ProbeScrollView()
    let counter = CounterView()
    var win: UInt32 { UInt32(window.windowNumber) }

    init(index: Int) {
        let sizes = [NSSize(width: 800, height: 560), NSSize(width: 640, height: 480), NSSize(width: 520, height: 400)]
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80 + index * 60, y: 120 + index * 40), size: sizes[index]),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "WispProbe \(index + 1)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: sizes[index]))
        scroll.frame = content.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let rows = RowsView(frame: NSRect(x: 0, y: 0, width: 1600, height: CGFloat(5000) * RowsView.rowHeight))
        scroll.documentView = rows
        counter.frame = content.bounds
        counter.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
        content.addSubview(counter)
        window.contentView = content
        window.makeFirstResponder(rows)
        scroll.record = { [weak self] e, y in
            guard let self, var r = InputRecord.make(e, src: "probe", win: win, at: topLeft(e)) else { return }
            r["scrollY"] = Double(y)
            inputLog.write(r)
        }
    }

    /// An event's place in window points from the window's top-left (what the host's Injector aims at).
    func topLeft(_ e: NSEvent) -> CGPoint {
        CGPoint(x: e.locationInWindow.x, y: window.frame.height - e.locationInWindow.y)
    }

    func tick() {
        counter.titleBar = window.frame.height - window.contentLayoutRect.height
        counter.counter += 1
        counter.needsDisplay = true
    }

    func windowDidResize(_ n: Notification) {
        inputLog.write(["src": "probe", "win": Int(win), "ev": "resize", "w": Int(window.frame.width.rounded()), "h": Int(window.frame.height.rounded())])
    }
    func windowDidBecomeKey(_ n: Notification) { inputLog.write(["src": "probe", "win": Int(win), "ev": "key"]) }
    func windowDidResignKey(_ n: Notification) { inputLog.write(["src": "probe", "win": Int(win), "ev": "resign"]) }
}

final class ProbeApp: NSObject, NSApplicationDelegate {
    var windows: [ProbeWindow] = []
    var link: CVDisplayLink?
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit WispProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        windows = (0 ..< windowCount).map { ProbeWindow(index: $0) }
        for w in windows.reversed() { w.window.makeKeyAndOrderFront(nil) }
        NSApp.activate()
        inputLog.write(["src": "probe", "ev": "start", "pid": Int(getpid()),
                        "windows": windows.map { ["win": Int($0.win), "title": $0.window.title, "w": Int($0.window.frame.width), "h": Int($0.window.frame.height)] }])
        // Clicks, drags and keys as the app gets them (before any view or menu does). Scrolls are
        // recorded by the scroll views, where the app's scrolling happens.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            if let w = self?.windows.first(where: { $0.window === e.window }),
               let r = InputRecord.make(e, src: "probe", win: w.win, at: e.type == .keyDown || e.type == .keyUp || e.type == .flagsChanged ? nil : w.topLeft(e)) {
                inputLog.write(r)
            }
            return e
        }
        // A new frame every display refresh, so a frozen picture can be told from a quiet one.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.windows.forEach { $0.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        print("WispProbe: \(windows.count) windows (\(windows.map { "\($0.window.title) = window \($0.win)" }.joined(separator: ", ")); recording to \(logPath)")
        fflush(stdout)
        if args.contains("--selftest") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.selfTest() } }
    }

    /// --selftest: the counter can be read back from each window as drawn (rendered here, not
    /// captured: no permission needed), and events sent to the windows are recorded. Exits 0 or 1.
    func selfTest() {
        var ok = true
        func read(_ w: ProbeWindow) -> Int? {
            guard let view = w.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let size = w.window.frame.size
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width * scale), Int(size.height * scale), kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb, let image = rep.cgImage else { return nil }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))) // content under the title bar
            CVPixelBufferUnlockBaseAddress(pb, [])
            return FrameCode.decode(pb, pointsWidth: size.width)
        }
        let first = windows.map(read)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            for (w, a) in zip(windows, first) {
                let b = read(w)
                let fine = a != nil && b != nil && FrameCode.advance(from: a!, to: b!) > 5
                ok = ok && fine
                print("\(w.window.title): counter read \(a.map(String.init) ?? "nil") then \(b.map(String.init) ?? "nil") (drawn \(w.counter.counter)): \(fine ? "ok" : "FAIL")")
            }
            let w = windows[0], p = NSPoint(x: 200, y: 200)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
            NSApp.sendEvent(down)
            let cg = down.cgEvent!.copy()!
            cg.type = .scrollWheel
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -30)
            NSApp.sendEvent(NSEvent(cgEvent: cg)!)
            NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.window.windowNumber,
                                             context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let lines = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n") ?? []
                let kinds = Set(lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.compactMap { $0["ev"] as? String })
                for k in ["start", "down", "scroll", "keyDown"] {
                    print("recorded \(k): \(kinds.contains(k) ? "ok" : "FAIL")")
                    ok = ok && kinds.contains(k)
                }
                print(ok ? "selftest PASSED" : "selftest FAILED")
                exit(ok ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ProbeApp()
app.delegate = delegate
app.run()
