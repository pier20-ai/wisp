// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// A phantom app: this binary, copied into a generated bundle whose Info.plist has WispPhantom
// (PhantomBundle.swift). It is the remote app as far as this Mac is concerned: its own Dock icon,
// ⌘Tab entry and menu bar, and it owns that app's windows. The main Wisp process holds the
// connection; this process decodes and shows its streams and sends their input back (PhantomHub).

/// "phantom-Safari.log": one file per phantom app (by its app name). Each phantom is a process of its
/// own: a file each keeps their lines from interleaving, lets each rotate on its own, and puts a
/// misbehaving app's log where its name says. (Two hosts' phantoms of one app share a file; every
/// line has its pid, and each phantom's first line says which host it shows.)
func phantomLogFileName(_ appName: String) -> String {
    let safe = appName.map { c -> Character in c.isLetter || c.isNumber || c == " " || c == "-" || c == "_" || c == "." ? c : "_" }
    return "phantom-\(String(safe).trimmingCharacters(in: .whitespaces).prefix(60)).log"
}

func runPhantom(_ info: [String: Any]) -> Never {
    Log.info(.phantom, "\(Diagnostics.versionLine) phantom at \(Bundle.main.bundlePath), pid \(getpid()), \(Diagnostics.macOSLine)")
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PhantomAppDelegate(info: info)
    app.delegate = delegate
    app.run()
    exit(0)
}

final class PhantomAppDelegate: NSObject, NSApplicationDelegate, WindowOwner, NSMenuDelegate {
    let hostName: String
    let appKey: String
    let appName: String
    private let wispPath: String?
    private let relay: PhantomRelay
    var link: StreamLink { relay }
    private var controllers: [ViewerController] = []
    private var streams: [UInt16: PhantomStream] = [:]
    /// This app's windows on the host (Wisp sends them); `shared` = open here.
    private var remoteWindows: [WindowEntry] = []
    private var notice: String?
    /// Wisp said a window is on its way: a Dock reopen until then is Wisp bringing us forward.
    private var expectingUntil = Date.distantPast
    private var connected = false
    private var quitting = false
    private var connectAttempts = 0
    private var launchedWisp = false
    private var dockWindowsMenu = NSMenu()
    // The menu bar: local app and Window menus, with the remote app's menus mirrored around and into them.
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    private(set) lazy var menus = PhantomMenus(owner: self)
    /// The stream whose window was key last (menu items are chosen for it).
    private var lastKeyStream: UInt16 = 0
    /// No App Nap or timer coalescing while windows are streaming, even when this app is in the background.
    private var activity: NSObjectProtocol?

    init(info: [String: Any]) {
        hostName = info["host"] as? String ?? "?"
        appKey = info["appKey"] as? String ?? "?"
        appName = info["appName"] as? String ?? ProcessInfo.processInfo.processName
        wispPath = info["wisp"] as? String
        relay = PhantomRelay()
        super.init()
        relay.owner = self
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        ViewerController.localShortcuts = true
        // macOS adds these to an app's Edit menu; here they would act on a view that takes no text.
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true, "NSDisabledCharacterPaletteMenuItem": true])
        NSApp.mainMenu = makePhantomMenu()
        _ = menus
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, let s = controllers.first(where: { $0.window === w })?.stream else { return }
            lastKeyStream = s.id
        }
        Log.info(.phantom, "phantom \(appName) (\(appKey) on \(hostName)) started, pid \(getpid()), socket \(PhantomPaths.socket)")
        connect()
        testInput()
        testMenus()
    }

    func applicationDidBecomeActive(_ n: Notification) { if connected { menus.requestBar() } }

    /// The stream a menu item is chosen for: the key window's, else the last key one's if still open, else none.
    func menuStream() -> UInt16 {
        if let s = controllers.first(where: { $0.window.isKeyWindow })?.stream { return s.id }
        if streams[lastKeyStream] != nil { return lastKeyStream }
        return controllers.first?.stream?.id ?? 0
    }

    /// A host control message (menuRequest, menuPress), through Wisp.
    func sendToHost(_ msg: Data) { relay.send(.toHost) { $0.bytes(msg) } }

    /// Debug: WISP_PHANTOM_TEST_MENU=<seconds>. After that long: logs the mirrored menu bar, chooses
    /// View > Show Sidebar as a click would, refreshes View as opening it would and logs it again (the
    /// synthetic host toggles that checkmark), then types ⌘B (Show Sidebar's shortcut) into the key
    /// remote window: it must reach the host as keys, not as a menu press. Then logs View again, and
    /// chooses the remote Quit (without the confirmation).
    private func testMenus() {
        guard let delay = ProcessInfo.processInfo.environment["WISP_PHANTOM_TEST_MENU"].flatMap(Double.init) else { return }
        func at(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay + t, execute: f) }
        func dumpView(_ why: String) {
            guard let view = menus.menu(titled: "View") else { log("phantom \(appName): test: no View menu"); return }
            let lines = view.items.map { i in "\(i.state == .on ? "[✓] " : i.state == .mixed ? "[-] " : "")\(i.title)" }
            log("phantom \(appName): test: View menu \(why): \(lines.joined(separator: " | "))")
        }
        at(0) { [self] in
            log("phantom \(appName): test: menu bar:\n" + menus.dump())
            guard let view = menus.menu(titled: "View"), let i = view.items.firstIndex(where: { $0.title == "Show Sidebar" }) else {
                log("phantom \(appName): test: no View > Show Sidebar"); return
            }
            dumpView("before")
            view.performActionForItem(at: i)
        }
        at(1) { [self] in if let view = menus.menu(titled: "View") { menus.menuWillOpen(view) } }
        at(2) { dumpView("after choosing Show Sidebar") }
        at(2.5) { [self] in
            guard let c = controllers.first(where: { $0.window.isKeyWindow }) ?? controllers.first else { log("phantom \(appName): test: no window for ⌘B"); return }
            let w = c.window
            w.makeKeyAndOrderFront(nil)
            log("phantom \(appName): test: typing ⌘B into stream #\(c.stream?.id ?? 0)'s window")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
                                            isARepeat: false, keyCode: 11) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        at(3.5) { [self] in if let view = menus.menu(titled: "View") { menus.menuWillOpen(view) } }
        at(4.5) { [self] in
            dumpView("after typing ⌘B (unchanged if the key went to the host as a key)")
            menus.pressRemoteQuit()
        }
    }

    /// Debug: WISP_PHANTOM_TEST_INPUT=<seconds> clicks the middle of each of this phantom's windows
    /// and types "a" into it after that long, through the event queue (as the user would), so the
    /// input path from a phantom to the host can be checked.
    private func testInput() {
        guard let delay = ProcessInfo.processInfo.environment["WISP_PHANTOM_TEST_INPUT"].flatMap(Double.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            for c in controllers {
                let w = c.window
                w.makeKeyAndOrderFront(nil)
                let p = NSPoint(x: w.contentLayoutRect.midX, y: w.contentLayoutRect.midY)
                log("phantom \(appName): test: click at the middle of stream #\(c.stream?.id ?? 0)'s window and type a")
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                isARepeat: false, keyCode: 0) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
            }
        }
    }

    // MARK: Connection to Wisp

    private func connect() {
        let c = IPCConnection(path: PhantomPaths.socket, label: "wisp.phantom")
        c.onReady = { [weak self] in
            guard let self else { return }
            c.send(.hello) { $0.str(self.hostName); $0.str(self.appKey); $0.u32(UInt32(getpid())) }
        }
        c.onMessage = { [weak self] t, d in self?.received(t, d) }
        c.onClose = { [weak self] in DispatchQueue.main.async { self?.lost() } }
        relay.conn = c
        c.start()
    }

    /// The socket closed, or isn't there: Wisp isn't running (start it, connected to our host), or quit.
    private func lost() {
        relay.conn = nil
        guard !quitting else { return }
        if connected {
            // Wisp quit or crashed: the windows can't show anything any more. Like an app whose
            // document server went away: close them and quit.
            log("phantom \(appName): \(Brand.name) went away; quitting")
            quit()
            return
        }
        connectAttempts += 1
        if connectAttempts == 1 { Log.info(.phantom, "\(Brand.name)'s socket \(PhantomPaths.socket) doesn't answer: \(wispPath == nil ? "waiting for it" : "starting \(Brand.name)")") }
        if connectAttempts % 20 == 0 { Log.info(.phantom, "still no \(Brand.name) at \(PhantomPaths.socket) after \(connectAttempts) attempts") }
        if connectAttempts == 1, let path = wispPath { startWisp(path) }
        guard connectAttempts < 80 else { // ~20 s
            alert("\(Brand.name) isn't connected to \(hostName)", "Open \(Brand.name) and connect to \(hostName), then open \(appName) again.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.connect() }
    }

    /// Opened from the Dock or Spotlight with Wisp not running: start it, connecting to our host.
    private func startWisp(_ path: String) {
        guard !launchedWisp else { return }
        launchedWisp = true
        log("phantom \(appName): starting \(Brand.name) to connect to \(hostName)")
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--connect", hostName]
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
                if let err { Log.error(.phantom, "couldn't open \(path): \(Log.describe(err))") } else { Log.info(.phantom, "opened \(path) (pid \(app?.processIdentifier ?? 0))") }
            }
        } else {
            let p = Process()
            p.executableURL = url
            p.arguments = ["--connect", hostName]
            do { try p.run(); Log.info(.phantom, "started \(path) (pid \(p.processIdentifier))") } catch { Log.failed(.phantom, "starting \(path)", error) }
        }
    }

    /// On the connection's queue: frames are decoded right here; everything else on main. A new
    /// stream is registered here too, before its window exists, so its first keyframe (which may
    /// arrive while the main thread is still making the window) isn't dropped.
    private func received(_ t: PhantomMsg, _ d: Data) {
        switch t {
        case .frame:
            var r = Reader(d)
            guard let sid = r.u16(), let at = r.u64() else { return }
            let s = streamsLock.withLock { liveStreams[sid] }
            s?.frame(r.rest(), reassembled: at)
        case .streamOpen:
            var r = Reader(d)
            guard let sid = r.u16(), let wid = r.u32() else { return }
            let s = streamsLock.withLock { () -> PhantomStream? in
                guard liveStreams[sid] == nil else { return nil }
                let s = PhantomStream(id: sid, windowID: wid, relay: relay)
                liveStreams[sid] = s
                return s
            }
            if let s { DispatchQueue.main.async { self.opened(s) } }
        default:
            DispatchQueue.main.async { self.handle(t, d) }
        }
    }

    // Streams by ID for the connection's queue (frames): registered there, forgotten on main.
    private let streamsLock = NSLock()
    private var liveStreams: [UInt16: PhantomStream] = [:]

    /// A stream for this app: a window of its own.
    private func opened(_ s: PhantomStream) {
        streams[s.id] = s
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "showing remote windows")
        }
        let c = ViewerController(session: self, stream: s)
        controllers.append(c)
        c.show()
        log("phantom \(appName): showing stream #\(s.id) (window \(s.windowID))")
    }

    private func handle(_ t: PhantomMsg, _ d: Data) {
        var r = Reader(d)
        switch t {
        case .helloAck:
            guard r.u8() == 1 else {
                _ = r.str()
                Log.warning(.phantom, "\(Brand.name) turned this phantom away")
                alert("\(appName) can't open", r.str() ?? "")
                return
            }
            Log.info(.phantom, "connected to \(Brand.name) (socket \(PhantomPaths.socket)) after \(connectAttempts + 1) attempt(s)")
            connected = true
            menus.requestBar(force: true)
        case .expect:
            expectingUntil = Date().addingTimeInterval(2)
        case .host:
            guard let (type, payload) = MessageParser().feed(r.rest()).first else { return }
            var p = Reader(payload)
            guard let sid = p.u16(), let s = streams[sid] else { return }
            switch type {
            case .windowInfo: if let i = WindowInfo.decode(p.rest()) { s.received(i) }
            case .windowChrome: if let c = WindowChrome.decode(p.rest()) { s.received(c) }
            case .windowGone: s.receivedGone(); forget(sid)
            case .streamClosed: s.closed(); forget(sid)
            default: break
            }
        case .stats:
            guard let sid = r.u16(), let line = r.str() else { return }
            controllers.first { $0.stream?.id == sid }?.setStats(line)
        case .connection:
            let msg = r.str() ?? ""
            controllers.forEach { $0.setConnection(msg.isEmpty ? nil : msg) }
        case .hostStatus:
            let s = r.str() ?? ""
            controllers.forEach { $0.setHostStatus(s) }
        case .windows:
            guard let (_, payload) = MessageParser().feed(r.rest()).first, let list = WindowEntry.decode(payload) else { return }
            remoteWindows = list
        case .notice:
            let text = r.str() ?? ""
            notice = text
            log("phantom \(appName): \(text)")
            if let c = controllers.first(where: { $0.window.isKeyWindow }) ?? controllers.first(where: { $0.window.isVisible }) {
                c.showNotice(text)
            } else {
                alert(appName, text)
            }
        case .focus:
            guard let sid = r.u16() else { return }
            controllers.first { $0.stream?.id == sid }?.bringToFront()
        case .stopViewing:
            guard let sid = r.u16() else { return }
            log("phantom \(appName): test: stop viewing stream #\(sid)")
            controllers.first { $0.stream?.id == sid }?.closeLocally()
        case .icon:
            if let img = NSImage(data: r.rest()) { NSApp.applicationIconImage = img }
        case .menu:
            menus.received(r.rest())
        case .quit:
            log("phantom \(appName): \(Brand.name) is disconnecting; quitting")
            quit()
        default:
            break
        }
    }

    private func forget(_ sid: UInt16) {
        streams[sid] = nil
        streamsLock.withLock { liveStreams[sid] = nil }
    }

    // MARK: WindowOwner

    func placeNew(_ c: ViewerController) { place(c, among: controllers) }

    func controllerClosed(_ c: ViewerController) {
        controllers.removeAll { $0 === c }
        if let sid = c.stream?.id { forget(sid) }
        if controllers.isEmpty, let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        // No windows left: the phantom stays, like any app with no windows open.
    }

    // MARK: App behaviour

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Dock icon clicked: its windows come forward (AppKit does that); with none open, the app's
    /// frontmost remote window opens, or, if the host has none either, the remote app is reopened as
    /// a Dock click there would (Finder opens a new window, which then opens here). Not while Wisp is
    /// bringing us forward for a window on its way.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if controllers.isEmpty, Date() > expectingUntil {
            relay.send(.openWindow) { $0.u32(0) }
        } else if !hasVisibleWindows {
            controllers.first { $0.window.isMiniaturized }?.window.deminiaturize(nil)
        }
        return true
    }

    /// ⌘Q (or a quit from the Dock, or NSRunningApplication.terminate): stop viewing this app's windows
    /// and quit. The remote app keeps running.
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        quitting = true
        log("phantom \(appName): quitting; closing its \(controllers.count) stream(s) (the remote app keeps running)")
        controllers.forEach { $0.closeLocally() } // each sends closeStream
        guard let c = relay.conn else { return .terminateNow }
        // Quit once the closes have gone out (at most 0.5 s). The reply goes through the run loop, not
        // the main dispatch queue: terminate may have been called from a main-queue block (Wisp's
        // quit), and AppKit's wait for the reply can't run main-queue blocks then.
        var replied = false
        let reply = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
        c.send(.bye, completion: { onMainRunLoop(reply) })
        let t = Timer(timeInterval: 0.5, repeats: false) { _ in reply() }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
        return .terminateLater
    }

    /// Quits (closing the streams) from outside the main dispatch queue's current block (see above).
    private func quit() {
        quitting = false
        onMainRunLoop { NSApp.terminate(nil) }
    }

    private func alert(_ title: String, _ text: String) {
        onMainRunLoop { [self] in
            NSApp.activate()
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.runModal()
            if !connected { quitting = true; NSApp.terminate(nil) }
        }
    }

    // MARK: Menus

    /// The Dock menu: this app's windows on the host (open ones checked; choosing one opens it or
    /// brings it forward). AppKit adds the open windows above it, as for any app.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        fillRemoteWindows(m)
        return m
    }

    private func fillRemoteWindows(_ m: NSMenu) {
        m.autoenablesItems = false
        if let notice {
            let n = NSMenuItem(title: "⚠︎ " + notice, action: nil, keyEquivalent: "")
            n.isEnabled = false
            m.addItem(n)
        }
        m.addItem(.sectionHeader(title: "Windows on \(hostName)"))
        if remoteWindows.isEmpty {
            let n = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            n.isEnabled = false
            m.addItem(n)
        }
        for w in remoteWindows {
            let open = streams.values.contains { $0.windowID == w.id }
            let mi = NSMenuItem(title: w.title.isEmpty ? appName : w.title, action: #selector(openRemote(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Int(w.id)
            mi.state = open ? .on : .off
            m.addItem(mi)
        }
    }

    @objc private func openRemote(_ sender: NSMenuItem) {
        let wid = UInt32(sender.tag)
        if let c = controllers.first(where: { $0.stream?.windowID == wid }) { c.bringToFront(); return }
        notice = nil
        relay.send(.openWindow) { $0.u32(wid) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === dockWindowsMenu else { return }
        menu.removeAllItems()
        fillRemoteWindows(menu)
    }

    @objc private func about(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "\(appName) (remote on \(hostName))",
            .applicationVersion: "",
            .version: "",
            .credits: NSAttributedString(string: "\(appName) is running on \(hostName). \(Brand.name) shows its windows here and sends your mouse and keyboard to it.\nQuitting here stops viewing its windows; the app keeps running on \(hostName).",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    private func makePhantomMenu() -> NSMenu {
        let main = mainMenu
        let appItem = appMenuItem
        let app = appMenu
        app.title = appName
        let about = NSMenuItem(title: "About \(appName) (remote on \(hostName))", action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        app.addItem(about)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let windowItem = windowMenuItem
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close Window on \(hostName)", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Stop Viewing This Window", action: #selector(RemoteView.stopViewing(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let open = NSMenuItem(title: "Windows on \(hostName)", action: nil, keyEquivalent: "")
        dockWindowsMenu.delegate = self
        open.submenu = dockWindowsMenu
        windowMenu.addItem(open)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

/// Runs `f` on the main thread from the run loop (also inside modal loops), not from the main dispatch queue.
private func onMainRunLoop(_ f: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking], block: f)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// The phantom's StreamLink: everything goes to Wisp over the socket, which passes it to the host.
final class PhantomRelay: StreamLink {
    var conn: IPCConnection?
    weak var owner: PhantomAppDelegate?

    func send(_ t: PhantomMsg, _ build: (inout Writer) -> Void = { _ in }) { conn?.send(t, build) }

    func sendInput(_ stream: UInt16, _ d: Data, discrete: Bool) {
        send(.input) { $0.u16(stream); $0.u8(discrete ? 1 : 0); $0.bytes(d) }
    }
    func resizeWindow(_ stream: UInt16, _ size: CGSize, id: UInt32) {
        send(.resize) {
            $0.u16(stream)
            $0.u16(UInt16(clamping: max(1, Int(size.width.rounded())))); $0.u16(UInt16(clamping: max(1, Int(size.height.rounded()))))
            $0.u32(id)
        }
    }
    func closeStream(_ stream: UInt16) { send(.closeStream) { $0.u16(stream) } }
    func closeRemoteWindow(_ stream: UInt16) { send(.closeRemote) { $0.u16(stream) } }

    /// The key window's screen (else the main one): Wisp tells the host, which sizes its virtual displays to it.
    func sendScreen() {
        DispatchQueue.main.async { [self] in
            guard let s = NSApp.keyWindow?.screen ?? NSApp.windows.first(where: \.isVisible)?.screen ?? NSScreen.main,
                  let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
            send(.screen) { $0.u32(id) }
        }
    }

    func frameDecoded(_ t: FrameTiming) { send(.frameTiming) { $0.timing(t, displayed: 0) } }
    func frameDisplayed(_ t: FrameTiming) { send(.frameTiming) { $0.timing(t, displayed: nowMicros()) } }
}

/// A stream shown by this phantom: its decoder, and the latest info and chrome (replayed to a window
/// that attaches late). Frames arrive complete from Wisp on the connection's queue and are decoded there.
final class PhantomStream: ViewerStream {
    let id: UInt16
    let windowID: UInt32
    private let relay: PhantomRelay
    private let decoder = Decoder()
    private var decoding: FrameTiming?
    /// Waiting for a keyframe (at the start, or after a frame failed to decode): other frames are skipped.
    private var needKey = true
    /// When we last asked Wisp for a keyframe (frames keep coming but none is a keyframe: ask again each second).
    private var askedKey: UInt64 = 0

    // Main queue.
    private var info: RemoteInfo?
    private var chrome: WindowChrome?
    private var isGone = false
    private var isClosed = false
    private var onInfo: ((RemoteInfo) -> Void)?
    private var onChrome: ((WindowChrome) -> Void)?
    private var onGone: (() -> Void)?
    private var onClosed: (() -> Void)?

    private let imageLock = NSLock()
    private var onImage: ((CVPixelBuffer, FrameTiming) -> Void)?
    private var lastImage: (CVPixelBuffer, FrameTiming)?

    init(id: UInt16, windowID: UInt32, relay: PhantomRelay) {
        self.id = id
        self.windowID = windowID
        self.relay = relay
        decoder.onImage = { [weak self] pb in
            guard let self, var t = decoding else { return }
            t.decoded = nowMicros()
            decoding = t
            relay.frameDecoded(t)
            imageLock.lock()
            lastImage = (pb, t)
            let sink = onImage
            imageLock.unlock()
            sink?(pb, t)
        }
    }

    func attach(info: ((RemoteInfo) -> Void)?, chrome: ((WindowChrome) -> Void)?, gone: (() -> Void)?,
                closed: (() -> Void)?, image: ((CVPixelBuffer, FrameTiming) -> Void)?) {
        onInfo = info; onChrome = chrome; onGone = gone; onClosed = closed
        if let i = self.info { info?(i) }
        if let c = self.chrome { chrome?(c) }
        imageLock.lock()
        onImage = image
        let last = lastImage
        imageLock.unlock()
        if let last { image?(last.0, last.1) }
        if isGone { gone?() } else if isClosed { closed?() }
    }

    func detach() {
        onInfo = nil; onChrome = nil; onGone = nil; onClosed = nil
        imageLock.lock(); onImage = nil; imageLock.unlock()
    }

    func received(_ i: RemoteInfo) { info = i; onInfo?(i) }
    func received(_ c: WindowChrome) { chrome = c; onChrome?(c) }
    func receivedGone() { isGone = true; onGone?() }
    func closed() { isClosed = true; onClosed?() }

    /// A complete frame (FrameTag onwards), on the connection's queue.
    func frame(_ payload: Data, reassembled: UInt64) {
        let arrived = nowMicros()
        var r = Reader(payload)
        guard let tag = FrameTag.read(&r), tag.stream == id else { return }
        let sample = r.rest()
        let key = (sample.first ?? 0) & 1 == 1
        if needKey && !key {
            // Wisp asked for a keyframe when it started relaying; if it got lost, ask again.
            if askedKey == 0 { askedKey = arrived } else if arrived - askedKey > 1_000_000 { askKeyframe(arrived) }
            return
        }
        decoding = FrameTiming(tag: tag, decodeStart: nowMicros(), reassembled: reassembled, relayed: arrived)
        if decoder.decode(sample) {
            needKey = false
        } else {
            // Wisp asks the host for a keyframe; frames are skipped until it arrives.
            needKey = true
            askKeyframe(arrived)
        }
    }

    private func askKeyframe(_ now: UInt64) {
        askedKey = now
        relay.send(.decodeFailed) { $0.u16(self.id) }
    }
}
