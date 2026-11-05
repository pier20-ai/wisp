// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// The main Wisp process's side of phantom apps (docs/multi-window.md §5): one phantom per remote
/// app, made and launched on demand; streams routed to the phantom of their app; complete frames
/// relayed to it as they leave reassembly (it decodes them itself); its input, resizes and closes
/// passed on to the host. Main queue, except where noted.
final class PhantomHub {
    private unowned let session: ViewerSession
    private var client: Client { session.client }
    private var hostName: String { session.hostName }
    private var listener: IPCListener?
    /// Called when what the menu shows changes (a window opened or closed in a phantom).
    var onChange: (() -> Void)?

    /// One remote app's phantom.
    private final class Phantom {
        let appKey: String
        var appName: String
        var conn: IPCConnection?
        /// Streams of this app, in the order they opened.
        var streams: [RemoteStream] = []
        /// Streams waiting for the phantom to connect.
        var waiting: [RemoteStream] = []
        var launching = false
        var app: NSRunningApplication?
        /// Its bundle is out of date (e.g. the icon changed) but it's running: rebuild after it quits.
        var stale = false
        /// It was started from the Dock (not by us), or clicked there with no windows: it wants its
        /// app's frontmost window (from a fresh window list), or a new one.
        var wantsWindow = false
        /// When the host last said a new window of this app is held back by its limit.
        var heldAt = Date.distantPast
        init(appKey: String, appName: String) { self.appKey = appKey; self.appName = appName }
    }
    private var phantoms: [String: Phantom] = [:]
    private var windows: [RemoteWindow] = []
    private var hasList = false
    /// Large icons received this session (appKey -> PNG), and phantoms waiting for one.
    private var icons: [String: Data] = [:]
    private var iconWaiters: [String: [(Data?) -> Void]] = [:]
    private var lastConnection = ""
    private var lastHostStatus = ""
    /// The screen the phantoms' windows are on (they report it), for the host's virtual displays.
    private(set) var screen: NSScreen?
    private let builder = DispatchQueue(label: "wisp.phantom-builder")
    private var stopped = false
    /// No App Nap while connected: this process is an accessory app with no windows, yet every frame passes through it.
    private var activity: NSObjectProtocol?

    init(session: ViewerSession) { self.session = session }

    func start() throws {
        let l = try IPCListener(path: PhantomPaths.socket)
        l.onConnection = { [weak self] c in self?.accepted(c) }
        l.start()
        listener = l
        builder.async { PhantomStore.removeLegacy() } // bundles in the old layout (before named bundles)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "relaying remote windows to phantom apps")
        log("phantom apps: listening on \(PhantomPaths.socket)")
    }

    /// Streams open (shown, or waiting for their phantom to start).
    var streamCount: Int { phantoms.values.reduce(0) { $0 + $1.streams.count + $1.waiting.count } }

    func isOpen(windowID id: UInt32) -> Bool {
        phantoms.values.contains { $0.streams.contains { $0.windowID == id } || $0.waiting.contains { $0.windowID == id } }
    }

    /// If window `id` is open in a phantom: brings it forward there (true also while its phantom starts).
    func focus(windowID id: UInt32) -> Bool {
        if phantoms.values.contains(where: { $0.waiting.contains { $0.windowID == id } }) { return true }
        guard let p = phantoms.values.first(where: { $0.streams.contains { $0.windowID == id } }),
              let s = p.streams.first(where: { $0.windowID == id }) else { return false }
        p.conn?.send(.focus) { $0.u16(s.id) }
        activate(p)
        return true
    }

    /// Test hook (WISP_TEST_CLOSE): window `id`'s phantom closes it as Window > Stop Viewing does.
    func stopViewing(windowID id: UInt32) {
        for p in phantoms.values {
            if let s = p.streams.first(where: { $0.windowID == id }) { p.conn?.send(.stopViewing) { $0.u16(s.id) } }
        }
    }

    // MARK: Streams

    /// A stream opened (we asked, or the host shared it): its app's phantom shows it.
    func streamOpened(_ s: RemoteStream, appKey: String, appName: String) {
        guard !stopped else { return }
        let p = phantom(appKey, appName)
        if p.streams.contains(where: { $0 === s }) || p.waiting.contains(where: { $0 === s }) {
            p.conn?.send(.focus) { $0.u16(s.id) }
            activate(p)
            return
        }
        log("stream #\(s.id) (window \(s.windowID)) belongs to \(appName): shown by its phantom app")
        if let c = p.conn {
            bind(s, to: p, c)
            activate(p)
        } else {
            p.waiting.append(s)
            launch(p)
        }
        onChange?()
    }

    private func phantom(_ key: String, _ name: String) -> Phantom {
        if let p = phantoms[key] {
            if p.appName != name, !name.isEmpty { p.appName = name; p.stale = true }
            return p
        }
        let p = Phantom(appKey: key, appName: name)
        phantoms[key] = p
        return p
    }

    /// From now on stream `s` is shown by phantom `p`: its window info, chrome and frames go there.
    private func bind(_ s: RemoteStream, to p: Phantom, _ c: IPCConnection) {
        p.streams.append(s)
        c.send(.expect)
        c.send(.streamOpen) { $0.u16(s.id); $0.u32(s.windowID) }
        s.attach(info: { i in c.send(.host) { $0.bytes(i.encode(stream: s.id)) } },
                 chrome: { ch in c.send(.host) { $0.bytes(ch.encode(stream: s.id)) } },
                 gone: { [weak self] in
                     c.send(.host) { $0.bytes(message(.windowGone, stream: s.id)) }
                     self?.unroute(s)
                 },
                 closed: { [weak self] in
                     c.send(.host) { $0.bytes(message(.streamClosed, stream: s.id) { $0.u8(StreamCloseReason.windowGone.rawValue); $0.u32(s.windowID) }) }
                     self?.unroute(s)
                 },
                 image: nil)
        // Frames straight from the network queue to the phantom's socket. A phantom that stops reading
        // (hung, or its main thread stuck behind its socket queue) lets frames pile up there: over 60,
        // frames are dropped until it has caught up, and it restarts from a keyframe.
        final class Backlog { var dropping = false, dropped = 0, askedAt = Date.distantPast; var stall: StallEpisode; init(_ s: StallEpisode) { stall = s } }
        let b = Backlog(StallEpisode("stream #\(s.id) phantom relay (\(p.appName))", .phantom))
        s.relay { payload, at in
            let backlog = c.framesQueued
            let isKey = payload.count > FrameTag.size && payload[payload.startIndex + FrameTag.size] & 1 == 1
            if b.dropping {
                guard isKey, backlog < 10 else {
                    b.dropped += 1
                    if Date().timeIntervalSince(b.askedAt) > 1, backlog < 10 { b.askedAt = Date(); s.relayDecodeFailed() } // caught up: a keyframe
                    return
                }
                b.dropping = false
                b.stall.end("the phantom caught up (\(b.dropped) frames dropped); resumed with a keyframe")
            } else if backlog >= 60 {
                b.dropping = true
                b.dropped = 1
                b.stall.begin("\(backlog) frames queued on the socket to \(p.appName) that it hasn't read: dropping frames until it catches up, then a keyframe")
                return
            }
            c.send(.frame) { $0.u16(s.id); $0.u64(at); $0.bytes(payload) }
        }
        if !lastConnection.isEmpty { c.send(.connection) { $0.str(self.lastConnection) } }
    }

    /// Stream `s` is no longer shown by any phantom.
    private func unroute(_ s: RemoteStream) {
        s.detach()
        for p in phantoms.values {
            p.streams.removeAll { $0 === s }
            p.waiting.removeAll { $0 === s }
        }
        onChange?()
    }

    // MARK: Launching

    /// Makes sure phantom `p`'s bundle is current, then starts it (it connects back to us).
    private func launch(_ p: Phantom) {
        guard !p.launching else { return }
        p.launching = true
        var spec = PhantomSpec(host: hostName, appKey: p.appKey, appName: p.appName, icon: nil)
        let started = Date()
        let go = { [weak self] (icon: Data?) in
            guard let self else { return }
            spec.icon = icon
            builder.async {
                let result: Result<URL, Error>
                let wasCurrent = PhantomStore.isCurrent(spec)
                if wasCurrent { result = .success(spec.url) } else {
                    let t0 = Date()
                    result = Result { try PhantomStore.make(spec) }
                    if case .success = result {
                        log(String(format: "made phantom app %@ (%@, signed %@) in %.0f ms", spec.url.path, spec.bundleID,
                                   PhantomStore.identity == "-" ? "ad-hoc" : PhantomStore.identity, Date().timeIntervalSince(t0) * 1000))
                    }
                }
                DispatchQueue.main.async { self.open(p, result, since: started) }
            }
        }
        // A bundle that's current apart from (maybe) the icon starts at once; the host's icon, when it
        // arrives, is compared and the bundle rebuilt after the phantom quits if it changed.
        if PhantomStore.isCurrent(spec) {
            go(nil)
            withIcon(p.appKey, timeout: 10) { [weak self] icon in self?.iconArrived(p, icon) }
        } else {
            withIcon(p.appKey, timeout: 1.5) { icon in go(icon ?? self.smallIcon(p.appKey)) }
        }
    }

    private func open(_ p: Phantom, _ result: Result<URL, Error>, since: Date) {
        guard !stopped else { return }
        switch result {
        case .failure(let e):
            p.launching = false
            log("couldn't make the phantom app for \(p.appName): \(e.localizedDescription)")
            let streams = p.waiting
            p.waiting = []
            streams.forEach { client.closeStream($0.id); $0.detach() }
            onChange?()
        case .success(let url):
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.addsToRecentItems = false
            cfg.createsNewApplicationInstance = false
            // Test hooks reach the phantom too (WISP_TEST_*, WISP_PHANTOM_*).
            cfg.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("WISP_") }
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
                DispatchQueue.main.async {
                    p.launching = false
                    if let err {
                        log("couldn't start the phantom app for \(p.appName): \(err.localizedDescription)")
                        return
                    }
                    p.app = app
                    log(String(format: "started phantom app %@ (pid %d) in %.0f ms", p.appName, app?.processIdentifier ?? 0,
                               Date().timeIntervalSince(since) * 1000))
                }
            }
        }
    }

    /// Brings phantom `p` to the front (LaunchServices may activate another app; we may not be active).
    private func activate(_ p: Phantom) {
        guard let url = p.app?.bundleURL ?? (p.conn != nil ? PhantomSpec(host: hostName, appKey: p.appKey, appName: p.appName).url : nil) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
    }

    // MARK: Icons

    private func smallIcon(_ key: String) -> Data? { windows.first { $0.entry.appKey == key }?.icon }

    /// Calls `f` with app `key`'s large icon when it arrives (nil after `timeout`).
    private func withIcon(_ key: String, timeout: TimeInterval, _ f: @escaping (Data?) -> Void) {
        if let png = icons[key] { f(png); return }
        let first = iconWaiters[key] == nil
        var done = false
        let once: (Data?) -> Void = { d in if !done { done = true; f(d) } }
        iconWaiters[key, default: []].append(once)
        if first { client.requestIcon(key, px: 512) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once(nil) }
    }

    func largeIcon(_ key: String, px: Int, png: Data) {
        icons[key] = png
        let waiters = iconWaiters.removeValue(forKey: key) ?? []
        waiters.forEach { $0(png) }
    }

    /// The host's icon for a phantom that was started from an existing bundle: if it differs, the
    /// running phantom shows it now and its bundle is rebuilt once it quits.
    private func iconArrived(_ p: Phantom, _ icon: Data?) {
        guard let icon else { return }
        let url = PhantomSpec(host: hostName, appKey: p.appKey, appName: p.appName).url
        guard PhantomStore.info(at: url)?["iconHash"] as? String != PhantomStore.hash(icon) else { return }
        log("the icon of \(p.appName) changed on \(hostName): updating its phantom app")
        p.stale = true
        if let png = PhantomStore.phantomIconPNG(icon) { p.conn?.send(.icon) { $0.bytes(png) } }
    }

    /// After phantom `p` quit: rebuild its bundle if it went out of date while it ran.
    private func rebuildIfStale(_ p: Phantom) {
        guard p.stale, !p.launching else { return }
        p.stale = false
        let spec = PhantomSpec(host: hostName, appKey: p.appKey, appName: p.appName, icon: icons[p.appKey])
        builder.async {
            do { _ = try PhantomStore.make(spec); log("rebuilt the phantom app for \(spec.appName)") } catch {
                log("couldn't rebuild the phantom app for \(spec.appName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Phantom connections

    /// A phantom connected: it says who it is first.
    private func accepted(_ c: IPCConnection) {
        var phantom: Phantom?
        c.onMessage = { [weak self] t, d in
            guard let self else { return }
            // Input and frame timings go straight on from the socket's queue; the rest on main.
            switch t {
            case .input:
                var r = Reader(d)
                guard let sid = r.u16(), let discrete = r.u8() else { return }
                client.sendInput(sid, r.rest(), discrete: discrete != 0)
            case .frameTiming:
                var r = Reader(d)
                guard let (timing, displayed) = r.timing() else { return }
                if displayed == 0 { client.latency.frameDecoded(timing) } else { client.latency.frameDisplayed(timing, at: displayed) }
            default:
                DispatchQueue.main.async {
                    if t == .hello { phantom = self.hello(c, d) } else if let p = phantom { self.handle(t, d, from: p) }
                }
            }
        }
        c.onClose = { [weak self] in DispatchQueue.main.async { if let p = phantom { self?.gone(p, c) } } }
    }

    private func hello(_ c: IPCConnection, _ d: Data) -> Phantom? {
        var r = Reader(d)
        guard let host = r.str(), let key = r.str(), let pid = r.u32() else { Log.warning(.ipc, "a phantom's hello can't be read (\(d.count) B)"); c.cancel(); return nil }
        guard host == hostName, !stopped else {
            Log.info(.phantom, "phantom of \(key) (pid \(pid)) is for \(host), but this is \(stopped ? "a stopped session" : "connected to \(hostName)"): turned away")
            c.send(.helloAck) { $0.u8(0); $0.str(self.hostName); $0.str("\(Brand.name) is connected to \(self.hostName), not \(host).") }
            return nil
        }
        let name = windows.first { $0.entry.appKey == key }?.entry.appName ?? NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? key
        let p = phantom(key, name)
        if let old = p.conn, old !== c { old.cancel() }
        p.conn = c
        p.app = NSRunningApplication(processIdentifier: pid_t(pid))
        c.send(.helloAck) { $0.u8(1); $0.str(self.hostName); $0.str("") }
        Log.info(.phantom, "phantom app \(p.appName) (\(key)) connected (pid \(pid)); \(p.waiting.count) streams waiting for it")
        if hasList { sendWindows(p) }
        if !lastHostStatus.isEmpty { c.send(.hostStatus) { $0.str(self.lastHostStatus) } }
        if let icon = icons[key], p.stale, let png = PhantomStore.phantomIconPNG(icon) { c.send(.icon) { $0.bytes(png) } }
        let waiting = p.waiting
        p.waiting = []
        waiting.forEach { bind($0, to: p, c) }
        if waiting.isEmpty, p.streams.isEmpty, !p.launching {
            // Started from the Dock or Spotlight: show the app's frontmost window.
            p.wantsWindow = true
            openFrontmost(p)
        }
        onChange?()
        return p
    }

    private func handle(_ t: PhantomMsg, _ d: Data, from p: Phantom) {
        var r = Reader(d)
        switch t {
        case .resize:
            guard let sid = r.u16(), let w = r.u16(), let h = r.u16(), let id = r.u32() else { return }
            client.resizeWindow(sid, CGSize(width: Int(w), height: Int(h)), id: id)
        case .closeStream:
            guard let sid = r.u16(), let s = p.streams.first(where: { $0.id == sid }) else { return }
            client.closeStream(sid)
            unroute(s)
        case .closeRemote:
            if let sid = r.u16() { client.closeRemoteWindow(sid) }
        case .openWindow:
            guard let wid = r.u32() else { return }
            if wid == 0 {
                // A Dock click with no windows open: decide on a fresh list (windows closed a moment
                // ago may still be in the last one). openFrontmost runs when it arrives.
                p.wantsWindow = true
                client.requestWindowList()
            } else {
                session.open(windowID: wid)
            }
        case .screen:
            guard let id = r.u32() else { return }
            screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            client.sendScreen()
        case .decodeFailed:
            if let sid = r.u16() { p.streams.first { $0.id == sid }?.relayDecodeFailed() }
        case .toHost:
            // A phantom's menu requests and presses go to the host, for its own app only.
            guard let (type, payload) = MessageParser().feed(d).first, type == .menuRequest || type == .menuPress else { return }
            var m = Reader(payload)
            guard m.str() == p.appKey else { return }
            client.sendControl(d)
        case .bye:
            log("phantom app \(p.appName) is quitting (its windows are closed; the remote app keeps running)")
        default:
            break
        }
    }

    /// Phantom `p`'s connection closed (it quit, or crashed): its streams end.
    private func gone(_ p: Phantom, _ c: IPCConnection) {
        guard p.conn === c else { return }
        p.conn = nil
        p.app = nil
        for s in p.streams {
            client.closeStream(s.id)
            s.detach()
        }
        if !p.streams.isEmpty { log("phantom app \(p.appName) went away: closed its \(p.streams.count) stream(s)") }
        p.streams = []
        rebuildIfStale(p)
        onChange?()
    }

    /// A phantom with no windows open wants one (Dock click, or started from the Dock): the app's
    /// frontmost remote window (the host lists front to back). With windows open (or on their way),
    /// the first comes forward instead. With none on the host either, the app is asked to open one,
    /// as clicking its Dock icon there would: it gets a reopen event (Finder opens a new window), and
    /// the host streams the new window by itself.
    private func openFrontmost(_ p: Phantom) {
        if let s = p.streams.first { p.wantsWindow = false; p.conn?.send(.focus) { $0.u16(s.id) }; return }
        guard p.waiting.isEmpty else { p.wantsWindow = false; return }
        guard hasList else { client.requestWindowList(); return } // retried when the list arrives
        p.wantsWindow = false
        if let w = windows.first(where: { $0.entry.appKey == p.appKey }) {
            session.open(windowID: w.entry.id)
        } else {
            reopen(p)
        }
    }

    /// Asks the host to reopen phantom `p`'s app. If no window of it arrives (an app that opens
    /// none on reopen, or an older host), the phantom says the app has no windows there.
    private func reopen(_ p: Phantom) {
        log("\(p.appName) has no windows on \(hostName): asking it to open one, as a Dock click there would")
        client.reopenApp(p.appKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak p] in
            guard let self, let p, p.conn != nil, p.streams.isEmpty, p.waiting.isEmpty,
                  Date().timeIntervalSince(p.heldAt) > 6 else { return }
            p.conn?.send(.notice) { $0.str("\(p.appName) has no windows open on \(self.hostName).") }
        }
    }

    // MARK: From the session

    func windowList(_ list: [RemoteWindow]) {
        windows = list
        hasList = true
        for p in phantoms.values where p.conn != nil {
            sendWindows(p)
            if p.wantsWindow { openFrontmost(p) }
        }
    }

    private func sendWindows(_ p: Phantom) {
        let mine = windows.filter { $0.entry.appKey == p.appKey }.map { w -> WindowEntry in
            var e = w.entry
            e.shared = p.streams.contains { $0.windowID == e.id } // "open here"
            return e
        }
        p.conn?.send(.windows) { $0.bytes(WindowEntry.encode(mine)) }
    }

    /// An app's menu bar arrived (a menuTree message): its phantom builds its menus from it.
    func menuTree(_ key: String, _ msg: Data) {
        phantoms[key]?.conn?.send(.menu) { $0.bytes(msg) }
    }

    /// App `key` opened a new window that the host can't stream (its limit): its phantom says so.
    func newWindowHeld(appKey key: String, text: String) {
        guard let p = phantoms[key] else { return }
        p.heldAt = Date()
        p.conn?.send(.notice) { $0.str(text) }
    }

    /// The host refused to open window `id` (e.g. its stream limit): its app's phantom says so too.
    func refused(windowID id: UInt32, text: String) {
        guard let key = windows.first(where: { $0.entry.id == id })?.entry.appKey, let p = phantoms[key] else { return }
        p.conn?.send(.notice) { $0.str(text) }
    }

    func hostStatus(_ s: String) {
        lastHostStatus = s
        phantoms.values.forEach { $0.conn?.send(.hostStatus) { $0.str(s) } }
    }

    func connection(_ msg: String?) {
        lastConnection = msg ?? ""
        phantoms.values.forEach { $0.conn?.send(.connection) { $0.str(self.lastConnection) } }
    }

    /// Once a second: each phantom window's title line.
    func updateStats(latency lat: String, down: Int, up: Int) {
        for p in phantoms.values {
            guard let c = p.conn else { continue }
            for s in p.streams {
                let line = statsLine(latency: lat, down: down, up: up, frames: s.frames.take(), repaired: s.resent.take() + s.fecRecovered.take())
                c.send(.stats) { $0.u16(s.id); $0.str(line) }
            }
        }
    }

    /// Disconnecting: every phantom closes its windows and quits.
    func stop() {
        guard !stopped else { return }
        stopped = true
        for p in phantoms.values {
            p.conn?.send(.quit)
            p.streams.forEach { $0.detach() }
            p.streams = []
        }
        listener?.stop()
        unlink(PhantomPaths.socket)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
