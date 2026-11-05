// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit
import UniformTypeIdentifiers
import WispCommon

/// One streamed window: its capture, encoder pipeline and repair state (in Server, by stream ID),
/// where it is, its resize handshake and its chrome. Main queue only.
final class HostStream {
    let id: UInt16
    let windowID: UInt32
    let pipeline: Pipeline
    let target = WindowTarget()
    var title = ""
    var pid: pid_t = 0
    /// The window's app, as the window list names it (bundle ID or "pid:<n>"), and its name.
    var appKey = ""
    var appName = ""
    var capture: WindowCapture?
    var synthetic: SyntheticSource?
    var follow: DispatchSourceTimer?
    /// Re-reads the window's bounds now (the same check the 0.2 s follow timer runs).
    var followCheck: (() -> Void)?
    /// The frame being captured (global points).
    var current = CGRect.zero
    /// What windowInfo currently says, so it can be re-sent with a new resize acknowledgement.
    var info: (points: CGSize, pixels: CGSize, title: String)?
    /// The newest viewer resize request that has been applied and has settled; sent in windowInfo.
    var resizeAck: UInt32 = 0
    /// A resize request applied through Accessibility whose result we haven't seen in the window bounds yet.
    var awaitingResize: (id: UInt32, size: CGSize, deadline: Date)?
    var chrome = WindowChrome.unknown
    var chromeRecheck: DispatchWorkItem?
    /// Where the window was before we moved it onto its virtual display, to put it back.
    var moved: CGRect?
    /// This stream's own HiDPI virtual display (one per stream, side by side, so streamed windows
    /// never overlap). nil: shared from the window's own display.
    var display: VirtualDisplay?
    /// The display it had before the viewer's screen size changed, until the window is on the new one.
    var previousDisplay: VirtualDisplay?
    /// Where the window sits on the display it's captured on, relative to the display's top-left: it
    /// is pinned there, even if the displays are rearranged.
    var offset = CGPoint.zero
    /// The viewer has this stream open: its frames, info and chrome are sent.
    var subscribed = false
    /// The window is being moved onto its display: the follow timer leaves it alone.
    var placing = false
    var closed = false
    var gone = false
    /// Panels shown with this window (an Open panel, a dialog, …; see Panels.swift), by window ID.
    var panels: [UInt32: StreamPanel] = [:]
    /// Processes other than the app whose windows the capture filter includes (its panel services).
    var filterHelpers: Set<pid_t> = []
    /// The synthetic host's out-of-process panel over this window, if one is open.
    var syntheticPanel: SyntheticPanel?

    init(id: UInt16, windowID: UInt32, opts: HostOptions, server: Server) {
        self.id = id
        self.windowID = windowID
        pipeline = Pipeline(stream: id, opts: opts, server: server)
        target.windowID = windowID
    }

    func stopCapture() async {
        follow?.cancel()
        follow = nil
        followCheck = nil
        chromeRecheck?.cancel()
        synthetic?.stop()
        synthetic = nil
        let cap = capture
        capture = nil
        await cap?.stop()
    }
}

/// Shares windows: owns the network server, one capture → encode → send pipeline per streamed window,
/// and input injection. The host operator picks the primary window (the CLI's --window, the app's
/// picker); the viewer opens it and any other windows as streams of their own.
final class Host {
    let server: Server
    let injector = Injector()
    private let menuReader = MenuReader()
    private let syntheticMenus = SyntheticMenus()
    /// Streams by ID (main queue). IDs are never reused while the host runs.
    private(set) var streams: [UInt16: HostStream] = [:]
    private var nextStreamID: UInt16 = 1
    /// The window the operator chose to share; the viewer's openStream(0) opens it.
    private(set) var primaryWindowID: UInt32?
    private var primary: HostStream? { streams.values.first { $0.windowID == primaryWindowID } }
    var sharedTitle: String? { primary?.title }
    /// Called on the main queue after the primary window changes, with its title.
    var onShareChanged: ((String) -> Void)?
    /// Clipboard sync with the viewer (nil when HostOptions.clipboard is off). Main queue.
    let clipboard: ClipboardSync?

    private let opts: HostOptions
    /// Removes the virtual displays a while after the last viewer left.
    private var teardown: DispatchWorkItem?
    static let teardownDelay: TimeInterval = 30
    /// The synthetic host (`shareSynthetic`): test patterns, no permissions needed.
    private var isSynthetic = false
    /// Its windows (pixel sizes), each of one of `syntheticApps`. Closing one removes it; reopening an
    /// app, or its File > New Window, adds one.
    private var syntheticWindows: [(id: UInt32, size: CGSize, app: Int)] = []
    private var syntheticBase = CGSize.zero
    /// Window IDs are never reused, as on a real host.
    private var nextSyntheticID: UInt32 = 1
    /// The synthetic windows pretend to belong to two apps (1 and 2: Synth Alpha, 3: Synth Beta), so a
    /// viewer makes two phantom apps for them.
    static let syntheticApps: [(key: String, name: String, letter: String, hue: CGFloat)] = [
        (Brand.syntheticAppKeyPrefix + "alpha", "Synth Alpha", "A", 0.58),
        (Brand.syntheticAppKeyPrefix + "beta", "Synth Beta", "B", 0.08),
    ]

    // Following new windows (docs/multi-window.md §12): while the viewer shows an app (one of its
    // windows is streamed, or a reopen or menu item was just sent to it), a new standard window of
    // that app opens as a stream by itself.
    private final class Followed {
        /// Its windows seen so far (on screen, layer 0). Anything else that turns up is new.
        var known: Set<UInt32>
        /// Followed until then even with no stream open (after a reopen or a menu item).
        var armedUntil: Date
        /// New windows Accessibility doesn't list yet: how many times we looked.
        var unverified: [UInt32: Int] = [:]
        init(known: Set<UInt32>, armedUntil: Date) { self.known = known; self.armedUntil = armedUntil }
    }
    private struct NewWindow { var id: UInt32; var appKey: String; var appName: String; var pid: pid_t }
    private var followed: [String: Followed] = [:]
    private var followTimer: DispatchSourceTimer?
    private var followPolling = false
    /// New windows not streamed because of the limit, oldest first: opened when a stream closes.
    private var heldNew: [NewWindow] = []
    static let followInterval: TimeInterval = 0.5
    static let armSeconds: TimeInterval = 10
    private var switching: Task<Void, Never>?
    // Panels (Panels.swift): an app's Open panel, dialogs and the like, shown in its stream.
    private let panels = PanelTracker()
    private var panelTimer: DispatchSourceTimer?
    static let panelInterval: TimeInterval = 0.25
    /// The stream of each app (by app key) that last got a click, a key press or a menu item, and when:
    /// a panel the app opens goes with that stream.
    private var lastInput: [String: (stream: UInt16, at: Date)] = [:]
    private var statsTimer: DispatchSourceTimer?
    private var rateTimer: DispatchSourceTimer?
    private var sessionTimer: DispatchSourceTimer?
    private var lastStatus = ""
    private var lastActivity = Date.distantPast
    private var activityID: IOPMAssertionID = 0
    private var rateScale = 1.0
    private var activeStreams = -1

    // A HiDPI virtual display per streamed window, each sized to the viewer's screen (see
    // VirtualDisplay.swift and HostStream.display).
    private var viewerPoints: CGSize?
    /// A display failed to come up (or the API is missing): from then on, windows are shared where they are.
    private var vdisplayFailed = false
    private var hasVirtualDisplays: Bool { streams.values.contains { $0.display != nil || $0.previousDisplay != nil } }

    // For the host window (main queue).
    /// The viewer's latest report (every 5 s), and when it came.
    private(set) var lastStats: (stats: ViewerStats, at: Date)?
    /// The session's screen is locked (input then goes to the lock screen).
    private(set) var screenLocked = false
    var maxStreams: Int { opts.maxStreams }
    /// The primary window's ID, if one is chosen.
    var primaryID: UInt32? { primaryWindowID }

    /// One streamed (or primary) window, as the host window shows it.
    struct StreamStatus {
        var id: UInt16
        var windowID: UInt32
        var title: String
        var appName: String
        var points: CGSize
        var pixels: CGSize
        /// The viewer has it open (else it's the primary window, waiting to be opened).
        var open: Bool
        var isPrimary: Bool
        /// Frames sent so far (the window computes fps from two readings).
        var framesSent: Int
    }

    var streamStatuses: [StreamStatus] {
        streams.values.filter { !$0.closed }.sorted { $0.id < $1.id }.map { s in
            StreamStatus(id: s.id, windowID: s.windowID, title: s.title, appName: s.appName, points: s.info?.points ?? .zero,
                         pixels: s.info?.pixels ?? .zero, open: s.subscribed, isPrimary: s.windowID == primaryWindowID,
                         framesSent: server.framesSent(s.id))
        }
    }

    /// Stream `id`'s latest frame, `width` px wide (main queue).
    func thumbnail(stream id: UInt16, width: CGFloat, _ done: @escaping (CGImage?) -> Void) {
        guard let s = streams[id] else { done(nil); return }
        s.pipeline.thumbnail(width: width, done)
    }

    init(opts: HostOptions) {
        self.opts = opts
        server = Server(paceMbps: opts.paceMbps, fecGroup: opts.fec)
        let main = DispatchQueue.main
        if opts.clipboard {
            let server = server
            let cb = ClipboardSync(side: .host) { d, done in server.sendControl(d, done: done) }
            clipboard = cb
            server.hostFeatures |= Wire.Feature.clipboard
            server.onClipboard = { t, p in main.async { cb.receive(t, p) } }
        } else {
            clipboard = nil
        }
        server.onKeyframeRequest = { [weak self] s in main.async { self?.stream(s)?.pipeline.requestKeyframe() } }
        server.onVideoPathOpen = { [weak self] in
            main.async { self?.streams.values.filter(\.subscribed).forEach { $0.pipeline.requestKeyframe() } }
        }
        // Input, resizes and the close button call WindowServer and Accessibility on the main thread,
        // so they wait while a virtual display is being added or removed (DisplayGate).
        server.onInput = { [weak self] s, t, p in
            main.async {
                DisplayGate.whenIdle { [weak self] in
                    guard let self, let st = stream(s) else { return }
                    if t == .mouseDown || t == .key || t == .scroll { lastInput[st.appKey] = (st.id, Date()) }
                    injector.handle(t, p, target: st.target)
                    server.noteInjected(st.id)
                    if st.synthetic != nil {
                        logSyntheticInput(st, t, p)
                        if syntheticPanelInput(st, t, p) { return }
                    }
                    if t == .mouseUp { syntheticClick(st, p) }
                }
            }
        }
        server.onOpenStream = { [weak self] id in main.async { self?.serially { await $0.open(windowID: id) } } }
        server.onCloseStream = { [weak self] s in main.async { self?.serially { await $0.viewerClosed(s) } } }
        server.onWindowListRequest = { [weak self] in Task { @MainActor in await self?.sendWindowList() } }
        server.onIconRequest = { [weak self] key, px in main.async { self?.sendLargeIcon(key, px: px) } }
        server.onMenuRequest = { [weak self] key, menu in main.async { self?.sendMenus(key, menu: menu) } }
        // A menu item may open a window: follow its app first (see arm).
        server.onMenuPress = { [weak self] m in
            main.async { self?.arm(m.appKey) { DisplayGate.whenIdle { self?.pressMenu(m) } } }
        }
        server.onReopenApp = { [weak self] key in main.async { self?.arm(key) { DisplayGate.whenIdle { self?.reopen(key) } } } }
        server.onViewerScreen = { [weak self] size, scale in
            main.async {
                log("viewer screen: \(Int(size.width))x\(Int(size.height)) pt @\(scale)x")
                self?.serially { await $0.viewerScreenChanged(size) }
            }
        }
        server.onResizeWindow = { [weak self] s, size, id in
            main.async {
                DisplayGate.whenIdle { [weak self] in guard let self, let st = stream(s) else { return }; resize(st, to: size, id: id) }
            }
        }
        server.onWindowAction = { [weak self] s, action in
            main.async {
                DisplayGate.whenIdle { [weak self] in
                    self?.windowAction(s, action)
                }
            }
        }
        server.onViewerConnected = { [weak self] in
            main.async { self?.clipboard?.disconnected(); self?.stopFollowing(); self?.cancelTeardown(); self?.serially { await $0.resetStreams() } }
        }
        server.onViewerGone = { [weak self] in
            main.async { self?.clipboard?.disconnected(); self?.stopFollowing(); self?.serially { await $0.resetStreams() }; self?.scheduleTeardown() }
        }
        server.probeInfo = { [weak self] in
            guard let self else { return ProbeReply(hostName: "", hasPrimary: false, viewerConnected: false, openStreams: 0, maxStreams: 0) }
            return ProbeReply(hostName: server.hostName, hasPrimary: primaryWindowID != nil, viewerConnected: server.hasViewerConnection,
                              openStreams: streams.values.filter(\.subscribed).count, maxStreams: opts.maxStreams)
        }
        server.onStats = { [weak self] s, from in
            main.async { self?.lastStats = (s, Date()) }
            log("viewer \(from): rtt \(ms(s.rttMin))/\(ms(s.rttAvg)) ms (min/avg) | video delay \(ms(s.videoP50))/\(ms(s.videoP95)) ms (p50/p95) | click→screen \(ms(s.inputP50))/\(ms(s.inputP95)) ms (\(s.inputSamples) samples) | \(s.fps) fps")
            if !s.stages.isEmpty { log("  stages p50/p95 ms: \(s.breakdown)") }
            if s.streams.count > 1 { log("  streams: \(s.perStream)") }
            StatsLog.append(s, from: "\(from)")
        }
    }

    /// The viewer's red button (action 1) for stream `s`; action 2 (synthetic host only, a test hook):
    /// that stream's app opens a new window.
    private func windowAction(_ s: UInt16, _ action: UInt8) {
        guard let st = stream(s) else { return }
        switch action {
        case 1 where isSynthetic:
            log("close action on synthetic stream #\(st.id): telling the viewer it's gone")
            serially { await $0.syntheticWindowClosed(st) }
        case 1:
            st.target.pressClose()
        case 2 where isSynthetic:
            let app = syntheticWindows.first { $0.id == st.windowID }?.app ?? 0
            arm(Self.syntheticApps[app].key) { [weak self] in self?.addSyntheticWindow(app: app, why: "new-window action") }
        case 3 where isSynthetic:
            lastInput[st.appKey] = (st.id, Date())
            openSyntheticPanel(appKey: st.appKey, why: "open-panel action")
        default:
            log("window action \(action) on stream #\(st.id): not supported here")
        }
    }

    // MARK: Reopening an app (a Dock click on its phantom, docs/multi-window.md §12)

    /// The viewer clicked app `key`'s phantom in the Dock with no windows of it open anywhere: do what
    /// a Dock click here would. Opening a running app through LaunchServices sends it the reopen
    /// ('rapp') Apple event, so Finder, TextEdit and the like open a window; an app that isn't
    /// running is launched. Its new window follows (arm was called first). Main queue, gated.
    private func reopen(_ key: String) {
        if isSynthetic {
            guard let app = Self.syntheticApps.firstIndex(where: { $0.key == key }) else { log("reopen: no synthetic app \(key)"); return }
            addSyntheticWindow(app: app, why: "reopened")
            return
        }
        let running = app(for: key).flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        guard let url = running?.bundleURL ?? (key.hasPrefix("pid:") ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)) else {
            log("reopen: \(key) isn't running and there's no app for it to launch")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.addsToRecentItems = false
        log("reopen: \(running == nil ? "launching" : "reopening") \(running?.localizedName ?? key), as a Dock click would")
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            if let err { log("reopen: \(key): \(err.localizedDescription)") } else { log("reopen: \(app?.localizedName ?? key) answered (pid \(app?.processIdentifier ?? 0))") }
        }
    }

    // MARK: Following new windows

    /// The apps followed now: those with a stream the viewer has open, and those armed lately.
    private func followedKeys() -> Set<String> {
        let now = Date()
        var keys = Set(streams.values.filter { $0.subscribed && !$0.closed && !$0.appKey.isEmpty }.map(\.appKey))
        for (k, f) in followed where f.armedUntil > now { keys.insert(k) }
        return keys
    }

    /// Follows app `key` for a while even with no stream open (a reopen or a menu item is about to
    /// go to it), then calls `then`. The first time, its windows are listed before `then` runs, so
    /// the window `then` makes counts as new.
    private func arm(_ key: String, then: @escaping () -> Void) {
        guard server.viewerFollowsNewWindows else { then(); return }
        let until = Date().addingTimeInterval(Self.armSeconds)
        if let f = followed[key] {
            f.armedUntil = max(f.armedUntil, until)
            startFollowing()
            then()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = await newWindowCandidates([key])
            let f = followed[key] ?? Followed(known: Set(now.map(\.id)), armedUntil: until)
            f.armedUntil = max(f.armedUntil, until)
            followed[key] = f
            startFollowing()
            then()
        }
    }

    private func startFollowing() {
        guard followTimer == nil, server.viewerFollowsNewWindows else { return }
        followTimer = every(Self.followInterval) { [weak self] in self?.followTick() }
    }

    /// A new viewer, or none: nothing is followed or held any more.
    private func stopFollowing() {
        followTimer?.cancel()
        followTimer = nil
        followed = [:]
        heldNew = []
    }

    /// Every 0.5 s while something is followed: list the followed apps' windows (ScreenCaptureKit,
    /// off the main thread) and stream the new ones. Never while a display is being added or removed.
    private func followTick() {
        let keys = followedKeys()
        for k in followed.keys where !keys.contains(k) { followed[k] = nil }
        guard !keys.isEmpty, server.viewerFollowsNewWindows else {
            followTimer?.cancel()
            followTimer = nil
            return
        }
        guard !followPolling, !DisplayGate.busy else { return }
        followPolling = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await newWindowCandidates(keys)
            followPolling = false
            DisplayGate.whenIdle { [weak self] in self?.noticeNewWindows(found, of: keys) }
        }
    }

    /// The on-screen, layer-0 windows of apps `keys` (the synthetic host's own list for it).
    @MainActor
    private func newWindowCandidates(_ keys: Set<String>) async -> [NewWindow] {
        if isSynthetic {
            return syntheticWindows.compactMap { w in
                let app = Self.syntheticApps[w.app]
                return keys.contains(app.key) ? NewWindow(id: w.id, appKey: app.key, appName: app.name, pid: 0) : nil
            }
        }
        guard let windows = await Host.windows(for: "following new windows") else { return [] }
        let mine = Bundle.main.bundleIdentifier
        return windows.compactMap { w in
            guard let app = w.owningApplication, app.bundleIdentifier != mine else { return nil }
            let key = Self.appKey(app)
            return keys.contains(key) ? NewWindow(id: w.windowID, appKey: key, appName: app.applicationName, pid: app.processID) : nil
        }
    }

    /// Compares what the poll found with what each followed app had: new standard windows open.
    /// Main queue, gated (Accessibility).
    private func noticeNewWindows(_ found: [NewWindow], of keys: Set<String>) {
        for key in keys {
            let mine = found.filter { $0.appKey == key }
            guard let f = followed[key] else {
                // Followed since this poll (a stream of it opened): what it has now is not new.
                followed[key] = Followed(known: Set(mine.map(\.id)), armedUntil: .distantPast)
                continue
            }
            for w in mine where !f.known.contains(w.id) {
                if streams.values.contains(where: { $0.windowID == w.id && !$0.closed }) { f.known.insert(w.id); continue }
                if panels.isPanel(w.id) || streams.values.contains(where: { $0.panels[w.id] != nil }) {
                    // Shown in its stream instead (Panels.swift): it never takes a stream of its own.
                    f.known.insert(w.id)
                    Log.info(.host, "follow: \(w.appName)'s new window \(w.id) is a panel: shown in its stream, not opened")
                    continue
                }
                switch isStandardWindow(w) {
                case true?:
                    f.known.insert(w.id)
                    f.unverified[w.id] = nil
                    Log.info(.host, "follow: \(w.appName) opened a new window (\(w.id))")
                    serially { await $0.openNewWindow(w) }
                case false?:
                    f.known.insert(w.id)
                    f.unverified[w.id] = nil
                    Log.info(.host, "follow: \(w.appName)'s new window \(w.id) isn't a standard window (a panel, sheet or the like): not opened")
                case nil:
                    // Not in the app's Accessibility windows yet (or a sheet, which isn't listed there): look again a few times.
                    let n = (f.unverified[w.id] ?? 0) + 1
                    f.unverified[w.id] = n
                    if n >= 4 { f.known.insert(w.id); f.unverified[w.id] = nil; Log.info(.host, "follow: \(w.appName)'s new window \(w.id) isn't an Accessibility window: not opened") }
                }
            }
        }
    }

    /// An ordinary document window (AXWindow, AXStandardWindow), not a panel, dialog or sheet. nil
    /// when Accessibility doesn't list it (yet). Without Accessibility there's no telling: yes.
    private func isStandardWindow(_ w: NewWindow) -> Bool? {
        if isSynthetic || !AXIsProcessTrusted() { return true }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &v) == .success,
              let all = v as? [AXUIElement], let ax = all.first(where: { cgWindowID(of: $0) == w.id }) else { return nil }
        // An Open or Save panel on its own is an AXStandardWindow too (macOS 27), told apart by its identifier.
        if PanelServices.panelIdentifiers.contains(axString(ax, kAXIdentifierAttribute)) { return false }
        return axString(ax, kAXRoleAttribute) == kAXWindowRole && axString(ax, kAXSubroleAttribute) == kAXStandardWindowSubrole
    }

    /// Streams new window `w` and tells the viewer, as if it had asked; at the limit, tells it so
    /// (newWindowHeld) and keeps the window for when a stream closes. A held window opens then even if
    /// the stream that closed was its app's last.
    @MainActor
    private func openNewWindow(_ w: NewWindow, held: Bool = false) async {
        guard server.viewerFollowsNewWindows, held || followed[w.appKey] != nil else { return }
        guard !streams.values.contains(where: { $0.windowID == w.id && !$0.closed }) else { return }
        guard streams.count < opts.maxStreams else {
            Log.info(.host, "follow: \(w.appName)'s new window \(w.id) not streamed: \(streams.count) windows are already (the limit); it opens when one closes")
            if !heldNew.contains(where: { $0.id == w.id }) { heldNew.append(w) }
            server.sendControl(message(.newWindowHeld) {
                $0.u32(w.id); $0.str(w.appKey); $0.str(w.appName)
                $0.u8(UInt8(clamping: self.streams.count)); $0.u8(UInt8(clamping: self.opts.maxStreams))
            })
            return
        }
        do {
            let s = try await startStream(windowID: w.id)
            Log.info(.host, "follow: streaming \(w.appName)'s new window \(w.id) as stream #\(s.id)")
            announce(s)
        } catch {
            Log.info(.host, "follow: could not stream \(w.appName)'s new window \(w.id): \(error.localizedDescription)")
        }
    }

    /// A stream closed: new windows held back by the limit open now, oldest first, while there's room.
    @MainActor
    private func openHeldWindows() async {
        while streams.count < opts.maxStreams, !heldNew.isEmpty {
            await openNewWindow(heldNew.removeFirst(), held: true)
        }
    }

    // MARK: Menu bars (docs/multi-window.md §10)

    /// The running app that `key` (a bundle ID or "pid:<n>") names: a streamed window's app first.
    private func app(for key: String) -> (pid: pid_t, name: String)? {
        if let s = streams.values.first(where: { $0.appKey == key && $0.pid != 0 }) { return (s.pid, s.appName) }
        if key.hasPrefix("pid:"), let pid = pid_t(key.dropFirst(4)), let a = NSRunningApplication(processIdentifier: pid) {
            return (pid, a.localizedName ?? key)
        }
        if let a = NSRunningApplication.runningApplications(withBundleIdentifier: key).first { return (a.processIdentifier, a.localizedName ?? key) }
        return nil
    }

    private func syntheticApp(key: String) -> String? {
        !isSynthetic ? nil : Self.syntheticApps.first { $0.key == key }?.name
    }

    /// The viewer wants app `key`'s menu bar (or one of its menus): read it now and send it.
    private func sendMenus(_ key: String, menu: UInt16) {
        if let name = syntheticApp(key: key) {
            syntheticMenus.trees(appKey: key, appName: name, menu: menu).forEach { server.sendControl($0.encode(appKey: key)) }
            return
        }
        guard let app = app(for: key) else {
            server.sendControl(MenuTree.none("\(key) isn't running on \(server.hostName)").encode(appKey: key))
            return
        }
        menuReader.read(pid: app.pid, appName: app.name, menu: menu) { [server] trees in
            trees.forEach { server.sendControl($0.encode(appKey: key)) }
        }
    }

    /// The viewer chose a menu item: bring the window it was chosen for forward (or at least its app),
    /// then press the item through Accessibility. Failures go to the log.
    private func pressMenu(_ m: MenuPress) {
        if m.stream != 0, streams[m.stream]?.appKey == m.appKey { lastInput[m.appKey] = (m.stream, Date()) }
        if let name = syntheticApp(key: m.appKey) {
            switch syntheticMenus.press(appKey: m.appKey, appName: name, m) {
            case "New Window":
                if let app = Self.syntheticApps.firstIndex(where: { $0.key == m.appKey }) { addSyntheticWindow(app: app, why: "File > New Window") }
            case "Open…":
                openSyntheticPanel(appKey: m.appKey, why: "File > Open…")
            default:
                break
            }
            return
        }
        guard let app = app(for: m.appKey) else { Log.info(.menu, "menu: can't choose \(m.describe): \(m.appKey) isn't running"); return }
        let st = streams[m.stream].flatMap { $0.pid == app.pid && !$0.closed ? $0 : nil }
        let what = "\(m.describe) in \(app.name)" + (st.map { " (for stream #\($0.id))" } ?? "")
        let press = { [menuReader] in
            menuReader.press(pid: app.pid, path: m.path) { err in
                Log.info(.menu, err.map { "menu: couldn't choose \(what): \($0)" } ?? "menu: chose \(what)")
            }
        }
        if let st { injector.bringToFront(st.target, then: press) } else { injector.activate(pid: app.pid, then: press) }
    }

    /// Stream `s`; 0 means the primary stream (what `wisp poke` addresses by default).
    private func stream(_ s: UInt16) -> HostStream? { s == 0 ? primary : streams[s] }

    func start() throws {
        try server.start()
        server.onViewerReady = { [weak self] in
            DispatchQueue.main.async {
                self?.lastStatus = "-"; self?.checkSession() // resend current status
                if let self, let cb = self.clipboard { cb.connected(peerSupports: self.server.viewerSyncsClipboard) }
            }
        }
        sessionTimer = every(2) { [weak self] in self?.checkSession() }
        panelTimer = every(Self.panelInterval) { [weak self] in self?.panelTick() }
        // Back off fast when the viewer has to re-request packets, creep back up while clean; split
        // what's left between the windows that are changing.
        rateTimer = every(0.5) { [weak self] in
            guard let self else { return }
            let lost = server.lossSignal.take()
            let old = rateScale
            if lost >= 3 { rateScale = max(0.15, rateScale * 0.7) } else if lost == 0 { rateScale = min(1, rateScale + 0.05) }
            if abs(rateScale - old) > 0.001 {
                server.setPace(mbps: max(8, opts.paceMbps * rateScale))
                if rateScale < old {
                    Log.info(.encode, String(format: "loss: %d packets re-requested, backing off to %.1f Mbps video / %.0f Mbps pacing",
                               lost, Double(opts.kbps) * rateScale / 1000, max(8, opts.paceMbps * rateScale)))
                }
            }
            allocateBitrate()
        }
        // Traffic every 5 s (skipped when nothing moved): this is what tells us how little we send.
        statsTimer = every(5) { [server, injector] in
            let bytes = server.bytesOut.take(), frames = server.framesOut.take(), keys = server.keyframesOut.take()
            let resent = server.resent.take(), inBytes = server.bytesIn.take(), events = injector.events.take()
            let perStream = server.takeStreamFrames()
            guard bytes + inBytes > 0 else { return }
            let encUs = Encoder.encodeMicros.take(), encN = Encoder.encodedFrames.take()
            let skipped = Encoder.skipped.take()
            let enc = (encN > 0 ? String(format: ", encode %.1f ms avg", Double(encUs) / Double(encN) / 1000) : "")
                + (skipped > 0 ? ", \(skipped) skipped (encoder busy)" : "")
            let pace = server.pacingDelay.take()
            let paced = pace.count > 0 ? ", pacing \(ms(pace.p50))/\(ms(pace.p95)) ms" : ""
            let split = perStream.count > 1 ? " | frames per stream: " + perStream.sorted { $0.key < $1.key }.map { "#\($0.key) \($0.value)" }.joined(separator: ", ") : ""
            log("video out \(kbps(bytes, over: 5)) (\(frames) frames, \(keys) key, \(resent) pkts resent\(enc)\(paced)) | input in \(kbps(inBytes, over: 5)) (\(events) events)\(split)")
        }
    }

    /// The bitrate budget (--kbps, scaled down while backing off from loss) is split evenly between the
    /// open streams whose window changed in the last second. Idle windows send nothing, so they cost
    /// nothing; each is set to the share it would get if it started changing now.
    private func allocateBitrate() {
        let now = nowMicros()
        let open = streams.values.filter(\.subscribed)
        let active = open.filter { let t = $0.pipeline.lastChange; return t > 0 && now >= t && now - t < 1_000_000 }
        let budget = Double(opts.kbps) * rateScale
        let share = Int(budget / Double(max(1, active.count)))
        let idle = Int(budget / Double(active.count + 1))
        for s in open { s.pipeline.setBitrate(kbps: active.contains { $0 === s } ? share : idle) }
        if active.count != activeStreams {
            if active.count > 1 || activeStreams > 1 {
                Log.info(.encode, String(format: "bitrate: %d of %d open windows changing, %.1f Mbps each", active.count, open.count, Double(share) / 1000))
            }
            activeStreams = active.count
        }
    }

    /// Stream opens and closes, window switches and virtual display changes run one at a time, in
    /// the order asked. Main queue.
    private func serially(_ work: @escaping @MainActor (Host) async -> Void) {
        let previous = switching
        switching = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Like `serially`, for callers that wait for the result.
    @MainActor
    private func serialized(_ work: @escaping @MainActor (Host) async throws -> Void) async throws {
        let previous = switching
        let task = Task { @MainActor [weak self] () throws in
            await previous?.value
            guard let self else { return }
            try await work(self)
        }
        switching = Task { _ = try? await task.value }
        try await task.value
    }

    // MARK: Streams

    private func newStream(windowID: UInt32) -> HostStream {
        let s = HostStream(id: nextStreamID, windowID: windowID, opts: opts, server: server)
        nextStreamID &+= 1
        if nextStreamID == 0 { nextStreamID = 1 }
        streams[s.id] = s
        return s
    }

    /// The viewer asked for a window (0 = the primary one): reuse its stream if it has one, or start one.
    @MainActor
    private func open(windowID requested: UInt32) async {
        guard let wid = requested == 0 ? primaryWindowID : requested else {
            log("viewer asked for the shared window, but none is chosen yet")
            server.sendControl(message(.streamClosed, stream: 0) { $0.u8(StreamCloseReason.failed.rawValue); $0.u32(requested) })
            return
        }
        if let s = streams.values.first(where: { $0.windowID == wid && !$0.closed }) { announce(s); return }
        guard streams.count < opts.maxStreams else {
            log("viewer asked for window \(wid), but \(streams.count) windows are streamed already (the limit)")
            server.sendControl(message(.streamClosed, stream: 0) { $0.u8(StreamCloseReason.limit.rawValue); $0.u32(requested) })
            return
        }
        do {
            announce(try await startStream(windowID: wid))
        } catch {
            log("could not stream window \(wid): \(error.localizedDescription)")
            server.sendControl(message(.streamClosed, stream: 0) { $0.u8(StreamCloseReason.failed.rawValue); $0.u32(requested) })
            await sendWindowList()
        }
    }

    /// Creates a stream for window `wid` and starts capturing it.
    @MainActor
    private func startStream(windowID wid: UInt32) async throws -> HostStream {
        if isSynthetic {
            guard syntheticWindows.contains(where: { $0.id == wid }) else { throw HostError("there is no synthetic window \(wid)") }
            let s = newStream(windowID: wid)
            startSynthetic(s)
            return s
        }
        // ScreenCaptureKit can be a moment behind (a window just made, or just back from another
        // Space): look again for up to 1.5 s before giving up on a window the viewer saw listed.
        var found = try await Host.windows().first(where: { $0.windowID == wid })
        var tries = 0
        while found == nil, tries < 6 {
            tries += 1
            try? await Task.sleep(nanoseconds: 250_000_000)
            found = try await Host.windows().first(where: { $0.windowID == wid })
        }
        guard let w = found else { throw HostError("window \(wid) is gone") }
        if tries > 0 { log("window \(wid) was listed again after \(tries * 250) ms") }
        let s = newStream(windowID: wid)
        do {
            try await capture(s, window: w)
        } catch {
            await discard(s)
            throw error
        }
        await refreshFilters(pid: s.pid)
        return s
    }

    /// A stream that failed to start: forget it, put its window back and remove its display.
    @MainActor
    private func discard(_ s: HostStream) async {
        streams[s.id] = nil
        s.closed = true
        s.pipeline.stop()
        await s.stopCapture()
        restoreMovedWindow(s)
        await removeDisplays(of: s)
    }

    /// Tells the viewer about stream `s` (its ID, size, title, chrome) and starts sending it.
    private func announce(_ s: HostStream) {
        s.subscribed = true
        s.pipeline.enabled = true
        server.sendControl(message(.streamOpened, stream: s.id) { $0.u32(s.windowID); $0.str(s.appKey); $0.str(s.appName) })
        if let i = s.info {
            server.sendControl(WindowInfo(points: i.points, pixels: i.pixels, title: i.title, requestID: s.resizeAck).encode(stream: s.id))
        }
        server.sendControl(s.chrome.encode(stream: s.id))
        s.pipeline.requestKeyframe()
        allocateBitrate()
        log("stream #\(s.id) open: \(s.title) (\(streams.values.filter(\.subscribed).count) open)")
        windowListChanged()
        startFollowing() // new windows of its app open by themselves
    }

    /// Ends stream `s` on this side. `notify` tells the viewer why (windowGone says so itself).
    @MainActor
    private func close(_ s: HostStream, reason: StreamCloseReason, notify: Bool) async {
        guard !s.closed else { return }
        s.closed = true
        injector.endGestures(s.target)
        streams[s.id] = nil
        s.pipeline.stop()
        server.dropStream(s.id)
        if notify, s.subscribed {
            server.sendControl(message(.streamClosed, stream: s.id) { $0.u8(reason.rawValue); $0.u32(s.windowID) })
        }
        await s.stopCapture()
        if !s.gone { restoreMovedWindow(s) }
        await removeDisplays(of: s)
        log("stream #\(s.id) closed (\(reason.text)): \(s.title)")
        await refreshFilters(pid: s.pid)
        windowListChanged()
        if !heldNew.isEmpty { serially { await $0.openHeldWindows() } }
    }

    /// The viewer closed its window for stream `id`. The primary window keeps being captured (so the
    /// next viewer sees it at once); any other is put back where it was.
    @MainActor
    private func viewerClosed(_ id: UInt16) async {
        guard let s = streams[id] else { return }
        if s.windowID == primaryWindowID {
            s.subscribed = false
            s.pipeline.enabled = false
            injector.endGestures(s.target)
            log("stream #\(s.id): the viewer closed it (\(s.title) stays shared)")
            windowListChanged()
        } else {
            await close(s, reason: .asked, notify: false)
        }
    }

    /// A new viewer (or none): every stream but the primary one ends; the primary one waits to be opened.
    @MainActor
    private func resetStreams() async {
        for s in streams.values {
            if s.windowID == primaryWindowID {
                s.subscribed = false
                s.pipeline.enabled = false
                injector.endGestures(s.target)
            } else {
                await close(s, reason: .asked, notify: false)
            }
        }
        activeStreams = -1
    }

    /// The window of stream `s` was closed on this Mac (or its app quit): tell the viewer, end the stream.
    @MainActor
    private func windowGone(_ s: HostStream) async {
        guard !s.gone, !s.closed else { return }
        s.gone = true
        log("stream #\(s.id): \(s.title) was closed on this Mac")
        if s.subscribed { server.sendControl(message(.windowGone, stream: s.id)) }
        await close(s, reason: .windowGone, notify: false)
        if s.windowID == primaryWindowID { onShareChanged?("\(s.title) (closed — choose another window)") }
    }

    /// Share `window` as the primary window, as chosen by the host operator. Any viewer gets it as a new
    /// window; the previous primary stream ends (its viewer window closes).
    @MainActor
    func share(_ window: SCWindow) async throws {
        try await serialized { try await $0.makePrimary(window) }
    }

    @MainActor
    private func makePrimary(_ window: SCWindow) async throws {
        let old = primary
        let s: HostStream
        if let existing = streams.values.first(where: { $0.windowID == window.windowID && !$0.closed }) {
            s = existing
        } else {
            guard streams.count < opts.maxStreams || old != nil else { throw HostError("\(streams.count) windows are streamed already") }
            s = newStream(windowID: window.windowID)
            do {
                try await capture(s, window: window)
            } catch {
                await discard(s)
                throw error
            }
            await refreshFilters(pid: s.pid)
        }
        primaryWindowID = window.windowID
        if server.hasViewerConnection, !s.subscribed { announce(s) }
        if let old, old !== s { await close(old, reason: .replaced, notify: true) }
        onShareChanged?(s.title)
        windowListChanged()
    }

    /// Captures `window` for stream `s` (again, if it was already): moves it onto the stream's own
    /// virtual display (made now if needed), then captures all of the window's app on that display,
    /// cropped to the window, so its context menus, popovers and sheets come along; the app's other
    /// streamed windows are left out.
    @MainActor
    private func capture(_ s: HostStream, window: SCWindow) async throws {
        var window = window
        // The running follow timer (if this is a recapture) leaves the window alone while it moves.
        s.placing = true
        defer { s.placing = false }
        var content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let app = window.owningApplication else { throw HostError("that window has no owning app") }
        var onOwnDisplay = false
        if let vd = await ensureDisplay(for: s), let placed = await place(window, pid: app.processID, on: vd, for: s) {
            (window, content) = placed
            onOwnDisplay = true
        } else if let vd = s.display {
            // The window didn't make it onto the display: keep the one of ours it's still on, if any,
            // and remove the other (or the unused new one).
            let b = cgBounds(of: window.windowID) ?? window.frame
            let center = CGPoint(x: b.midX, y: b.midY)
            if let old = s.previousDisplay, old !== vd, old.bounds.contains(center) {
                s.display = old
                s.previousDisplay = vd
                onOwnDisplay = true
            } else if s.previousDisplay == nil, !vd.bounds.contains(center) {
                s.display = nil
                s.previousDisplay = vd
            }
        }
        // The window is on its new display (or stays where it is): the old display can go. Removing it
        // can rearrange the others, so look again at where everything is.
        if let old = s.previousDisplay {
            s.previousDisplay = nil
            if old !== s.display {
                await removeDisplay(old, of: s)
                if let c = await Host.shareableContent(for: "after removing a display") {
                    content = c
                    if let w = c.windows.first(where: { $0.windowID == window.windowID }) { window = w }
                }
            }
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let own = onOwnDisplay ? content.displays.first { $0.displayID == s.display?.displayID } : nil
        guard let display = own ?? content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw HostError("no display found for that window")
        }
        let displayID = display.displayID
        let pinned = onOwnDisplay ? s.display : nil

        await s.stopCapture()
        s.awaitingResize = nil

        let filter = self.filter(for: s, app: app, display: display, content: content)
        let scale = opts.scale ?? Double(filter.pointPixelScale)
        let title = "\(app.applicationName) — \(window.title ?? "")"
        s.pid = app.processID
        s.target.pid = app.processID
        s.appKey = Self.appKey(app)
        s.appName = app.applicationName
        s.target.windowID = window.windowID
        s.title = title

        // The capture region is relative to the display's top-left, which is read afresh each time:
        // adding or removing a virtual display can rearrange the others (and on a headless Mac, change
        // which one is main, at the origin), moving every window on them in global coordinates.
        func pixels(_ r: CGRect) -> CGSize { CGSize(width: even(r.width * scale), height: even(r.height * scale)) }
        func region(_ r: CGRect, _ d: CGPoint) -> CGRect { r.offsetBy(dx: -d.x, dy: -d.y) }
        let start = cgBounds(of: window.windowID) ?? window.frame
        let startDisplay = CGDisplayBounds(displayID).origin
        s.current = start
        s.offset = CGPoint(x: start.minX - startDisplay.x, y: start.minY - startDisplay.y)
        s.target.frame = start
        setInfo(s, points: start.size, pixels: pixels(start), title: title)
        refreshChrome(s)

        let cap = WindowCapture()
        cap.onFrame = { [pipeline = s.pipeline] in pipeline.push($0, capturedAt: $1) }
        try await cap.start(filter: filter, region: region(start, startDisplay), pixelSize: pixels(start), fps: opts.fps, queue: s.pipeline.q)
        s.capture = cap
        log("stream #\(s.id): window \(window.windowID): \(title) (\(Int(start.width))x\(Int(start.height)) pt at \(Int(start.minX)),\(Int(start.minY))"
            + " on \(pinned.map { "its virtual display \($0.displayID)" } ?? "display \(displayID)"), scale \(scale))")

        // Follow the window as it moves or resizes. Not while a virtual display is being added or
        // removed (no WindowServer calls on the main thread then), nor while the window is being placed.
        let check = { [weak self, weak s] in
            guard let self, let s, !s.closed, !s.gone, !s.placing, !DisplayGate.busy else { return }
            guard let b = cgBounds(of: s.windowID) else { serially { await $0.windowGone(s) }; return }
            let d = CGDisplayBounds(displayID)
            s.target.frame = b
            // A viewer resize has settled once the bounds show what the app accepted (or it took too long).
            var settled = false
            if let a = s.awaitingResize, sameSize(b.size, a.size) || Date() > a.deadline {
                s.resizeAck = a.id
                s.awaitingResize = nil
                settled = true
            }
            // Pinned: on its own virtual display nothing but us should move the window (a drag that
            // reached the remote title bar once dragged it half off the display). Put it back, at the
            // same place relative to the display (the display itself may have been moved).
            let want = CGPoint(x: d.minX + s.offset.x, y: d.minY + s.offset.y)
            if pinned != nil, s.awaitingResize == nil, b.size == s.current.size,
               abs(b.minX - want.x) > 0.5 || abs(b.minY - want.y) > 0.5,
               d.contains(want), d.contains(b.origin), let ax = s.target.ax() {
                axSetFrame(ax, origin: want, size: nil)
                log("stream #\(s.id): the window was moved on this Mac; putting it back")
                return
            }
            guard b != s.current || settled else { return }
            let resized = b.size != s.current.size
            if b != s.current { cap.update(region: region(b, d.origin), pixelSize: pixels(b)) }
            let offset = CGPoint(x: b.minX - d.minX, y: b.minY - d.minY)
            if pinned != nil, b.origin != s.current.origin, abs(offset.x - s.offset.x) < 0.5, abs(offset.y - s.offset.y) < 0.5 {
                log("stream #\(s.id): its display moved; the window is now at \(Int(b.minX)),\(Int(b.minY))")
            }
            s.current = b
            s.offset = offset
            if resized || settled { setInfo(s, points: b.size, pixels: pixels(b), title: s.title) }
            if resized {
                log("stream #\(s.id): window resized to \(Int(b.width))x\(Int(b.height)) pt")
                refreshChrome(s)
            }
        }
        s.followCheck = check
        s.follow = every(0.2, check)
    }

    /// What stream `s` captures: the windows of its app and of the processes working for it (its
    /// out-of-process panels: the Open/Save panel service, Quick Look; see Panels.swift) on its display,
    /// less the app's other streamed windows.
    private func filter(for s: HostStream, app: SCRunningApplication, display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let except = otherStreamedWindows(of: app.processID, than: s)
        let pid = app.processID
        let helpers = content.applications.filter { $0.processID != pid && responsiblePID(of: $0.processID) == pid }
        let ids = Set(helpers.map(\.processID))
        if ids != s.filterHelpers {
            let added = helpers.filter { !s.filterHelpers.contains($0.processID) }
            if !added.isEmpty {
                Log.info(.capture, "stream #\(s.id): capturing \(app.applicationName) with \(added.map { "\($0.applicationName) (pid \($0.processID))" }.joined(separator: ", "))")
            }
            s.filterHelpers = ids
        }
        return SCContentFilter(display: display, including: [app] + helpers, exceptingWindows: content.windows.filter { except.contains($0.windowID) })
    }

    /// The windows of app `pid` that other streams show: left out of this stream's capture, so two
    /// streamed windows of one app never show up inside each other.
    private func otherStreamedWindows(of pid: pid_t, than s: HostStream) -> Set<UInt32> {
        Set(streams.values.filter { $0 !== s && $0.pid == pid && !$0.closed }.map(\.windowID))
    }

    /// After a stream of app `pid` opened or closed, its other streams' captures leave out the right windows.
    @MainActor
    private func refreshFilters(pid: pid_t) async {
        let same = streams.values.filter { $0.pid == pid && $0.capture != nil && !$0.closed }
        guard !same.isEmpty, let content = await Host.shareableContent(for: "refreshing capture filters") else { return }
        for s in same {
            guard let w = content.windows.first(where: { $0.windowID == s.windowID }), let app = w.owningApplication else { continue }
            let center = CGPoint(x: s.current.midX, y: s.current.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) else { continue }
            s.capture?.update(filter: filter(for: s, app: app, display: display, content: content))
        }
    }

    // MARK: Window info and chrome

    /// Sets (and sends, if the viewer has it open) stream `s`'s size and title, stamped with its resize acknowledgement.
    private func setInfo(_ s: HostStream, points: CGSize, pixels: CGSize, title: String) {
        s.info = (points, pixels, title)
        guard s.subscribed else { return }
        server.sendControl(WindowInfo(points: points, pixels: pixels, title: title, requestID: s.resizeAck).encode(stream: s.id))
    }

    /// Settles resize request `id`: the viewer learns the size it led to (possibly unchanged or clamped).
    private func acknowledgeResize(_ s: HostStream, _ id: UInt32) {
        s.resizeAck = id
        s.awaitingResize = nil
        if let i = s.info { setInfo(s, points: i.points, pixels: i.pixels, title: i.title) }
    }

    /// Sends stream `s`'s chrome to the viewer when it changed.
    private func setChrome(_ s: HostStream, _ c: WindowChrome) {
        // Keep the last good reading over a failed or empty one: Zed sometimes reports its traffic
        // lights with zero size, and AX can fail for a moment; either made the viewer hide its own
        // buttons and show macOS's sharing badge instead. (A window that really has no buttons keeps
        // whatever it first reported.)
        let empty = !c.isKnown || (c.close == .zero && c.minimize == .zero && c.zoom == .zero)
        if empty, s.chrome.isKnown, s.chrome.close != .zero { return }
        guard c != s.chrome else { return }
        s.chrome = c
        if s.subscribed { server.sendControl(c.encode(stream: s.id)) }
        log(c.isKnown
            ? "stream #\(s.id) chrome: title bar \(c.titleBarHeight) pt, buttons at \(Int(c.close.minX)),\(Int(c.close.minY)) / \(Int(c.minimize.minX)) / \(Int(c.zoom.minX))"
            : "stream #\(s.id) chrome: unknown (no Accessibility access to the window)")
    }

    /// Re-reads the chrome now and once more shortly after, since apps relayout their title bar
    /// (e.g. entering or leaving full screen) a little after the frame changes.
    private func refreshChrome(_ s: HostStream) {
        setChrome(s, s.target.readChrome())
        s.chromeRecheck?.cancel()
        let work = DispatchWorkItem { [weak self, weak s] in
            DispatchQueue.main.async {
                DisplayGate.whenIdle { [weak self, weak s] in guard let self, let s, !s.closed else { return }; setChrome(s, s.target.readChrome()) }
            }
        }
        s.chromeRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Resizing from the viewer

    /// The viewer resized its window for stream `s`: give the window that size, keeping its top-left corner
    /// (moved left/up only if it would run off its display). The app may clamp it; windowInfo then
    /// reports the real size, stamped with `id` so the viewer can tell it from a change made here.
    private func resize(_ s: HostStream, to requested: CGSize, id: UInt32) {
        if s.synthetic != nil { resizeSynthetic(s, to: requested, id: id); return }
        guard let cur = cgBounds(of: s.windowID) else { acknowledgeResize(s, id); return }
        let area = displayArea(containing: cur)
        var size = requested
        if let area { size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height)) }
        // Ignore a request for the size the window already has (or is already on its way to).
        let effective = s.awaitingResize?.size ?? cur.size
        if sameSize(size, effective) {
            if s.awaitingResize != nil { s.awaitingResize?.id = id } else { acknowledgeResize(s, id) }
            return
        }
        var origin = cur.origin
        if let area {
            if origin.x + size.width > area.maxX { origin.x = max(area.minX, area.maxX - size.width) }
            if origin.y + size.height > area.maxY { origin.y = max(area.minY, area.maxY - size.height) }
        }
        guard let ax = s.target.ax() else {
            log("viewer asked for \(Int(size.width))x\(Int(size.height)) pt for stream #\(s.id), but the window isn't reachable through Accessibility")
            acknowledgeResize(s, id)
            return
        }
        if origin == cur.origin {
            var sz = size
            if let v = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v) }
        } else {
            axSetFrame(ax, origin: origin, size: size)
        }
        // What the app accepted (it may clamp to its minimum or maximum size).
        let got = axFrame(of: ax)?.size ?? size
        if !sameSize(got, size) {
            log("viewer asked for \(Int(size.width))x\(Int(size.height)) pt for stream #\(s.id); the app keeps it at \(Int(got.width))x\(Int(got.height))")
        }
        s.awaitingResize = (id, got, Date().addingTimeInterval(0.5))
        // Pick up the new bounds quickly instead of waiting for the next 0.2 s poll.
        s.followCheck?()
        for t in [0.03, 0.08, 0.15, 0.3, 0.55] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak s] in s?.followCheck?() }
        }
    }

    /// The usable part of the display the window is on: a stream's virtual display, or the real one under its top-left.
    private func displayArea(containing r: CGRect) -> CGRect? {
        let p = CGPoint(x: r.minX + 1, y: r.minY + 1)
        if let vd = streams.values.compactMap(\.display).first(where: { $0.bounds.contains(p) }) { return vd.usableBounds }
        var id: CGDirectDisplayID = 0, n: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &n) == .success, n > 0 else { return nil }
        return CGDisplayBounds(id)
    }

    /// A synthetic window takes any size from 400x300 pt (its fake minimum, so clamping can be tried) to 4000x4000.
    private func resizeSynthetic(_ s: HostStream, to requested: CGSize, id: UInt32) {
        let pts = CGSize(width: min(max(requested.width.rounded(), 400), 4000), height: min(max(requested.height.rounded(), 300), 4000))
        let px = CGSize(width: pts.width * 2, height: pts.height * 2)
        if let i = syntheticWindows.firstIndex(where: { $0.id == s.windowID }), px != syntheticWindows[i].size {
            syntheticWindows[i].size = px
            s.synthetic?.resize(to: px)
            s.target.frame.size = pts
            Self.inputLog?.write(["src": "synthetic", "win": Int(s.windowID), "ev": "resize", "w": Int(pts.width), "h": Int(pts.height)])
            log("synthetic stream #\(s.id) resized to \(Int(pts.width))x\(Int(pts.height)) pt"
                + (sameSize(pts, requested) ? "" : " (asked for \(Int(requested.width))x\(Int(requested.height)))"))
        }
        s.resizeAck = id
        s.awaitingResize = nil
        setInfo(s, points: pts, pixels: px, title: s.title)
    }

    // MARK: Virtual displays
    //
    // Each streamed window gets a HiDPI virtual display of its own, the size of the viewer's screen,
    // made when its stream opens (once the viewer's screen size is known) and removed when the stream
    // closes. They sit side by side, to the right of the real displays, so streamed windows never
    // overlap: hover reaches the right window without raising it, and each window can be as large as
    // the viewer's screen. Displays are made and removed strictly one at a time (everything here runs
    // in the `serially` chain, and VirtualDisplay does the work on one queue), with DisplayGate holding
    // back main-thread WindowServer calls meanwhile.

    /// The viewer told us its screen size: give each streamed window a display of that size, one
    /// window at a time (new display, move the window across, remove the old display).
    @MainActor
    private func viewerScreenChanged(_ points: CGSize) async {
        viewerPoints = points
        guard opts.virtualDisplay, !isSynthetic else { return }
        let size = VirtualDisplay.normalized(points)
        for s in streams.values.sorted(by: { $0.id < $1.id }) where s.synthetic == nil && !s.closed {
            if let d = s.display, d.points == size { continue }
            if s.display == nil, vdisplayFailed { continue }
            guard let w = await Host.windows(for: "moving to a resized display")?.first(where: { $0.windowID == s.windowID }) else {
                Log.info(.vdisplay, "stream #\(s.id): window \(s.windowID) isn't listed, so it isn't moved to a \(Int(size.width))x\(Int(size.height)) pt display")
                continue
            }
            do {
                try await capture(s, window: w) // makes the new display, moves the window, removes the old one
                if s.subscribed { s.pipeline.requestKeyframe() }
            } catch {
                log("stream #\(s.id): could not move it onto a \(Int(size.width))x\(Int(size.height)) pt display: \(error.localizedDescription)")
            }
        }
    }

    /// Captures every stream's window again, where it is now (after its display was removed).
    @MainActor
    private func recaptureAll(reason: String) async {
        guard let windows = await Host.windows(for: reason) else { return }
        for s in streams.values.sorted(by: { $0.id < $1.id }) where s.synthetic == nil && !s.closed {
            guard let w = windows.first(where: { $0.windowID == s.windowID }) else { continue }
            do {
                try await capture(s, window: w)
                if s.subscribed { s.pipeline.requestKeyframe() }
            } catch {
                log("stream #\(s.id): could not \(reason): \(error.localizedDescription)")
            }
        }
    }

    /// Stream `s`'s own virtual display, made now if it has none yet or the viewer's screen size has
    /// changed (the one it replaces is kept in `previousDisplay` until the window has moved).
    /// Otherwise its current display, or nil: not wanted, not possible, or no viewer size yet, so the
    /// window is shared from where it is.
    @MainActor
    private func ensureDisplay(for s: HostStream) async -> VirtualDisplay? {
        guard opts.virtualDisplay, !isSynthetic, let pts = viewerPoints else { return s.display }
        if let d = s.display, d.points == VirtualDisplay.normalized(pts) { return d }
        guard !vdisplayFailed else { return s.display }
        let others = streams.values.filter { $0 !== s }.reduce(0) { $0 + ($1.display == nil ? 0 : 1) }
        guard others < opts.maxStreams else { Log.info(.vdisplay, "stream #\(s.id): \(others) virtual displays already, so no new one"); return s.display }
        let t0 = Date()
        Log.info(.vdisplay, "stream #\(s.id): creating a \(Int(pts.width))x\(Int(pts.height)) pt virtual display (\(others) others)")
        do {
            let vd = try await DisplayGate.during { try await VirtualDisplay.create(points: pts) }
            let b = vd.bounds
            Log.info(.vdisplay, "stream #\(s.id): virtual display \(vd.displayID) created in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(Int(vd.points.width))x\(Int(vd.points.height)) pt @2x at \(Int(b.minX)),\(Int(b.minY))"
                + " (\(vd.modeDescription))\(CGMainDisplayID() == vd.displayID ? ", main display" : "")")
            if let old = s.display { s.previousDisplay = old }
            s.display = vd
            return vd
        } catch {
            vdisplayFailed = true
            Log.error(.vdisplay, "virtual display unavailable after \(Int(Date().timeIntervalSince(t0) * 1000)) ms, so windows are shared from their own display from now on: \(Log.describe(error))")
            return s.display
        }
    }

    /// Removes one of stream `s`'s displays (macOS moves anything still on it to another display).
    @MainActor
    private func removeDisplay(_ vd: VirtualDisplay, of s: HostStream) async {
        if s.display === vd { s.display = nil }
        if s.previousDisplay === vd { s.previousDisplay = nil }
        let t0 = Date()
        do { try await DisplayGate.during { await vd.destroy() } } catch { Log.failed(.vdisplay, "stream #\(s.id): removing virtual display \(vd.displayID)", error) }
        let main = CGMainDisplayID()
        let mainIsOurs = streams.values.contains { $0.display?.displayID == main }
        Log.info(.vdisplay, "stream #\(s.id): virtual display \(vd.displayID) removed in \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
            + (mainIsOurs ? "; virtual display \(main) is the main display now (no other display is left: headless)" : ""))
    }

    /// Removes all of stream `s`'s displays (after its window was put back).
    @MainActor
    private func removeDisplays(of s: HostStream) async {
        for vd in [s.previousDisplay, s.display].compactMap({ $0 }) { await removeDisplay(vd, of: s) }
    }

    /// Moves `window` to the top-left of the usable part of its stream's display with Accessibility
    /// (shrunk only if it doesn't fit), then waits for ScreenCaptureKit to see it there. Returns the
    /// window and content as now listed, or nil to carry on where it is.
    @MainActor
    private func place(_ window: SCWindow, pid: pid_t, on vd: VirtualDisplay, for s: HostStream) async -> (SCWindow, SCShareableContent)? {
        let id = window.windowID
        let start = cgBounds(of: id) ?? window.frame
        let area = vd.usableBounds
        if !area.insetBy(dx: -1, dy: -1).contains(start) {
            guard let ax = axWindow(pid: pid, frame: start) else {
                log("could not find window \(id) through Accessibility, so it stays on its display (is Accessibility allowed?)")
                return nil
            }
            let fits = start.width <= area.width && start.height <= area.height
            let size = fits ? nil : CGSize(width: min(start.width, area.width), height: min(start.height, area.height))
            if !axSetFrame(ax, origin: area.origin, size: size) {
                Log.info(.vdisplay, "Accessibility refused to move window \(id) onto virtual display \(vd.displayID)")
            }
            if s.moved == nil { s.moved = start }
        }
        // Wait until ScreenCaptureKit lists the display and the window on it.
        for _ in 0 ..< 30 {
            if let content = await Host.shareableContent(for: "waiting for a window to reach its display"),
               let d = content.displays.first(where: { $0.displayID == vd.displayID }),
               let w = content.windows.first(where: { $0.windowID == id }),
               d.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) {
                if start != w.frame {
                    let title = "\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")"
                    Log.info(.vdisplay, "stream #\(s.id): moved \(title) onto virtual display \(vd.displayID) (\(Int(w.frame.width))x\(Int(w.frame.height)) pt at \(Int(w.frame.minX)),\(Int(w.frame.minY)))")
                }
                return (w, content)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Log.info(.vdisplay, "window \(id) did not show up on virtual display \(vd.displayID) within 3 s, so it is shared from where it is")
        return nil
    }

    /// Puts stream `s`'s window back where it was before we moved it.
    private func restoreMovedWindow(_ s: HostStream) {
        guard let original = s.moved else { return }
        s.moved = nil
        guard let now = cgBounds(of: s.windowID), let ax = axWindow(pid: s.pid, frame: now) else { return }
        axSetFrame(ax, origin: original.origin, size: now.size == original.size ? nil : original.size)
    }

    // MARK: Virtual display teardown
    //
    // On a headless host a virtual display becomes the main display for every session, so none outlives
    // the viewer by long: a non-primary stream's display goes with its stream (which ends when the viewer
    // leaves), and 30 s after the last viewer leaves the primary window goes back where it was and its
    // display is removed too. A viewer that connects later gets new ones (from its viewerScreen).

    private func scheduleTeardown() {
        teardown?.cancel()
        teardown = nil
        guard hasVirtualDisplays else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.serially { await $0.removeVirtualDisplaysIfIdle() }
        }
        teardown = work
        Log.info(.vdisplay, "no viewer: removing the virtual displays in \(Int(Self.teardownDelay)) s unless one connects")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.teardownDelay, execute: work)
    }

    private func cancelTeardown() {
        guard let t = teardown else { return }
        t.cancel()
        teardown = nil
        if hasVirtualDisplays { Log.info(.vdisplay, "viewer back: keeping the virtual displays") }
    }

    @MainActor
    private func removeVirtualDisplaysIfIdle() async {
        teardown = nil
        guard !server.hasViewerConnection, hasVirtualDisplays else { return }
        viewerPoints = nil // the next viewer's screen size makes new ones
        Log.info(.vdisplay, "no viewer for \(Int(Self.teardownDelay)) s: moving the shared windows back and removing their virtual displays")
        for s in streams.values.sorted(by: { $0.id < $1.id }) where s.display != nil || s.previousDisplay != nil {
            restoreMovedWindow(s)
            await removeDisplays(of: s)
        }
        // Keep capturing the primary window where it is now, so the next viewer sees it at once.
        await recaptureAll(reason: "be captured again after removing its virtual display")
    }

    /// Stops sharing without quitting (the host window closed): stops listening, drops the viewer, ends
    /// every stream (each window goes back where it was and its virtual display is removed, one at a
    /// time on the display lifecycle queue, as when a viewer closes a window). A new Host can start after.
    @MainActor
    func shutdown() async {
        for t in [statsTimer, rateTimer, sessionTimer, panelTimer] { t?.cancel() }
        teardown?.cancel()
        teardown = nil
        server.stop()
        do {
            try await serialized { h in
                for s in h.streams.values.sorted(by: { $0.id < $1.id }) { await h.close(s, reason: .asked, notify: false) }
                h.primaryWindowID = nil
            }
        } catch { Log.failed(.host, "closing the streams while stopping", error) }
        Log.info(.host, "stopped sharing")
    }

    /// Stops sharing for good: puts the moved windows back and removes the virtual displays.
    func stop() {
        teardown?.cancel()
        clipboard?.disconnected()
        for s in streams.values {
            s.follow?.cancel()
            restoreMovedWindow(s)
        }
        for s in streams.values {
            for vd in [s.previousDisplay, s.display].compactMap({ $0 }) {
                vd.destroyBeforeExit()
                Log.info(.vdisplay, "virtual display \(vd.displayID) removed")
            }
            s.display = nil
            s.previousDisplay = nil
        }
    }

    /// While a viewer is connected, keep this Mac's session from idling into the screen lock, and tell
    /// the viewer if it is locked anyway (all input then goes to the lock screen).
    private func checkSession() {
        guard !DisplayGate.busy else { return } // CGSessionCopyCurrentDictionary asks WindowServer
        if server.hasViewerConnection, Date().timeIntervalSince(lastActivity) > 20 {
            lastActivity = Date()
            IOPMAssertionDeclareUserActivity("wisp viewer connected" as CFString, kIOPMUserActiveLocal, &activityID)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        screenLocked = locked
        let status = locked ? "\(Foundation.Host.current().localizedName ?? "The host")'s screen is locked — unlock it to control the window" : ""
        guard status != lastStatus else { return }
        if lastStatus != "-" || !status.isEmpty { log(status.isEmpty ? "screen unlocked" : "screen is locked: input goes to the lock screen") }
        lastStatus = status
        server.sendControl(message(.hostStatus) { $0.str(status) })
    }

    // MARK: Synthetic windows

    /// WISP_INPUT_LOG=<file>: the synthetic host appends what its windows receive (InputRecord lines),
    /// as WispProbe.app does on a real host, for `wisp e2e`.
    static let inputLog: InputLog? = ProcessInfo.processInfo.environment["WISP_INPUT_LOG"].map { InputLog(path: $0) }

    /// Test patterns instead of real windows; input is logged, not injected. Three test windows of
    /// different sizes, each with its own animation, can be streamed at once without any permissions.
    func shareSynthetic(size: CGSize) {
        injector.dryRun = true
        if let log = Self.inputLog {
            // What an app would receive: the events the injector builds, as NSEvents.
            injector.sink = { e, t in
                guard let ns = NSEvent(cgEvent: e) else { return }
                let p = CGPoint(x: e.location.x - t.frame.minX, y: e.location.y - t.frame.minY)
                if let r = InputRecord.make(ns, src: "synthetic", win: t.windowID, at: p) { log.write(r) }
            }
            injector.onRaise = { t, why in log.write(["src": "synthetic", "win": Int(t.windowID), "ev": "raise", "why": why]) }
            Log.info(.input, "synthetic: recording the input its windows receive to \(log.path)")
        }
        isSynthetic = true
        syntheticBase = size
        syntheticWindows = [(1, size, 0), (2, CGSize(width: even(size.width * 0.75), height: even(size.height * 0.75)), 0),
                            (3, CGSize(width: even(size.width * 0.5), height: even(size.height * 0.6)), 1)]
        nextSyntheticID = 4
        primaryWindowID = 1
        let s = newStream(windowID: 1)
        startSynthetic(s)
        onShareChanged?(s.title)
    }

    private func startSynthetic(_ s: HostStream) {
        guard let w = syntheticWindows.first(where: { $0.id == s.windowID }) else { return }
        let title = "wisp synthetic test \(w.id)"
        s.title = title
        let app = Self.syntheticApps[w.app]
        s.appKey = app.key
        s.appName = app.name
        setInfo(s, points: CGSize(width: w.size.width / 2, height: w.size.height / 2), pixels: w.size, title: title)
        s.target.frame = CGRect(x: 0, y: 0, width: w.size.width / 2, height: w.size.height / 2) // injected points are window-relative
        setChrome(s, SyntheticSource.chrome)
        let src = SyntheticSource(size: w.size, label: title, chrome: SyntheticSource.chrome, style: Int(w.id) - 1)
        src.onFrame = { [pipeline = s.pipeline] in pipeline.push($0, capturedAt: $1) }
        src.start(fps: opts.fps, queue: s.pipeline.q)
        s.synthetic = src
        log("stream #\(s.id): \(title) (\(Int(w.size.width))x\(Int(w.size.height)) px)")
    }

    /// A click on a synthetic window's red button "closes" it: the viewer is told the window is gone.
    private func syntheticClick(_ s: HostStream, _ p: Data) {
        guard s.synthetic != nil, let w = syntheticWindows.first(where: { $0.id == s.windowID }) else { return }
        var r = Reader(p)
        guard r.u8() == 0, r.u8() != nil, let x = r.u16(), let y = r.u16() else { return }
        let pt = CGPoint(x: Double(x) / 65535 * w.size.width / 2, y: Double(y) / 65535 * w.size.height / 2)
        guard SyntheticSource.chrome.close.insetBy(dx: -2, dy: -2).contains(pt) else { return }
        log("close button clicked on synthetic stream #\(s.id): telling the viewer it's gone")
        serially { await $0.syntheticWindowClosed(s) }
    }

    /// A synthetic window was closed: gone for the viewer, and from the list.
    @MainActor
    private func syntheticWindowClosed(_ s: HostStream) async {
        syntheticWindows.removeAll { $0.id == s.windowID }
        await windowGone(s)
    }

    /// Synthetic app `app` opens a new window (as reopening it or its File > New Window would), a
    /// little smaller than the base size and of the next style.
    private func addSyntheticWindow(app: Int, why: String) {
        let id = nextSyntheticID
        nextSyntheticID += 1
        let k = [0.7, 0.55, 0.62][Int(id) % 3]
        syntheticWindows.append((id, CGSize(width: even(syntheticBase.width * k), height: even(syntheticBase.height * k)), app))
        log("synthetic: \(Self.syntheticApps[app].name) opened window \(id) (\(why))")
        windowListChanged()
        followTick() // notice it now rather than at the next poll
    }

    // MARK: Panels (Panels.swift)

    /// Every 0.25 s: the panels of the streamed apps (real host only). Not while a display is being
    /// added or removed (it lists windows and may move one through Accessibility).
    private func panelTick() {
        guard !isSynthetic, !streams.isEmpty, !DisplayGate.busy else { return }
        let refresh = panels.tick(streams: Array(streams.values)) { [weak self] key in self?.lastInput[key] }
        for pid in refresh { Task { @MainActor [weak self] in await self?.refreshFilters(pid: pid) } }
    }

    /// The synthetic host's stand-in for an out-of-process Open panel: owned by a made-up panel
    /// service, it "appears" where macOS puts a standalone panel (the middle of the main display,
    /// outside the window), is associated with one of the app's streams as a real one is, moved over
    /// that window like a sheet and drawn into its frames. Escape, Return or a click on its Cancel or
    /// Open button closes it; while it's open, other clicks and keys in that window go to it.
    private static let syntheticPanelService = "Synth Panel Service"
    private var nextSyntheticPanelID: UInt32 = 1001
    /// What a synthetic panel won't shrink below (an NSOpenPanel has a minimum size too).
    private static let syntheticPanelMin = CGSize(width: 440, height: 260)

    private func openSyntheticPanel(appKey: String, why: String) {
        let candidates = streams.values.filter { $0.appKey == appKey && $0.synthetic != nil && !$0.closed }
        let appName = Self.syntheticApps.first { $0.key == appKey }?.name ?? appKey
        guard !candidates.isEmpty else { Log.info(.capture, "panel: \(appName) opens a panel (\(why)) but none of its windows is streamed"); return }
        if let s = candidates.first(where: { $0.syntheticPanel != nil }) {
            Log.info(.capture, "panel: \(appName) already shows a panel in stream #\(s.id)")
            return
        }
        let id = nextSyntheticPanelID
        nextSyntheticPanelID += 1
        let owner = "\(Self.syntheticPanelService) (\(appName))"
        // Window-local points: a standalone panel at the main display's centre is right of the window.
        let size = CGSize(width: 560, height: 340)
        let first = candidates.min { $0.id < $1.id }!
        let appeared = CGRect(origin: CGPoint(x: (first.info?.points.width ?? 800) + 200, y: 240), size: size)
        let (s, reason) = PanelTracker.associate(appeared, among: candidates, lastInput: lastInput[appKey])
        let win = CGRect(origin: .zero, size: s.info?.points ?? CGSize(width: 800, height: 500))
        let bar = CGFloat(SyntheticSource.chrome.titleBarHeight)
        let fit = PanelPlacement.fitted(size, in: win, titleBar: bar)
        let got = CGSize(width: max(fit.width, Self.syntheticPanelMin.width), height: max(fit.height, Self.syntheticPanelMin.height))
        let frame = PanelPlacement.frame(size: got, in: win, titleBar: bar)
        Log.info(.capture, "panel: Open panel \(id) of \(owner) appeared at \(PanelTracker.rect(appeared)) in window \(s.windowID)'s coordinates (\(why)); "
                 + "with stream #\(s.id) (\(reason))")
        Log.info(.capture, "panel: moved Open panel \(id) from outside stream #\(s.id)'s window (\(PanelTracker.rect(win))) to \(PanelTracker.rect(frame))"
                 + (PanelPlacement.inside(frame, win) ? "" : ", larger than the window: it overflows"))
        let panel = SyntheticPanel(id: id, frame: frame, title: "Open", owner: owner)
        s.syntheticPanel = panel
        s.target.panels[id] = 0
        s.synthetic?.setPanel(panel)
    }

    private func closeSyntheticPanel(_ s: HostStream, _ how: String) {
        guard let p = s.syntheticPanel else { return }
        s.syntheticPanel = nil
        s.target.panels[p.id] = nil
        s.synthetic?.setPanel(nil)
        Log.info(.capture, "panel: Open panel \(p.id) of \(p.owner) closed after \(String(format: "%.1f", Date().timeIntervalSince(p.since))) s (\(how); stream #\(s.id))")
    }

    /// Input for a synthetic window with a panel open goes to the panel, as it would to an app-modal
    /// panel: true when the panel took it.
    private func syntheticPanelInput(_ s: HostStream, _ t: MsgType, _ p: Data) -> Bool {
        guard let panel = s.syntheticPanel, let pts = s.info?.points else { return false }
        var r = Reader(p)
        switch t {
        case .key:
            guard let code = r.u16(), let down = r.u8() else { return true }
            if down != 0, code == 53 || code == 36 { closeSyntheticPanel(s, code == 53 ? "Escape: Cancel" : "Return: Open") }
            else if down != 0 { log("synthetic input: stream #\(s.id) key went to the panel") }
            return true
        case .mouseDown, .mouseUp:
            guard r.u8() == 0, r.u8() != nil, let x = r.u16(), let y = r.u16() else { return true }
            let pt = CGPoint(x: Double(x) / 65535 * pts.width, y: Double(y) / 65535 * pts.height)
            guard t == .mouseUp else { return true }
            if let button = panel.button(at: pt) { closeSyntheticPanel(s, "clicked \(button)") }
            else if !panel.frame.contains(pt) { log("synthetic input: stream #\(s.id) click outside the panel: ignored, the panel is modal") }
            return true
        default:
            return false
        }
    }

    // MARK: Window list

    private func windowListChanged() {
        if server.wantsWindowList { Task { @MainActor in await sendWindowList() } } // moves the checkmarks
    }

    /// Sends the viewer this Mac's shareable windows, preceded by any app icons it doesn't have yet.
    @MainActor
    func sendWindowList() async {
        var entries: [WindowEntry] = []
        var icons: [String: NSImage] = [:]
        func pt(_ v: Double) -> UInt16 { UInt16(clamping: Int(v.rounded())) }
        let open = Set(streams.values.filter(\.subscribed).map(\.windowID))
        if isSynthetic {
            entries = syntheticWindows.map {
                let app = Self.syntheticApps[$0.app]
                if icons[app.key] == nil { icons[app.key] = Self.syntheticIcon(app.key) }
                return WindowEntry(id: $0.id, appKey: app.key, appName: app.name, title: "synthetic test \($0.id)",
                                   points: (pt($0.size.width / 2), pt($0.size.height / 2)), shared: open.contains($0.id))
            }
        } else {
            let mine = Bundle.main.bundleIdentifier
            guard let windows = await Host.windows(for: "the viewer's window list") else { return }
            for w in windows where !panels.isPanel(w.windowID) { // a panel is shown in its stream, not on its own
                guard let app = w.owningApplication, app.bundleIdentifier != mine else { continue }
                let key = Self.appKey(app)
                if icons[key] == nil { icons[key] = NSRunningApplication(processIdentifier: app.processID)?.icon }
                entries.append(WindowEntry(id: w.windowID, appKey: key, appName: app.applicationName, title: w.title ?? "",
                                           points: (pt(w.frame.width), pt(w.frame.height)), shared: open.contains(w.windowID)))
            }
        }
        for (key, image) in icons where server.needsIcon(key) {
            guard let png = pngIcon(image), png.count < 60000 else { continue }
            server.sendControl(message(.appIcon) { $0.str(key); $0.bytes(png) })
        }
        server.sendControl(WindowEntry.encode(entries))
    }

    static func appKey(_ app: SCRunningApplication) -> String {
        app.bundleIdentifier.isEmpty ? "pid:\(app.processID)" : app.bundleIdentifier
    }

    /// The viewer wants app `key`'s icon at `px` (a phantom app's Dock icon): send it as PNG chunks.
    private func sendLargeIcon(_ key: String, px requested: Int) {
        let px = min(max(requested, 16), 1024)
        let image: NSImage?
        if Self.syntheticApps.contains(where: { $0.key == key }) {
            image = Self.syntheticIcon(key)
        } else if key.hasPrefix("pid:"), let pid = pid_t(key.dropFirst(4)) {
            image = NSRunningApplication(processIdentifier: pid)?.icon
        } else {
            image = NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key).map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        guard let image, let png = pngIcon(image, px: px) else { log("viewer asked for the icon of \(key), which isn't known here"); return }
        let chunk = 60000
        var offset = 0
        while offset < png.count {
            let part = png[png.startIndex + offset ..< png.startIndex + min(png.count, offset + chunk)]
            server.sendControl(message(.appIconLarge) { [offset] w in
                w.str(key); w.u16(UInt16(px)); w.u32(UInt32(png.count)); w.u32(UInt32(offset)); w.bytes(Data(part))
            })
            offset += chunk
        }
        log("sent the \(px) px icon of \(key) (\(png.count / 1024) KB)")
    }

    /// A made-up app icon for a synthetic app: a coloured rounded square with its letter.
    static func syntheticIcon(_ key: String) -> NSImage {
        let app = syntheticApps.first { $0.key == key } ?? syntheticApps[0]
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
            let inset = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.1)
            let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.width * 0.22)
            NSGradient(starting: NSColor(hue: app.hue, saturation: 0.55, brightness: 1, alpha: 1),
                       ending: NSColor(hue: app.hue, saturation: 0.9, brightness: 0.7, alpha: 1))!.draw(in: path, angle: -90)
            let font = NSFont.systemFont(ofSize: inset.height * 0.62, weight: .heavy)
            let text = NSAttributedString(string: app.letter, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2))
            return true
        }
    }

    /// The synthetic host injects nothing; it logs clicks and key presses so a test can see them arrive.
    private func logSyntheticInput(_ s: HostStream, _ t: MsgType, _ p: Data) {
        var r = Reader(p)
        switch t {
        case .mouseDown, .mouseUp:
            guard let b = r.u8(), let n = r.u8(), let x = r.u16(), let y = r.u16() else { return }
            log("synthetic input: stream #\(s.id) (window \(s.windowID)) \(t == .mouseDown ? "mouse down" : "mouse up") button \(b) ×\(n) at "
                + String(format: "%.2f,%.2f", Double(x) / 65535, Double(y) / 65535))
        case .key:
            guard let code = r.u16(), let down = r.u8(), let flags = r.u32() else { return }
            log("synthetic input: stream #\(s.id) (window \(s.windowID)) key \(code) \(down != 0 ? "down" : "up") flags 0x\(String(flags, radix: 16))")
        default:
            break
        }
    }

    // MARK: Permissions

    /// Screen Recording is required to capture; asks once (macOS shows its own prompt).
    static func ensureScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    /// Accessibility is required to inject input; prompts if missing. Without it, viewers can only watch.
    @discardableResult
    static func ensureAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    static func windows() async throws -> [SCWindow] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 80 }
    }

    /// Host.windows(), or nil with the error logged (once per purpose until it changes: some callers
    /// run every second, e.g. without Screen Recording).
    static func windows(for why: String) async -> [SCWindow]? {
        do {
            let w = try await windows()
            clearListError(why)
            return w
        } catch {
            noteListError(why, error)
            return nil
        }
    }

    /// SCShareableContent (on-screen windows), or nil with the error logged as for windows(for:).
    static func shareableContent(for why: String) async -> SCShareableContent? {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            clearListError(why)
            return c
        } catch {
            noteListError(why, error)
            return nil
        }
    }

    nonisolated(unsafe) private static var lastListError: [String: String] = [:] // under listErrorLock
    private static let listErrorLock = NSLock()
    private static func clearListError(_ why: String) {
        listErrorLock.lock(); let had = lastListError.removeValue(forKey: why) != nil; listErrorLock.unlock()
        if had { Log.info(.capture, "listing windows (\(why)) works again") }
    }
    private static func noteListError(_ why: String, _ error: Error) {
        let text = Log.describe(error)
        listErrorLock.lock(); let same = lastListError[why] == text; lastListError[why] = text; listErrorLock.unlock()
        guard !same else { return }
        Log.warning(.capture, "couldn't list windows (\(why)): \(text); Screen Recording \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
    }

    /// Window by ID, or the largest whose app name or title contains `query`.
    static func findWindow(_ query: String, in windows: [SCWindow]) -> SCWindow? {
        windows.first { String($0.windowID) == query }
            ?? windows.filter {
                ($0.owningApplication?.applicationName.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
            }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

/// A small PNG of an app icon for the viewer's menu: 32×32 px, i.e. 16 pt on a Retina screen.
func pngIcon(_ image: NSImage, px: Int = 32) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

struct HostError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// Window sizes from CGWindow and Accessibility agree to within a point.
func sameSize(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1 }

/// Repeating timer on the main queue. Keep the returned timer alive; cancel it to stop.
func every(_ seconds: Double, _ block: @escaping () -> Void) -> DispatchSourceTimer {
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + seconds, repeating: seconds)
    t.setEventHandler(handler: block)
    t.resume()
    return t
}

/// This Mac's Tailscale addresses (100.64.0.0/10), to tell viewers where to connect.
func tailscaleAddresses() -> [String] {
    var out: [String] = []
    var ifs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifs) == 0 else { return [] }
    defer { freeifaddrs(ifs) }
    var p = ifs
    while let i = p {
        defer { p = i.pointee.ifa_next }
        guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        guard addr >> 22 == (100 << 2 | 1) else { continue } // 100.64.0.0/10
        out.append("\(addr >> 24).\(addr >> 16 & 0xff).\(addr >> 8 & 0xff).\(addr & 0xff)")
    }
    return out
}
