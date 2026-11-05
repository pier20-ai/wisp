// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// MARK: - poke

/// Debug: connect on the side (any viewer stays connected), send one click, key press, resize or
/// close to a stream (default: the host's primary stream), quit.
func runPoke(_ arguments: [String]) -> Never {
    var args = arguments
    var stream: UInt16 = 0
    if let i = args.firstIndex(of: "--stream") {
        guard i + 1 < args.count, let s = UInt16(args[i + 1]) else { fail(usage) }
        stream = s
        args.removeSubrange(i ... i + 1)
    }
    guard args.count == 3 else { fail(usage) }
    let client = Client(host: args[0])
    client.sideChannel = true
    var messages: [Data] = []
    switch args[1] {
    case "click":
        let p = args[2].split(separator: ",").compactMap { Double($0) }
        guard p.count == 2 else { fail(usage) }
        let x = UInt16(min(max(p[0], 0), 1) * 65535), y = UInt16(min(max(p[1], 0), 1) * 65535)
        messages = [message(.mouseMove, stream: stream) { $0.u16(x); $0.u16(y) },
                    message(.mouseDown, stream: stream) { $0.u8(0); $0.u8(1); $0.u16(x); $0.u16(y) },
                    message(.mouseUp, stream: stream) { $0.u8(0); $0.u8(1); $0.u16(x); $0.u16(y) }]
    case "key":
        guard let code = UInt16(args[2]) else { fail(usage) }
        messages = [message(.key, stream: stream) { $0.u16(code); $0.u8(1); $0.u32(0) },
                    message(.key, stream: stream) { $0.u16(code); $0.u8(0); $0.u32(0) }]
    case "resize":
        let p = args[2].split(separator: "x").compactMap { UInt16($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { fail(usage) }
        // Request 0 never looks newer than a viewer's own requests, so viewers treat it like a resize
        // made on the host and follow it.
        messages = [message(.resizeWindow, stream: stream) { $0.u16(p[0]); $0.u16(p[1]); $0.u32(0) }]
    case "action":
        guard let action = ["close": UInt8(1), "new-window": 2, "open-panel": 3][args[2]] else { fail(usage) }
        messages = [message(.windowAction, stream: stream) { $0.u8(action) }]
    default: fail(usage)
    }
    client.onDisconnect = { fail("error: \($0)", code: 1) }
    // Only once the host has acknowledged the side channel: an older host would misread these messages.
    client.onReady = { _ in
        messages.forEach { client.sendControl($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("sent \(args[1]) \(args[2]) to \(stream == 0 ? "the primary stream" : "stream #\(stream)")")
            exit(0)
        }
    }
    client.start()
    RunLoop.main.run()
    exit(0)
}

// MARK: - view

/// Prints what the viewer's menu bar list would show, then exits.
func runWindowList(address: String) -> Never {
    let client = Client(host: address)
    client.onDisconnect = { fail("error: \($0)", code: 1) }
    client.onWindowList = { list in
        func col(_ s: String, _ n: Int) -> String { String(s.prefix(n)).padding(toLength: n + 1, withPad: " ", startingAt: 0) }
        print(col("ID", 10) + col("APP", 40) + col("ICON", 5) + col("SIZE", 10) + "TITLE")
        for w in list {
            let e = w.entry
            let icon = w.icon.flatMap(NSImage.init(data:)).map { "\(Int($0.size.width))px" } ?? "none"
            print(col("\(e.id)", 10) + col("\(e.appName) (\(e.appKey))", 40) + col(icon, 5) + col("\(e.points.w)x\(e.points.h)", 10)
                + e.title + (e.shared ? "   (streamed)" : ""))
        }
        exit(0)
    }
    client.start()
    client.requestWindowList()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 5)
    t.setEventHandler { fail("no window list after 5 s: the host's \(Brand.name) may be too old", code: 1) }
    t.resume()
    withExtendedLifetime(t) { RunLoop.main.run() }
    exit(0)
}

/// Prints app `appKey`'s menu bar as the host reads it (what a phantom app mirrors), then exits. With
/// `press` ("File>New Window": titles from the top-level menu down), chooses that item afterwards.
func runMenuDump(address: String, appKey: String, press: String?) -> Never {
    let client = Client(host: address)
    client.onDisconnect = { fail("error: \($0)", code: 1) }
    var bar: [MenuTree.MenuTitle]?
    var menus: [UInt16: MenuNode] = [:]
    func finish() {
        guard let bar else { return }
        for t in bar { print(menus[t.index]?.dump() ?? t.title + "  (not received)") }
        guard let press else { exit(0) }
        let titles = press.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        var node: MenuNode? = MenuNode(index: 0, title: "", children: bar.compactMap { menus[$0.index] })
        var path: [MenuTree.MenuTitle] = []
        for t in titles {
            node = node?.children?.first { $0.title == t }
            guard let n = node else { fail("no menu item \(press)", code: 1) }
            path.append(MenuTree.MenuTitle(index: n.index, title: n.title))
        }
        client.sendControl(MenuPress(appKey: appKey, stream: 0, path: path).encode())
        print("chose \(press) (see the host's log)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
    client.onMenuTree = { _, msg in
        guard let (_, payload) = MessageParser().feed(msg).first, let (key, tree) = MenuTree.decode(payload), key == appKey else { return }
        switch tree {
        case .bar(let b): bar = b
        case .menu(let n): menus[n.index] = n
        case .none(let why): fail("no menus: \(why)", code: 1)
        }
        if let bar, bar.allSatisfy({ menus[$0.index] != nil }) { finish() }
    }
    client.onReady = { _ in client.sendControl(MenuTree.request(appKey: appKey, menu: MenuTree.wholeBar)) }
    client.start()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 5)
    t.setEventHandler {
        if bar == nil { fail("no menus after 5 s: the host's \(Brand.name) may be too old", code: 1) }
        finish()
    }
    t.resume()
    withExtendedLifetime(t) { RunLoop.main.run() }
    exit(0)
}

final class CLIViewerDelegate: NSObject, NSApplicationDelegate {
    let address: String
    let phantoms: Bool
    var viewer: ViewerSession?
    init(address: String, phantoms: Bool) { self.address = address; self.phantoms = phantoms }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let v = ViewerSession(host: address, phantoms: phantoms)
        v.onClose = { error in
            if let error { log("error: \(error)") }
            NSApp.terminate(nil)
        }
        viewer = v
        v.show()
    }
}

func runView(_ arguments: [String]) -> Never {
    guard let address = arguments.first, !address.hasPrefix("-") else { fail(usage) }
    func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag) else { return nil }
        guard i + 1 < arguments.count else { fail(usage) }
        return arguments[i + 1]
    }
    if arguments.contains("--windows") { runWindowList(address: address) }
    if let key = value("--menus") { runMenuDump(address: address, appKey: key, press: value("--press")) }
    if let path = value("--snapshot") {
        let open = value("--open").map { v -> [UInt32] in
            let ids = v.split(separator: ",").compactMap { UInt32($0) }
            guard !ids.isEmpty else { fail("--open takes window ids from --windows, e.g. --open 2,3") }
            return ids
        } ?? []
        let close = value("--close").map { v -> (UInt32, Int) in
            let p = v.split(separator: "@")
            guard p.count == 2, let id = UInt32(p[0]), let t = Int(p[1]) else { fail("--close takes <window id>@<seconds>, e.g. --close 2@3") }
            return (id, t)
        }
        runSnapshot(address: address, path: path, open: open, close: close)
    }
    let phantoms = arguments.contains("--phantoms")
    let app = NSApplication.shared
    app.setActivationPolicy(phantoms ? .accessory : .regular)
    let delegate = CLIViewerDelegate(address: address, phantoms: phantoms)
    app.delegate = delegate
    app.run()
    exit(0)
}

/// Headless test: open the host's shared window plus the windows in `open`, decode a few seconds
/// (WISP_SECONDS, default 3) of each, print per-stream stats every second, and save each stream's
/// last frame as PNG: the shared window's to `path`, window N's to <path without .png>-N.png.
/// `close` = (window ID, second): close that stream then, to check the others keep going.
func runSnapshot(address: String, path: String, open: [UInt32], close: (UInt32, Int)?) -> Never {
    final class Tap {
        let stream: RemoteStream
        var title = "?"
        var size = CGSize.zero
        var latest: CVPixelBuffer?
        var closedAt: Int?
        var gone = false
        var frames = 0, key = 0, rebuilt = 0, resent = 0, keyRequests = 0
        let lock = NSLock()
        init(_ s: RemoteStream) { stream = s }
    }
    let client = Client(host: address)
    // A test syncs the clipboard only with a private pasteboard (WISP_PASTEBOARD), never the real one.
    if ClipboardSync.isTestPasteboard { client.syncClipboard() }
    var taps: [Tap] = [] // main queue, in the order opened
    var elapsed = 0
    client.onReady = { name in
        print("host: \(name), protocol \(Wire.protocolVersion)")
        client.openStream(windowID: 0)
        open.forEach { client.openStream(windowID: $0) }
    }
    client.onStreamOpened = { s in
        guard !taps.contains(where: { $0.stream === s }) else { return }
        let tap = Tap(s)
        taps.append(tap)
        print("stream #\(s.id) opened: window \(s.windowID)")
        s.attach(info: { i in
            tap.title = i.title
            tap.size = i.points
            print("stream #\(s.id) window: \(i.title) \(Int(i.points.width))x\(Int(i.points.height)) pt, \(Int(i.pixels.width))x\(Int(i.pixels.height)) px"
                + (i.requestID.map { ", resize ack #\($0)" } ?? ""))
        }, chrome: { c in
            func r(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
            print(c.isKnown ? "stream #\(s.id) chrome: title bar \(c.titleBarHeight) pt, close \(r(c.close)), minimize \(r(c.minimize)), zoom \(r(c.zoom))"
                            : "stream #\(s.id) chrome: unknown")
        }, gone: {
            tap.gone = true
            print("stream #\(s.id): the window is gone on the host")
        }, closed: {
            print("stream #\(s.id): closed by the host")
        }, image: { pb, _ in tap.lock.lock(); tap.latest = pb; tap.lock.unlock() })
    }
    client.onStreamClosed = { id, wid, reason in
        if id == 0 { print("host couldn't open window \(wid): \(reason.text)") }
    }
    client.onDisconnect = { fail("error: \($0)", code: 1) }
    client.start()
    let seconds = Int(ProcessInfo.processInfo.environment["WISP_SECONDS"] ?? "3") ?? 3
    let t = every(1) {
        elapsed += 1
        if elapsed % 5 == 0 { print(client.latency.summary); print(client.lastBreakdown) }
        print("t=\(elapsed)s down \(kbps(client.bytesDown.take(), over: 1)), up \(kbps(client.bytesUp.take(), over: 1))")
        for tap in taps {
            let s = tap.stream
            let f = s.frames.take(), k = s.keyframes.take(), fec = s.fecRecovered.take(), re = s.resent.take(), kr = s.keyRequests.take()
            tap.frames += f; tap.key += k; tap.rebuilt += fec; tap.resent += re; tap.keyRequests += kr
            let state = tap.gone ? " (gone)" : tap.closedAt.map { " (closed at t=\($0)s)" } ?? ""
            print("  #\(s.id) \(tap.title) \(Int(tap.size.width))x\(Int(tap.size.height)) pt: \(f) frames (\(k) key), \(fec) pkts rebuilt by FEC, \(re) re-requested, \(kr) keyframe requests\(state)")
        }
        if let (wid, at) = close, elapsed == at, let tap = taps.first(where: { $0.stream.windowID == wid && $0.closedAt == nil }) {
            print("closing stream #\(tap.stream.id) (window \(wid))")
            tap.closedAt = elapsed
            tap.stream.detach()
            client.closeStream(tap.stream.id)
        }
        guard elapsed >= seconds else { return }
        guard !taps.isEmpty else { fail("no stream opened", code: 1) }
        var missing = false
        print("totals over \(elapsed) s:")
        for (i, tap) in taps.enumerated() {
            let s = tap.stream
            print("  #\(s.id) window \(s.windowID): \(tap.frames) frames (\(tap.key) key), \(tap.rebuilt) pkts rebuilt by FEC, \(tap.resent) re-requested, \(tap.keyRequests) keyframe requests")
            if tap.closedAt != nil || tap.gone { continue }
            tap.lock.lock(); let pb = tap.latest; tap.lock.unlock()
            guard let pb else { print("  #\(s.id): no frame decoded"); missing = true; continue }
            let out = i == 0 ? path : (path.hasSuffix(".png") ? String(path.dropLast(4)) : path) + "-\(s.windowID).png"
            writePNG(pb, to: out)
            print("saved stream #\(s.id) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) frame to \(out)")
        }
        exit(missing ? 1 : 0)
    }
    withExtendedLifetime(t) { RunLoop.main.run() }
    exit(0)
}
