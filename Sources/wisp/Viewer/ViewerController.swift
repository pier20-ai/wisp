// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// One connection to a host, the menu bar list of its windows, and the windows showing its streams.
/// All of them share one TCP and one UDP connection. Main queue only.
///
/// Two ways to show the windows:
/// - in-process (`wisp view`, or `defaults write <Brand.defaultsDomain> phantoms -bool false`): each stream
///   in a window of this process. The first window shows "connecting…" and closing the last one ends
///   the session.
/// - phantom apps (the app's default, stage 3 of docs/multi-window.md): each remote app gets a
///   generated app of its own (Dock icon, ⌘Tab entry, menu bar), which owns that app's windows. This
///   process keeps the connection and relays frames and input (PhantomHub); it stays connected with
///   no windows open, until Disconnect in the menu bar list.
///
/// The menu bar list: `wisp view` gets its own (RemoteWindowsMenu); the app passes `ownMenu: false`
/// and shows the session's state (status, notice, windowList, isOpen) in its own menu bar item,
/// redrawn on `onChange`.
final class ViewerSession: WindowOwner {
    let client: Client
    let hostName: String
    var link: StreamLink { client }
    /// The session is over: after the last in-process window closed, Disconnect, or (with the reason)
    /// a connection that never came up in phantom mode.
    var onClose: ((String?) -> Void)?
    private var controllers: [ViewerController] = []
    private var menu: RemoteWindowsMenu?
    private let ownMenu: Bool
    /// Something the menu shows changed (status, notice, the window list, which windows are open).
    var onChange: (() -> Void)?
    /// Connection state ("Connecting to…", "Disconnected from…: why"); nil while connected.
    private(set) var status: String?
    /// The host's last refusal (e.g. its stream limit), until the next window opens.
    private(set) var notice: String?
    /// The host answered our hello.
    var isConnected: Bool { ready && status == nil }
    private var statsTimer: Timer?
    /// Host windows asked for and not answered yet, so choosing one twice doesn't open two windows.
    private var opening: Set<UInt32> = []
    private var stopped = false
    private var ready = false
    private(set) var hub: PhantomHub?
    private(set) var windowList: [RemoteWindow]?
    /// Streams whose app isn't known yet (an older host): waiting for the window list.
    private var unplaced: [RemoteStream] = []

    init(host: String, phantoms: Bool = false, ownMenu: Bool = true) {
        hostName = host
        self.ownMenu = ownMenu
        client = Client(host: host)
        client.relaysFrames = phantoms
        client.syncClipboard()
        if phantoms { hub = PhantomHub(session: self) }
    }

    var windows: [ViewerController] { controllers }

    func show() {
        if hub == nil {
            let first = ViewerController(session: self, stream: nil)
            controllers.append(first)
            first.show()
        }

        client.latency.measuresDisplay = true
        client.screen = { [weak self] in self?.screen ?? NSScreen.main }
        client.onReady = { [weak self] name in
            Log.info(.viewer, "connected to \(self?.hostName ?? "?") (\"\(name)\"): opening its shared window")
            self?.ready = true
            self?.setStatus(nil)
            self?.client.openStream(windowID: 0) // the window the host shares
        }
        client.onDisconnect = { [weak self] msg in self?.disconnected(msg) }
        client.onHostStatus = { [weak self] s in
            self?.controllers.forEach { $0.setHostStatus(s) }
            self?.hub?.hostStatus(s)
        }
        client.onStreamOpened = { [weak self] s in self?.streamOpened(s) }
        client.onStreamClosed = { [weak self] id, wid, reason in self?.streamClosed(id, windowID: wid, reason: reason) }
        client.onWindowList = { [weak self] list in self?.received(list) }
        client.onLargeIcon = { [weak self] key, px, png in self?.hub?.largeIcon(key, px: px, png: png) }
        client.onMenuTree = { [weak self] key, msg in self?.hub?.menuTree(key, msg) }
        client.onNewWindowHeld = { [weak self] _, key, name, _, max in self?.newWindowHeld(appKey: key, appName: name, max: max) }
        if let hub {
            do { try hub.start() } catch {
                Log.error(.phantom, "phantom apps unavailable (\(Log.describe(error))): showing windows in \(Brand.name) itself")
                self.hub = nil
                client.relaysFrames = false
                show()
                return
            }
        }
        client.start()

        if ownMenu {
            let menu = RemoteWindowsMenu(client: client, hostName: hostName, phantoms: hub != nil)
            menu.isOpen = { [weak self] id in self?.isOpen(id) ?? false }
            menu.onChoose = { [weak self] id in self?.open(windowID: id) }
            menu.onDisconnect = { [weak self] in self?.disconnect() }
            self.menu = menu
        } else {
            client.requestWindowList() // so the menu has a list the first time it opens
        }
        if hub != nil, !ready { setStatus("Connecting to \(hostName)…") }
        hub?.onChange = { [weak self] in self?.changed() }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = client.bytesDown.take(), up = client.bytesUp.take()
            let lat = client.latency.summary
            for c in controllers {
                guard let s = c.stream as? RemoteStream else { continue }
                c.setStats(statsLine(latency: lat, down: down, up: up, frames: s.frames.take(), repaired: s.resent.take() + s.fecRecovered.take()))
            }
            hub?.updateStats(latency: lat, down: down, up: up)
        }
        testOpen()
    }

    private func setStatus(_ s: String?) { status = s; menu?.status = s; onChange?() }
    private func setNotice(_ s: String?) { notice = s; menu?.notice = s; onChange?() }
    private func changed() { menu?.rebuild(); onChange?() }

    /// Windows open here (streams shown, or on their way).
    var openCount: Int { hub?.streamCount ?? controllers.filter { $0.stream != nil }.count }

    func isOpen(_ id: UInt32) -> Bool {
        if let hub { return hub.isOpen(windowID: id) }
        return controllers.contains { $0.stream?.windowID == id }
    }

    /// The menu's path: host window `id` in a window of its own, or its window to the front if it has one.
    func open(windowID id: UInt32) {
        if let hub, hub.focus(windowID: id) { return }
        if let c = controllers.first(where: { $0.stream?.windowID == id }) { c.bringToFront(); return }
        guard !opening.contains(id) else { return }
        opening.insert(id)
        Log.info(.viewer, "opening window \(id) of \(hostName)")
        client.openStream(windowID: id)
    }

    private func streamOpened(_ s: RemoteStream) {
        opening.remove(s.windowID)
        if notice != nil { setNotice(nil) }
        if hub != nil {
            route(s)
            changed()
            return
        }
        if let c = controllers.first(where: { $0.stream?.id == s.id }) { c.bringToFront(); return }
        if let pending = controllers.first(where: { $0.stream == nil }) {
            pending.bind(s)
        } else {
            let c = ViewerController(session: self, stream: s)
            controllers.append(c)
            c.show()
        }
        changed()
    }

    /// Phantom mode: hands stream `s` to its app's phantom, once the app is known.
    private func route(_ s: RemoteStream) {
        if let app = s.app ?? windowList?.first(where: { $0.entry.id == s.windowID }).map({ ($0.entry.appKey, $0.entry.appName) }) {
            hub?.streamOpened(s, appKey: app.0, appName: app.1)
            return
        }
        // An older host doesn't name the app in streamOpened: look the window up in a fresh list.
        unplaced.append(s)
        client.requestWindowList()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, unplaced.contains(where: { $0 === s }) else { return }
            unplaced.removeAll { $0 === s }
            hub?.streamOpened(s, appKey: "wisp.unknown-app", appName: "Remote Window")
        }
    }

    private func received(_ list: [RemoteWindow]) {
        windowList = list
        menu?.update(list)
        onChange?()
        hub?.windowList(list)
        let waiting = unplaced
        unplaced = []
        waiting.forEach(route)
    }

    private func streamClosed(_ id: UInt16, windowID: UInt32, reason: StreamCloseReason) {
        guard id == 0 else {
            controllers.first { $0.stream?.id == id }?.streamEnded(reason.text)
            return
        }
        // An openStream that failed.
        opening.remove(windowID)
        Log.info(.viewer, "\(hostName) couldn't open window \(windowID == 0 ? "(its shared window)" : "\(windowID)"): \(reason.text)")
        if hub != nil, windowID == 0 {
            // The window the host shares by default: none chosen yet. The menu lists the others.
            Log.info(.viewer, "\(hostName) has no shared window chosen: open one from the menu")
            return
        }
        if let hub {
            let open = hub.streamCount
            let text = reason == .limit
                ? "\(hostName) streams at most \(open) window\(open == 1 ? "" : "s") at once: close one to open another"
                : "\(hostName) couldn't open that window: \(reason.text)"
            setNotice(text)
            hub.refused(windowID: windowID, text: text)
            NSSound.beep()
        } else if windowID == 0, let pending = controllers.first(where: { $0.stream == nil }) {
            pending.setConnection("can't show its window: \(reason.text)")
        } else {
            NSSound.beep()
        }
    }

    /// An app we show opened a new window on the host, which the host can't stream (its limit). It
    /// opens by itself once a window closes.
    private func newWindowHeld(appKey: String, appName: String, max: Int) {
        let text = "\(appName) opened a new window on \(hostName); \(max) window\(max == 1 ? " is" : "s are") already open — close one to see it"
        Log.info(.viewer, text)
        setNotice(text)
        if let hub {
            hub.newWindowHeld(appKey: appKey, text: text)
        } else {
            (controllers.first { $0.window.isKeyWindow } ?? controllers.first)?.showNotice(text)
        }
        NSSound.beep()
    }

    private var waitingGiveUp: DispatchWorkItem?

    private func disconnected(_ msg: String) {
        controllers.forEach { $0.setConnection(msg) }
        guard let hub else { return }
        if !ready, msg.hasPrefix("waiting") {
            setStatus("Connecting to \(hostName): \(msg)")
            Log.info(.viewer, "still connecting to \(hostName): \(msg)" + (waitingGiveUp == nil ? "; giving up in 15 s unless it connects" : ""))
            // Network.framework waits forever (e.g. a name that never resolves); give up after 15 s.
            if waitingGiveUp == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, !ready, !stopped else { return }
                    Log.warning(.viewer, "giving up on \(hostName) after 15 s of waiting: \(msg)")
                    stop()
                    onClose?("Couldn't reach \(hostName) within 15 seconds (\(msg.replacingOccurrences(of: "waiting: ", with: ""))). "
                             + "Check that Tailscale is connected on both Macs, or connect to its 100.x address.")
                }
                waitingGiveUp = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
            }
            return
        }
        if !ready {
            // Never connected: back to the chooser, with the reason.
            Log.warning(.viewer, "couldn't connect to \(hostName): \(msg)")
            stop()
            onClose?(msg)
            return
        }
        Log.warning(.viewer, "disconnected from \(hostName): \(msg)")
        setStatus("Disconnected from \(hostName): \(msg)")
        hub.connection(msg)
    }

    /// A local window closed (it already told the host, if it had to).
    func controllerClosed(_ c: ViewerController) {
        controllers.removeAll { $0 === c }
        changed()
        if controllers.isEmpty, hub == nil, !stopped {
            stop()
            onClose?(nil)
        }
    }

    /// The menu's Disconnect: phantom apps quit, the connection closes.
    func disconnect() {
        guard !stopped else { return }
        Log.info(.viewer, "disconnecting from \(hostName)")
        stop()
        onClose?(nil)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        statsTimer?.invalidate()
        menu?.remove()
        hub?.stop()
        let open = controllers
        controllers = []
        open.forEach { $0.closeLocally() }
        client.stop()
    }

    func placeNew(_ c: ViewerController) { place(c, among: controllers) }

    /// The screen the host's virtual displays should match: the key window's, else the first one's;
    /// in phantom mode, the screen the phantoms last reported.
    private var screen: NSScreen? {
        if let hub { return hub.screen }
        return (controllers.first { $0.window.isKeyWindow } ?? controllers.first)?.window.screen
    }

    /// Debug: WISP_TEST_OPEN=<id>[,<id>…][@seconds] opens those host windows after a while (2 s), as
    /// choosing them from the menu bar list does. WISP_TEST_CLOSE=<id>[@seconds] later closes that
    /// window's local window as Window > Stop Viewing does (the stream ends, the remote window stays).
    private func testOpen() {
        func parse(_ key: String, _ delay: Double) -> ([UInt32], Double)? {
            guard let spec = ProcessInfo.processInfo.environment[key] else { return nil }
            let parts = spec.split(separator: "@")
            return (parts[0].split(separator: ",").compactMap { UInt32($0) }, parts.count > 1 ? Double(parts[1]) ?? delay : delay)
        }
        if let (ids, delay) = parse("WISP_TEST_OPEN", 2) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for id in ids {
                    log("test: opening host window \(id), as the menu does")
                    self?.open(windowID: id)
                }
            }
        }
        if let (ids, delay) = parse("WISP_TEST_CLOSE", 5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for id in ids {
                    log("test: closing the local window of host window \(id), as Window > Stop Viewing does")
                    self?.controllers.first { $0.stream?.windowID == id }?.closeLocally()
                    self?.hub?.stopViewing(windowID: id)
                }
            }
        }
    }
}

/// One local window showing one stream (one remote window): its own video, chrome, traffic lights,
/// resizing, and close. Closing it stops that stream only; its red button closes the remote window.
final class ViewerController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private unowned let session: WindowOwner
    private var client: StreamLink { session.link }
    /// Internal (not private) for `wisp e2e`, which drives it as a user would.
    let view: RemoteView
    private(set) var stream: ViewerStream?
    /// In a phantom app, ⌘Q, ⌘H and ⌥⌘H act on the phantom instead of going to the remote (see isLocalShortcut).
    static var localShortcuts = false
    /// A short message over the video (e.g. the host's stream limit), for a few seconds.
    private var notice: String?
    private var noticeTimer: Timer?
    /// Connection trouble ("connecting…", "disconnected"); nil once frames are showing.
    private var connection: String? = "connecting…"
    private var stats = ""
    private var hostStatus = ""
    private var optionHeld = false
    private var title: String
    private var shownSize: CGSize?
    private var keyMonitor: Any?
    private var hostName: String { session.hostName }
    /// The stream is over (the host closed it, or the remote window is gone): don't ask to close it.
    private var ended = false
    private var closing = false
    private static var didTestResize = false

    // Resizing both ways. A local resize by the user sends resizeWindow (at most every 50 ms while
    // dragging, and once at the end); windowInfo says which request the host has applied, so echoes
    // of our own requests are told apart from resizes made on the host, which the local window then
    // follows (keeping its top-left corner where it is).
    private var resizable = false
    private var requestSeq: UInt32 = 0
    /// Our newest request the host hasn't settled yet.
    private var pendingResize: (id: UInt32, size: CGSize)?
    /// The size (remote points) the user's resize asks for, not sent yet.
    private var wantedSize: CGSize?
    private var lastResizeSent = Date.distantPast
    private var resizeTimer: Timer?
    /// We are resizing the window ourselves (to follow the remote): not a request to pass on.
    private var adjusting = false
    /// The remote ended up at a size other than this window's during a live resize: snap to it at the end.
    private var snapAfterLiveResize = false

    init(session: WindowOwner, stream: ViewerStream?) {
        self.session = session
        view = RemoteView(link: session.link)
        title = session.hostName
        // A titled window (so it minimizes, zooms, goes full screen and gets the system shadow and
        // corners), with a transparent title bar: the remote title bar acts as it, under our own buttons.
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.delegate = self
        window.tabbingMode = .disallowed
        view.cornerRadius = Self.cornerRadius(of: window)
        takeCloseButton()
        view.updateStandardButtons()
        view.onStopViewing = { [weak self] in self?.closeLocally() }
        window.center()
        if let stream { bind(stream) }
    }

    /// The system's window corner radius (16 pt on macOS 26+, 10 before), so the video's corners match other windows.
    private static func cornerRadius(of w: NSWindow) -> CGFloat {
        let key = "_cornerRadius"
        if w.responds(to: Selector((key))), let r = w.value(forKey: key) as? NSNumber, r.doubleValue > 0 {
            return CGFloat(r.doubleValue)
        }
        if #available(macOS 26, *) { return 16 }
        return 10
    }

    func show() {
        // A window for a stream that is already running waits for its size before it appears.
        if stream == nil { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(view)
        NSApp.activate()
        updateStatus()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if Self.localShortcuts, Self.isLocalShortcut(e) { return e } // the phantom's own menu handles it
            if e.type == .flagsChanged, e.modifierFlags.contains(.option) != optionHeld {
                optionHeld.toggle()
                updateStatus()
            }
            self.view.forwardKey(e)
            return nil
        }
        view.onFrameShown = { [weak self] in
            guard let self, connection != nil else { return }
            connection = nil
            updateStatus()
            window.invalidateShadow()
        }
        if !Self.didTestResize { Self.didTestResize = true; testResize() }
    }

    /// ⌘Q (quit the phantom: stop viewing its windows), ⌘H (hide it) and ⌥⌘H (hide the others): exactly
    /// these modifiers, by the character typed (as menu key equivalents match). Every other key,
    /// ⌘W and ⌘` included, goes to the remote. ⌘Tab never reaches an app: the system switches apps
    /// and the remote gets the ⌘ press and, when the window loses focus, its release.
    static func isLocalShortcut(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown || e.type == .keyUp else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = e.charactersIgnoringModifiers?.lowercased()
        return (mods == .command && (key == "q" || key == "h")) || (mods == [.command, .option] && key == "h")
    }

    /// Shows stream `s` in this window.
    func bind(_ s: ViewerStream) {
        stream = s
        view.stream = s
        s.attach(info: { [weak self] in self?.apply($0) },
                 chrome: { [weak self] c in self?.applyChrome(c.isKnown ? c : nil) },
                 gone: { [weak self] in
                     guard let self else { return }
                     log("\(title) was closed on \(hostName)")
                     streamEnded(nil)
                 },
                 closed: { [weak self] in self?.streamEnded(nil) },
                 image: { [weak self] pb, timing in self?.view.enqueue(pb, timing) })
    }

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setConnection(_ msg: String?) { connection = msg; updateStatus() }
    func setHostStatus(_ s: String) { hostStatus = s; updateStatus() }

    /// Once a second, from the session (see statsLine): latency, traffic, this stream's frames.
    func setStats(_ line: String) {
        stats = line
        updateStatus()
    }

    /// Shows `text` over the video for a few seconds (e.g. the host refused another window).
    func showNotice(_ text: String) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.notice = nil; self?.updateStatus() }
        updateStatus()
    }

    /// The host ended this stream: close the window (`why` nil = the remote window closed).
    func streamEnded(_ why: String?) {
        ended = true
        if let why { log("\(title): \(why)") }
        closeLocally()
    }

    /// Closes this window here only (the remote window stays open unless the stream already ended).
    func closeLocally() {
        guard !closing else { return }
        window.close()
        // A window that was never shown may not say it closed.
        if !closing { windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window)) }
    }

    private func apply(_ info: RemoteInfo) {
        title = info.title
        view.remoteSize = info.points
        if info.points.width > 0 { view.pixelsPerPoint = info.pixels.width / info.points.width }
        let first = shownSize == nil
        if !resizable {
            resizable = true
            view.stretch = false
            window.contentResizeIncrements = NSSize(width: 1, height: 1) // free resize, the remote follows
        }
        let rid = info.requestID ?? 0
        if let p = pendingResize {
            guard !isNewer(p.id, than: rid) else { updateStatus(); return } // the host hasn't got to our latest yet
            pendingResize = nil
            if wantedSize != nil || resizeTimer != nil { updateStatus(); return } // more of the user's resize is on its way
        } else if isNewer(rid, than: requestSeq) {
            requestSeq = rid // e.g. a reopened stream: carry on from the host's numbering
        }
        // Settled. If the remote isn't the size this window shows, it was resized there, or it clamped
        // our request: follow it, but never in the middle of the user's drag.
        if first || !sameSize(info.points, localRemoteSize()) {
            if view.isFullScreen {
                // Full screen can't change size: the video is letterboxed in it.
            } else if window.inLiveResize {
                snapAfterLiveResize = true
            } else {
                matchRemote(info.points, place: first)
            }
        }
        shownSize = info.points
        if first, !window.isVisible { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view) }
        updateStatus()
    }

    /// The window's content size in remote points.
    private func localRemoteSize() -> CGSize {
        let b = view.bounds.size
        return CGSize(width: (b.width / view.scale).rounded(), height: (b.height / view.scale).rounded())
    }

    /// Sizes this window to the remote's `points`: 1 remote point = 1 local point if it fits on this
    /// screen, else scaled down to fit. Keeps the top-left corner (moving up only to stay on screen);
    /// the first time, the session places it (centred, or cascaded from the other windows).
    private func matchRemote(_ points: CGSize, place: Bool = false) {
        let vis = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 850)
        let s = min(1, vis.width / points.width, vis.height / points.height)
        let size = CGSize(width: (points.width * s).rounded(), height: (points.height * s).rounded())
        view.scale = s
        if !place { log("following \(hostName): window now \(Int(points.width))x\(Int(points.height)) pt" + (s < 1 ? String(format: " at %.2fx", s) : "")) }
        let old = window.frame
        var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        f.origin = NSPoint(x: old.minX, y: old.maxY - f.height)
        if f.minY < vis.minY { f.origin.y = min(vis.minY, vis.maxY - f.height) }
        if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
        snapAfterLiveResize = false
        adjusting = true
        window.setFrame(f, display: true)
        if place { session.placeNew(self) }
        adjusting = false
    }

    // MARK: Local resize -> remote

    /// Debug: WISP_TEST_RESIZE=<w>x<h>[@seconds] resizes the first window (content, local points) once,
    /// keeping its top-left, as a user's resize would; the host should follow and confirm it.
    private func testResize() {
        guard let spec = ProcessInfo.processInfo.environment["WISP_TEST_RESIZE"] else { return }
        let parts = spec.split(separator: "@")
        let wh = parts[0].split(separator: "x").compactMap { Double($0) }
        guard wh.count == 2 else { return }
        let delay = parts.count > 1 ? Double(parts[1]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let old = window.frame
            let f = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: wh[0], height: wh[1]))
            log("test: resizing the window to \(Int(wh[0]))x\(Int(wh[1])) pt")
            window.setFrame(NSRect(x: old.minX, y: old.maxY - f.height, width: f.width, height: f.height), display: true)
        }
    }

    func windowDidResize(_ n: Notification) {
        guard resizable, !adjusting, shownSize != nil else { return }
        wantedSize = localRemoteSize()
        let wait = 0.05 - Date().timeIntervalSince(lastResizeSent)
        if wait <= 0 {
            sendWantedSize()
        } else if resizeTimer == nil {
            let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.sendWantedSize() }
            RunLoop.main.add(t, forMode: .common) // fires during the live-resize tracking loop too
            resizeTimer = t
        }
    }

    private func sendWantedSize() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        guard let want = wantedSize, let stream else { return }
        wantedSize = nil
        guard !sameSize(want, pendingResize?.size ?? view.remoteSize) else { return }
        requestSeq &+= 1
        pendingResize = (requestSeq, want)
        lastResizeSent = Date()
        client.resizeWindow(stream.id, want, id: requestSeq)
        if !window.inLiveResize { log("asked \(hostName) to resize stream #\(stream.id) to \(Int(want.width))x\(Int(want.height)) pt (#\(requestSeq))") }
    }

    func windowDidEndLiveResize(_ n: Notification) {
        sendWantedSize() // the final size goes out now
        if snapAfterLiveResize, pendingResize == nil {
            snapAfterLiveResize = false
            if !sameSize(view.remoteSize, localRemoteSize()) { matchRemote(view.remoteSize) }
        }
    }

    /// This window's own red button: ⌥-click stops viewing (closes this window only), a plain click
    /// closes the remote window (performClose, below). Taken over from AppKit, whose ⌥-click on a close
    /// button closes every window of the app. Yellow and green stay AppKit's: minimize here, full
    /// screen here (⌥: zoom).
    private func takeCloseButton() {
        guard let red = window.standardWindowButton(.closeButton) else { return }
        red.target = self
        red.action = #selector(closeButtonClicked(_:))
    }

    @objc private func closeButtonClicked(_ sender: Any?) {
        if NSEvent.modifierFlags.contains(.option) { closeLocally(); return }
        // Not window.performClose: a window with a close button performs it by clicking that button,
        // which is this action again (infinite recursion, a crash). Ask the delegate ourselves.
        if windowShouldClose(window) { window.close() }
    }

    /// Red: close the remote window (through Accessibility on the host, which then says it's gone and
    /// this window closes). ⌥-red, Window > Stop Viewing, or no connection: just close it here.
    func windowShouldClose(_ w: NSWindow) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return true }
        guard connection == nil, !view.isFullScreen else { return true }
        return !view.clickRemoteClose()
    }

    /// The title (Window menu, Mission Control) always carries the status; the pill over the video
    /// shows it only while connecting, on a host warning, or while ⌥ is held.
    private func updateStatus() {
        let line = "\(title)   ·   \(connection ?? stats)"
        window.title = hostStatus.isEmpty ? line : "⚠︎ \(hostStatus)   ·   \(title)"
        let pill = notice.map { "⚠︎ \($0)" } ?? (!hostStatus.isEmpty ? "⚠︎ \(hostStatus)" : connection.map { "\(hostName): \($0)" } ?? line)
        view.setStatus(pill, visible: notice != nil || connection != nil || !hostStatus.isEmpty || optionHeld)
    }

    /// Zoom fills the screen: the remote follows our size.
    func windowWillUseStandardFrame(_ w: NSWindow, defaultFrame f: NSRect) -> NSRect { f }

    func windowWillEnterFullScreen(_ n: Notification) { view.isFullScreen = true }
    func windowDidFailToEnterFullScreen(_ w: NSWindow) { view.isFullScreen = false }
    func windowWillExitFullScreen(_ n: Notification) { view.isFullScreen = false }
    func windowDidExitFullScreen(_ n: Notification) { view.updateStandardButtons(); window.invalidateShadow() }
    func windowDidBecomeKey(_ n: Notification) { client.sendScreen() }

    func windowDidResignKey(_ n: Notification) {
        view.releaseHeldKeys()
        if optionHeld { optionHeld = false; updateStatus() }
    }
    func windowDidChangeScreen(_ n: Notification) { client.sendScreen() } // the host resizes its virtual display

    /// Remote windows with a toolbar-style title bar (Claude, Safari, Finder: ~40 pt and up) have
    /// macOS's larger traffic lights, placed lower and further in. An empty unified toolbar gives this
    /// window the same: AppKit then sizes and places its own buttons as for any toolbar window, which
    /// is about where the remote's are. Not for plain title bars (Terminal, TextEdit: 28 pt): there a
    /// toolbar would put our buttons below the remote title bar, over its content.
    private func applyChrome(_ c: WindowChrome?) {
        let wantToolbar = (c?.titleBarHeight ?? 0) >= 40
        if wantToolbar, window.toolbar == nil {
            let tb = NSToolbar(identifier: "remote-chrome")
            tb.showsBaselineSeparator = false
            window.toolbar = tb
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        } else if !wantToolbar, window.toolbar != nil {
            window.toolbar = nil
            window.toolbarStyle = .automatic
        }
        takeCloseButton() // AppKit may have made new buttons for the new title bar style
        view.chrome = c
    }

    func windowWillClose(_ n: Notification) {
        guard !closing else { return }
        closing = true
        view.releaseHeldKeys()
        view.stop()
        resizeTimer?.invalidate()
        noticeTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let stream {
            stream.detach()
            if !ended { client.closeStream(stream.id) }
        }
        session.controllerClosed(self)
    }
}
