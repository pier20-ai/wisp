// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import CoreMedia
import Foundation
import Network
import UniformTypeIdentifiers
import VideoToolbox
import WispCommon

/// A streamed window's size and title (see WindowInfo in Protocol.swift).
typealias RemoteInfo = WindowInfo

/// A window the host could share, with its app's icon (PNG) once the host has sent it.
struct RemoteWindow {
    var entry: WindowEntry
    var icon: Data?
}

/// One connection to a host: one TCP and one UDP flow, shared by all the streams (windows) open on it.
/// Negotiates the protocol version, measures latency, and hands datagrams to their stream.
/// Callbacks run on the main queue, except each stream's decoded images.
final class Client {
    private let q = DispatchQueue(label: "wisp.client")
    private let address: String
    private let tcp: NWConnection
    /// The video flow. Replaced (a new source port) when it fails, or when the host's hello echoes
    /// stop arriving while TCP still answers; on q.
    private var udp: NWConnection
    private let parser = MessageParser()
    let latency = Latency()
    /// A control-only connection (`wisp poke`): the host keeps its viewer; no video, pings or screen size.
    var sideChannel = false
    /// Phantom mode: streams don't decode here; each complete frame goes to its stream's relay (the
    /// phantom app showing it), which decodes it. Set before start().
    var relaysFrames = false
    /// Tell the host it may open streams for new windows of the apps we show (Wire.Feature.followsNewWindows).
    /// Set before start().
    var followsNewWindows = true
    /// Clipboard sync with the host (Wire.Feature.clipboard), made by syncClipboard() before start(). Main queue.
    private(set) var clipboard: ClipboardSync?

    /// Sync the clipboard with the host while connected (if the host can, and both settings are on).
    /// Call before start().
    func syncClipboard(pasteboard: NSPasteboard = ClipboardSync.defaultPasteboard) {
        clipboard = ClipboardSync(side: .viewer, pasteboard: pasteboard) { [weak self] d, done in
            guard let self else { done(); return }
            self.sendControl(d, done: done)
        }
    }

    /// The host answered our hello (its name): streams can be opened now.
    var onReady: ((String) -> Void)?
    var onHostStatus: ((String) -> Void)?
    /// Connection trouble; after a failure nothing more arrives.
    var onDisconnect: ((String) -> Void)?
    var onWindowList: (([RemoteWindow]) -> Void)?
    /// A stream started: one we asked for, or one the host opened by itself (its operator shared another window).
    var onStreamOpened: ((RemoteStream) -> Void)?
    /// A stream ended (stream 0: an openStream for that window ID failed).
    var onStreamClosed: ((UInt16, UInt32, StreamCloseReason) -> Void)?
    /// A large app icon arrived (appKey, px, PNG), answering requestIcon.
    var onLargeIcon: ((String, Int, Data) -> Void)?
    /// An app's menu bar, or one of its menus (appKey, the whole menuTree message as the host sent it).
    var onMenuTree: ((String, Data) -> Void)?
    /// An app we show opened a new window the host can't stream (its limit): windowID, appKey, appName, open, max.
    var onNewWindowHeld: ((UInt32, String, String, Int, Int) -> Void)?
    /// The screen whose size the host should match (called on the main queue). The viewer sets this to
    /// its windows' screen; the default is the main screen.
    var screen: () -> NSScreen? = { NSScreen.main }
    private var screenObserver: NSObjectProtocol?
    private var lastScreen: Data? // only touched on q
    private var icons: [String: Data] = [:] // appKey -> PNG, only touched on q
    private var largeIcons: [String: (px: Int, total: Int, data: Data)] = [:] // being received, on q
    let bytesDown = Counter(), bytesUp = Counter()
    /// Last 5 s per-stage breakdown (p50/p95 ms), for the CLI.
    private(set) var lastBreakdown = ""

    // Only touched on q.
    private var ready = false
    private var failed = false
    private var session: UInt32 = 0
    private var held: [Data] = [] // messages waiting for helloAck
    private var streams: [UInt16: RemoteStream] = [:]
    private var timers: [DispatchSourceTimer] = []
    private var started = Date()
    private var windowLists = 0
    private let dropPercent = Double(ProcessInfo.processInfo.environment["WISP_DROP"] ?? "") ?? 0
    /// WISP_NET_DELAY_MS / _JITTER_MS / _LOSS: a far-away host, emulated (NetEmu.swift). On q.
    private lazy var netEmu = NetEmu(queue: q)

    // The video path's health, on q (see checkVideoPath).
    private var lastUDPAt = Date.distantPast    // any datagram from the host
    private var lastEchoAt: Date?               // the host's answer to our UDP hello (nil: an older host, or none yet)
    private var lastPongAt = Date.distantPast
    private var lastHelloSentAt = Date.distantPast
    private var udpFlows = 1, lastUDPRebuild = Date.distantPast
    private var udpDatagrams = 0
    private lazy var videoPath = StallEpisode("video path from \(address)", .net)
    private var helloTimer: DispatchSourceTimer?
    private var helloDatagram = Data()
    /// Fault `udp-drop-all-for=<s>`: drop every incoming datagram for that long, from 4 s after the session starts.
    private let faultDropFor = Fault.number("udp-drop-all-for", default: 5)
    private var faultDrop: (from: Date, until: Date)?
    private var faultDropping = false

    init(host: String) {
        address = host
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        tcp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.tcpPort)!,
                           using: NWParameters(tls: nil, tcp: tcpOpts))
        udp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Wire.udpPort)!, using: .udp)
    }

    private var elapsed: String { String(format: "%.1f s", Date().timeIntervalSince(started)) }
    private var kind: String { sideChannel ? "side channel" : "viewer" }

    func start() {
        started = Date()
        Log.info(.viewer, "connecting to \(describeAddress(address)) as a \(kind): TCP \(Wire.tcpPort), then UDP \(Wire.udpPort); protocol \(Wire.protocolVersion)")
        tcp.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready, .waiting, .failed:
                Log.info(.net, "TCP \(address):\(Wire.tcpPort) \(st.logDescription) after \(elapsed); path: \(tcp.currentPath?.logDescription ?? "none")")
            default:
                Log.debug(.net, "TCP \(address):\(Wire.tcpPort) \(st.logDescription) after \(elapsed)")
            }
            switch st {
            case .ready:
                if sideChannel {
                    send(message(.sideChannel) { $0.u16(Wire.protocolVersion) })
                } else {
                    var hello = Hello(name: Foundation.Host.current().localizedName ?? "viewer")
                    if followsNewWindows { hello.features |= Wire.Feature.followsNewWindows }
                    if clipboard != nil { hello.features |= Wire.Feature.clipboard }
                    Log.info(.viewer, "→ hello: protocol \(hello.version), features \(Wire.Feature.describe(hello.features)), name \"\(hello.name)\"")
                    send(hello.encode())
                    lastScreen = nil
                    sendScreen()
                }
                // The host checks who we are with Tailscale first (whois), which can take a moment.
                q.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, !ready, !failed else { return }
                    Log.warning(.viewer, "no helloAck from \(address) 6 s after TCP connected")
                    fail("\(address) didn't answer: is \(Brand.name) running there, and as new as this Mac's (protocol \(Wire.protocolVersion))?")
                }
            case .failed(let e): fail("connection failed: \(e)")
            case .waiting(let e): main { $0.onDisconnect?("waiting: \(e)") }
            default: break
            }
        }
        tcp.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Log.debug(.net, "TCP \(address) path: \(path.logDescription)")
        }
        var wasViable = true // on q
        tcp.viabilityUpdateHandler = { [weak self] viable in
            guard let self, viable != wasViable else { return }
            wasViable = viable
            Log.info(.net, "TCP \(address) \(viable ? "viable again" : "not viable (no route at the moment)") after \(elapsed)")
        }
        tcp.betterPathUpdateHandler = { [weak self] better in
            guard let self, better else { return }
            Log.info(.net, "TCP \(address): a better path is available (\(tcp.currentPath?.logDescription ?? "?"))")
        }
        // Network.framework can sit in "preparing" (a name being resolved, a SYN unanswered) without a
        // word: say so, so a stuck "Connecting…" has an explanation in the log.
        for t in [3.0, 8.0, 14.0] {
            q.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, !ready, !failed else { return }
                Log.info(.net, "TCP \(address) still \(tcp.state.logDescription) after \(Int(t)) s; path: \(tcp.currentPath?.logDescription ?? "none yet")")
            }
        }
        // Still not connected after 15 s and not "waiting" either (which has its own give-up): e.g. an
        // address with no route, stuck in "preparing". Report it as a failure so the viewer stops.
        q.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !ready, !failed else { return }
            if case .waiting = tcp.state { return }
            Log.warning(.net, "TCP \(address) still \(tcp.state.logDescription) after 15 s: giving up")
            let reason = "no answer from \(address) after 15 s (still \(tcp.state.logDescription))"
            main { $0.onDisconnect?(reason) }
        }
        tcp.start(queue: q)
        receiveTCP()
        guard !sideChannel else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.sendScreen() }
    }

    /// The host said helloAck: open the video path and start measuring.
    private func startSession() {
        startUDP(udp)
        // Hello opens the UDP path through any NAT, binds it to this session, and doubles as a keepalive.
        var w = Writer()
        w.u8(Wire.Datagram.hello.rawValue)
        w.u32(session)
        helloDatagram = w.data
        if let at = faultDropFor { faultDrop = (Date().addingTimeInterval(4), Date().addingTimeInterval(4 + at)) }
        let hello = makeHelloTimer()
        MainThreadWatch.start()
        let ping = DispatchSource.makeTimerSource(queue: q)
        ping.schedule(deadline: .now() + 0.5, repeating: 1.0)
        ping.setEventHandler { [weak self] in guard let self else { return }; self.send(self.latency.nextPing()) }
        ping.resume()
        // Every 5 s, send what we measured back to the host so it can log it.
        let report = DispatchSource.makeTimerSource(queue: q)
        report.schedule(deadline: .now() + 5, repeating: 5.0)
        report.setEventHandler { [weak self] in
            guard let self else { return }
            let stats = latency.report(seconds: 5)
            lastBreakdown = stats.breakdown
            send(stats.encode())
        }
        report.resume()
        let repair = DispatchSource.makeTimerSource(queue: q)
        repair.schedule(deadline: .now(), repeating: 0.03)
        repair.setEventHandler { [weak self] in
            guard let self else { return }
            streams.values.forEach { $0.repair() }
            // The hello timer is the keepalive: if it ever stops, the host loses the video path.
            if Date().timeIntervalSince(lastHelloSentAt) > 3, !failed, helloTimer != nil {
                Log.warning(.net, String(format: "UDP hello not sent for %.1f s: restarting its timer", Date().timeIntervalSince(lastHelloSentAt)))
                helloTimer?.cancel()
                timers.removeAll { [helloTimer] in $0 === helloTimer }
                timers.append(makeHelloTimer())
            }
        }
        repair.resume()
        timers = [hello, ping, report, repair]
    }

    /// Sends the UDP hello every second (opening and keeping the path, and asking for the host's echo)
    /// and checks the video path each time.
    private func makeHelloTimer() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            sendHello()
            checkVideoPath()
        }
        t.resume()
        helloTimer = t
        return t
    }

    private func sendHello() {
        lastHelloSentAt = Date()
        let flow = udp
        udp.send(content: helloDatagram, completion: .contentProcessed { [weak self] err in
            guard let self, let err, !failed else { return }
            Log.debug(.net, "UDP hello on \(flow.state.logDescription) flow failed: \(err.logDescription)")
        })
    }

    private func startUDP(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c else { return }
            switch st {
            case .ready, .waiting, .failed:
                Log.info(.net, "UDP \(address):\(Wire.udpPort) \(st.logDescription); path: \(c.currentPath?.logDescription ?? "none")")
            default:
                Log.debug(.net, "UDP \(address):\(Wire.udpPort) \(st.logDescription)")
            }
            if case .failed = st, c === udp, !failed {
                // It used to stay failed, with no video for the rest of the session.
                q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, c === udp, !failed else { return }
                    rebuildUDP("the UDP flow failed")
                }
            }
        }
        c.start(queue: q)
        receiveUDP(c)
    }

    /// A new UDP flow (a new source port): the host follows the newest hello. On q.
    private func rebuildUDP(_ why: String) {
        let old = udp
        udp = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: Wire.udpPort)!, using: .udp)
        udpFlows += 1
        lastUDPRebuild = Date()
        Log.warning(.net, "UDP \(address): \(why): making a new UDP flow (#\(udpFlows)); the old one was \(old.state.logDescription)")
        old.stateUpdateHandler = nil
        old.cancel()
        startUDP(udp)
        sendHello()
    }

    /// Once a second (on q): is video still able to arrive? Only judged against a host that echoes our
    /// hellos (an older one doesn't, and an idle window sends nothing), and while TCP answers (when it
    /// doesn't, the connection itself is in trouble and says so).
    private func checkVideoPath() {
        guard ready, !failed, let echo = lastEchoAt else { return }
        let now = Date()
        let silent = now.timeIntervalSince(max(lastUDPAt, echo))
        let tcpAlive = now.timeIntervalSince(lastPongAt) < 2.5
        guard silent > 3 else { return }
        if !videoPath.active {
            guard tcpAlive else { return }
            videoPath.begin(String(format: "no UDP from the host for %.1f s (no video, no hello echo) while TCP answers (last pong %.1f s ago); ",
                                   silent, now.timeIntervalSince(lastPongAt))
                + "UDP flow #\(udpFlows) \(udp.state.logDescription), path \(udp.currentPath?.logDescription ?? "none"), "
                + "hello sent \(String(format: "%.1f", now.timeIntervalSince(lastHelloSentAt))) s ago", at: now.addingTimeInterval(-silent))
            sendHello()
            videoPath.act("sent the UDP hello again at once")
        } else if silent > 6, now.timeIntervalSince(lastUDPRebuild) > 6 {
            videoPath.act(String(format: "no UDP for %.0f s: new UDP flow", silent))
            rebuildUDP("no UDP from the host for \(Int(silent)) s")
        }
    }

    private func main(_ f: @escaping (Client) -> Void) { DispatchQueue.main.async { [weak self] in if let self { f(self) } } }
    fileprivate func onQueue(_ f: @escaping () -> Void) { q.async(execute: f) }

    /// Fails for good, once (on q).
    private func fail(_ why: String) {
        guard !failed else { return }
        Log.warning(.viewer, "connection to \(address) ended after \(elapsed)\(ready ? "" : " (before the host answered)"): \(why)")
        failed = true
        timers.forEach { $0.cancel() }
        timers = []
        tcp.cancel()
        udp.cancel()
        let cb = clipboard
        DispatchQueue.main.async { cb?.disconnected() }
        main { $0.onDisconnect?(why) }
    }

    /// Tells the host the size of the viewer's screen (its usable area), so it can give the shared
    /// windows a HiDPI virtual display of that size. Only sent when it changed since last time.
    func sendScreen() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let s = screen() else { return }
            let f = s.visibleFrame
            let msg = message(.viewerScreen) {
                $0.u16(UInt16(clamping: Int(f.width.rounded(.down)))); $0.u16(UInt16(clamping: Int(f.height.rounded(.down))))
                $0.u8(UInt8(clamping: Int(s.backingScaleFactor.rounded())))
            }
            q.async {
                guard msg != self.lastScreen else { return }
                self.lastScreen = msg
                self.send(msg)
            }
        }
    }

    func stop() {
        q.async { [self] in
            if !failed { Log.info(.viewer, "closing the \(kind) connection to \(address) after \(elapsed), \(streams.count) streams open") }
            failed = true
            timers.forEach { $0.cancel() }
            timers = []
            streams = [:]
            tcp.cancel()
            udp.cancel()
        }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let cb = clipboard
        DispatchQueue.main.async { cb?.disconnected() }
        onDisconnect = nil; onWindowList = nil; onHostStatus = nil; onReady = nil
        onStreamOpened = nil; onStreamClosed = nil; onLargeIcon = nil; onMenuTree = nil
    }

    // MARK: Sending

    func send(_ d: Data) {
        bytesUp.add(d.count)
        if let emu = netEmu { emu.sending { [tcp] in tcp.send(content: d, completion: .idempotent) }; return }
        tcp.send(content: d, completion: .idempotent)
    }

    /// Sends `d` once the host has answered our hello (at once if it has). On q.
    private func sendWhenReady(_ d: Data) {
        if ready { send(d) } else { held.append(d) }
    }

    private func flushHeld() {
        let h = held
        held = []
        h.forEach(send)
    }

    /// Input messages go through here so click→screen latency can be matched to that stream's frames.
    func sendInput(_ stream: UInt16, _ d: Data, discrete: Bool = false) {
        q.async { [self] in
            latency.inputSent(stream: stream, discrete: discrete)
            sendWhenReady(d)
        }
    }

    /// Any control message, once the host has answered our hello.
    func sendControl(_ d: Data) { q.async { self.sendWhenReady(d) } }

    /// A control message after the hello exchange (dropped before it, or after the connection ended),
    /// with `done` called once it has left: for bulk data (the clipboard), so it never piles up.
    func sendControl(_ d: Data, done: @escaping () -> Void) {
        q.async { [self] in
            guard ready, !failed else { done(); return }
            bytesUp.add(d.count)
            tcp.send(content: d, completion: .contentProcessed { _ in done() })
        }
    }

    func requestWindowList() { q.async { self.sendWhenReady(message(.windowListRequest)) } }

    /// Ask the host for app `key`'s icon at `px`×`px` (answer: onLargeIcon; an older host never answers).
    func requestIcon(_ key: String, px: Int) {
        q.async { self.sendWhenReady(message(.iconRequest) { $0.str(key); $0.u16(UInt16(px)) }) }
    }

    /// Ask the host to stream window `id` (0 = the window it is sharing). The answer is onStreamOpened
    /// or onStreamClosed(0, id, reason).
    func openStream(windowID id: UInt32) {
        q.async {
            Log.info(.viewer, "→ openStream window \(id == 0 ? "0 (the host's shared window)" : "\(id)")\(self.ready ? "" : " (once the host answers)")")
            self.sendWhenReady(message(.openStream) { $0.u32(id) })
        }
    }

    /// App `key` has no windows here or on the host and its phantom was clicked in the Dock: ask the
    /// host to reopen it, as a Dock click there would (its new window then opens as a stream).
    func reopenApp(_ key: String) {
        q.async {
            Log.info(.viewer, "→ reopenApp \(key)")
            self.sendWhenReady(message(.reopenApp) { $0.str(key) })
        }
    }

    /// Stop receiving stream `id`; the window stays open on the host.
    func closeStream(_ id: UInt16) {
        q.async { [self] in
            guard let s = streams.removeValue(forKey: id) else { return }
            Log.info(.viewer, "→ closeStream #\(id) (window \(s.windowID)); \(streams.count) left")
            send(message(.closeStream, stream: id))
        }
    }

    /// Ask the host to resize stream `stream`'s window to `size` points (see MsgType.resizeWindow).
    func resizeWindow(_ stream: UInt16, _ size: CGSize, id: UInt32) {
        let msg = message(.resizeWindow, stream: stream) {
            $0.u16(UInt16(clamping: max(1, Int(size.width.rounded())))); $0.u16(UInt16(clamping: max(1, Int(size.height.rounded()))))
            $0.u32(id)
        }
        q.async { self.sendWhenReady(msg) }
    }

    /// Close stream `stream`'s window on the host (through Accessibility there).
    func closeRemoteWindow(_ stream: UInt16) {
        Log.info(.viewer, "→ close the window of stream #\(stream) on the host")
        q.async { self.sendWhenReady(message(.windowAction, stream: stream) { $0.u8(1) }) }
    }

    func frameDisplayed(_ t: FrameTiming) { latency.frameDisplayed(t) }

    // MARK: Receiving

    private func receiveTCP() {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data {
                bytesDown.add(data.count)
                if let emu = netEmu { emu.received { [self] in self.parser.feed(data).forEach { self.handle($0.0, $0.1) } } }
                else { parser.feed(data).forEach { self.handle($0.0, $0.1) } }
            }
            if let err { fail("disconnected: \(err.logDescription)"); return }
            if done { fail("disconnected (the host closed the connection)"); return }
            receiveTCP()
        }
    }

    private func handle(_ t: MsgType, _ p: Data) {
        guard !failed else { return }
        if t != .pong, t != .hostClipboardChunk { Log.debug(.viewer, "← \(t) (\(p.count) B)") }
        if !ready {
            switch t {
            case .helloAck:
                guard let h = Hello.decodeAck(p), h.version >= 2 else {
                    Log.error(.viewer, "helloAck from \(address) can't be read or is too old: \(p.count) B, version \(Hello.decodeAck(p).map { "\($0.version)" } ?? "?")")
                    fail("\(address) answered with an unknown protocol"); return
                }
                Log.info(.viewer, "← helloAck after \(elapsed): host \"\(h.name)\", protocol \(h.version) (ours \(Wire.protocolVersion)), features \(Wire.Feature.describe(h.features)), session \(h.session)")
                ready = true
                session = h.session
                if !sideChannel { startSession() }
                flushHeld()
                if let cb = clipboard {
                    let supports = h.features & Wire.Feature.clipboard != 0
                    DispatchQueue.main.async { cb.connected(peerSupports: supports) }
                }
                main { $0.onReady?(h.name) }
            case .refused:
                // The host won't serve us (its allow-list, or we're not on Tailscale): it says why.
                var r = Reader(p)
                let why = r.str() ?? "\(address) refused the connection"
                Log.warning(.viewer, "← refused by \(address): \(why)")
                fail(why)
            case .windowInfo:
                // A protocol-1 host ignores hello and starts with its (v1) windowInfo.
                fail("\(address) runs an older \(Brand.name) (protocol 1). Update \(Brand.name) there to the same version as this Mac (protocol \(Wire.protocolVersion)).")
            default:
                Log.debug(.viewer, "ignored \(t) before helloAck")
            }
            return
        }
        var r = Reader(p)
        if t.isPerStream {
            guard let id = r.u16() else { return }
            switch t {
            case .streamOpened:
                guard let wid = r.u32() else { return }
                let s = streams[id] ?? RemoteStream(id: id, windowID: wid, client: self, relays: relaysFrames)
                s.app = r.str().flatMap { key in r.str().map { (key, $0) } }.flatMap { $0.0.isEmpty ? nil : $0 }
                Log.info(.viewer, "← streamOpened #\(id): window \(wid)\(s.app.map { " of \($0.1) (\($0.0))" } ?? ""); \(streams[id] == nil ? streams.count + 1 : streams.count) open")
                streams[id] = s
                main { $0.onStreamOpened?(s) }
            case .streamClosed:
                let reason = r.u8().flatMap(StreamCloseReason.init) ?? .failed
                let wid = r.u32() ?? 0
                let s = id == 0 ? nil : streams.removeValue(forKey: id)
                Log.info(.viewer, "← streamClosed #\(id) (window \(wid)): \(reason) (\(reason.text)); \(streams.count) open")
                main { s?.closed(); $0.onStreamClosed?(id, wid, reason) }
            case .windowInfo:
                if let s = streams[id], let info = WindowInfo.decode(r.rest()) { s.received(info) }
            case .windowChrome:
                if let s = streams[id], let c = WindowChrome.decode(r.rest()) { s.received(c) }
            case .windowGone:
                Log.info(.viewer, "← windowGone #\(id): the window closed on the host")
                streams.removeValue(forKey: id)?.receivedGone()
            default: break
            }
            return
        }
        switch t {
        case .pong: latency.pong(p); lastPongAt = Date()
        case .hostStatus:
            let s = r.str() ?? ""
            Log.info(.viewer, "← hostStatus: \(s.isEmpty ? "(clear)" : s)")
            main { $0.onHostStatus?(s) }
        case .appIcon:
            if let key = r.str() { icons[key] = r.rest() }
        case .appIconLarge:
            guard let key = r.str(), let px = r.u16(), let total = r.u32(), let offset = r.u32(), total < 8 << 20 else { return }
            var part = largeIcons[key] ?? (Int(px), Int(total), Data())
            if offset == 0 { part = (Int(px), Int(total), Data()) }
            guard Int(offset) == part.data.count else { largeIcons[key] = nil; return } // out of step: drop it
            part.data.append(r.rest())
            if part.data.count >= part.total {
                largeIcons[key] = nil
                let png = part.data
                main { $0.onLargeIcon?(key, Int(px), png) }
            } else {
                largeIcons[key] = part
            }
            if part.data.count >= part.total { Log.debug(.viewer, "← large icon of \(key): \(px) px, \(total) B") }
        case .menuTree:
            if let key = r.str() {
                let msg = message(.menuTree) { $0.bytes(p) }
                main { $0.onMenuTree?(key, msg) }
            }
        case .hostClipboardBegin, .hostClipboardChunk, .hostClipboardState:
            if let cb = clipboard { DispatchQueue.main.async { cb.receive(t, p) } }
        case .newWindowHeld:
            guard let wid = r.u32(), let key = r.str(), let name = r.str(), let open = r.u8(), let max = r.u8() else { return }
            Log.info(.viewer, "← newWindowHeld: window \(wid) of \(name) (\(key)), \(open) of \(max) open")
            main { $0.onNewWindowHeld?(wid, key, name, Int(open), Int(max)) }
        case .windowList:
            if let list = WindowEntry.decode(p) {
                windowLists += 1
                let apps = Set(list.map(\.appKey)).count
                if windowLists == 1 { Log.info(.viewer, "← windowList: \(list.count) windows of \(apps) apps") } else { Log.debug(.viewer, "← windowList #\(windowLists): \(list.count) windows of \(apps) apps") }
                let windows = list.map { RemoteWindow(entry: $0, icon: icons[$0.appKey]) }
                main { $0.onWindowList?(windows) }
            }
        default: break
        }
    }

    private func receiveUDP(_ c: NWConnection) {
        c.receiveMessage { [weak self, weak c] data, _, _, err in
            guard let self, let c else { return }
            if let data, !injectedDrop() {
                bytesDown.add(data.count)
                lastUDPAt = Date()
                udpDatagrams += 1
                if videoPath.active { videoPath.end("UDP from the host arrives again (flow #\(udpFlows))") }
                if let emu = netEmu { emu.datagram { [weak self] in self?.handleDatagram(data) } } else { handleDatagram(data) }
            }
            if let err {
                guard !failed, c === udp else { return }
                // It used to stop here for good: no more video for the rest of the session.
                Log.warning(.net, "UDP \(address): receive failed: \(err.logDescription); flow \(c.state.logDescription)")
                q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, c === udp, !failed else { return }
                    rebuildUDP("receiving failed (\(err.logDescription))")
                }
                return
            }
            receiveUDP(c)
        }
    }

    /// Fault `udp-drop-all-for`: true while every incoming datagram is to be dropped. On q.
    private func injectedDrop() -> Bool {
        guard let f = faultDrop else { return false }
        let now = Date()
        let dropping = now >= f.from && now < f.until
        if dropping != faultDropping {
            faultDropping = dropping
            if dropping { Log.warning(.net, "FAULT udp-drop-all-for: dropping every incoming datagram for \(Int(f.until.timeIntervalSince(f.from))) s") }
            else { Log.warning(.net, "FAULT udp-drop-all-for: over, datagrams pass again"); faultDrop = nil }
        }
        if !dropping, now >= f.until { faultDrop = nil }
        return dropping
    }

    /// WISP_DROP_WINDOW=<host window ID>: WISP_DROP's loss hits only that window's stream.
    private let dropWindow = UInt32(ProcessInfo.processInfo.environment["WISP_DROP_WINDOW"] ?? "")

    private func handleDatagram(_ d: Data) {
        var r = Reader(d)
        guard let kind = r.u8() else { return }
        if kind == Wire.Datagram.helloEcho.rawValue {
            if r.u32() == session {
                if lastEchoAt == nil { Log.info(.net, "UDP \(address): the host echoes our hellos: the video path is checked both ways") }
                lastEchoAt = Date()
            }
            return
        }
        guard kind == Wire.Datagram.video.rawValue || kind == Wire.Datagram.parity.rawValue,
              let id = r.u16(), let s = streams[id] else { return }
        // WISP_DROP=<percent> simulates a lossy network for testing recovery.
        if dropPercent > 0, dropWindow == nil || dropWindow == s.windowID, Double.random(in: 0 ..< 100) < dropPercent { return }
        if kind == Wire.Datagram.parity.rawValue { s.handleParity(&r) } else { s.handleVideo(&r) }
    }

    /// One minimal round trip plus slack before re-asking for a lost packet: 250 ms suited the 150 ms
    /// link to the UK but stalled a 3 ms LAN for ages.
    var renackAfter: TimeInterval {
        guard let rtt = latency.rttMin else { return 0.25 }
        return max(0.02, Double(rtt) / 1_000_000 * 1.5 + 0.01)
    }
}

/// One stream (a remote window) as the viewer sees it: its own reassembly, repair and decoder, and
/// the latest size, title and chrome for whichever local window shows it. Info, chrome and "gone"
/// are delivered on the main queue and replayed to a window that attaches late; decoded images
/// arrive on the network queue. In phantom mode (`relays`) frames aren't decoded here: each complete
/// one goes to `relay` (the phantom app showing this stream), which decodes it.
final class RemoteStream: ViewerStream {
    let id: UInt16
    let windowID: UInt32
    /// The window's app (key, name) as the host named it in streamOpened; nil from an older host.
    fileprivate(set) var app: (key: String, name: String)?
    private weak var client: Client?
    private let decoder = Decoder()
    private let relays: Bool
    /// Phantom mode: where complete frames go (FrameTag onwards, time reassembled). On the network queue.
    private var relay: ((Data, UInt64) -> Void)?
    let frames = Counter(), keyframes = Counter(), resent = Counter(), keyRequests = Counter(), fecRecovered = Counter()

    // Main queue.
    private(set) var info: RemoteInfo?
    private(set) var chrome: WindowChrome?
    private(set) var isGone = false
    private(set) var isClosed = false
    private var onInfo: ((RemoteInfo) -> Void)?
    private var onChrome: ((WindowChrome) -> Void)?
    private var onGone: (() -> Void)?
    private var onClosed: (() -> Void)?

    // Images: set from the main queue, used on the network queue.
    private let imageLock = NSLock()
    private var onImage: ((CVPixelBuffer, FrameTiming) -> Void)?
    private var lastImage: (CVPixelBuffer, FrameTiming)?
    private var decoding: FrameTiming?

    init(id: UInt16, windowID: UInt32, client: Client, relays: Bool = false) {
        self.id = id
        self.windowID = windowID
        self.client = client
        self.relays = relays
        decoder.onImage = { [weak self] pb in
            guard let self, var t = decoding else { return }
            t.decoded = nowMicros()
            decoding = t
            imageLock.lock()
            lastImage = (pb, t)
            let sink = onImage
            imageLock.unlock()
            sink?(pb, t)
        }
    }

    /// Where this stream's updates go (main queue). What arrived before is replayed at once.
    func attach(info: ((RemoteInfo) -> Void)? = nil, chrome: ((WindowChrome) -> Void)? = nil, gone: (() -> Void)? = nil,
                closed: (() -> Void)? = nil, image: ((CVPixelBuffer, FrameTiming) -> Void)? = nil) {
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
        client?.onQueue { self.relay = nil }
    }

    /// Phantom mode: send complete frames to `sink` from now on (nil: drop them), starting with a
    /// fresh keyframe, since the phantom's decoder has seen nothing yet.
    func relay(to sink: ((Data, UInt64) -> Void)?) {
        client?.onQueue { [self] in
            relay = sink
            if sink != nil { lastKeyRequest = .distantPast; requestKeyframe() }
        }
    }

    /// The phantom couldn't decode a frame: it skips frames until a keyframe, which we ask for now.
    func relayDecodeFailed() {
        client?.onQueue { [self] in
            lastKeyRequest = .distantPast
            requestKeyframe()
        }
    }

    fileprivate func received(_ i: RemoteInfo) { DispatchQueue.main.async { self.info = i; self.onInfo?(i) } }
    fileprivate func received(_ c: WindowChrome) { DispatchQueue.main.async { self.chrome = c; self.onChrome?(c) } }
    fileprivate func receivedGone() { DispatchQueue.main.async { self.isGone = true; self.onGone?() } }
    /// Main queue: the host ended the stream (streamClosed).
    fileprivate func closed() { isClosed = true; onClosed?() }

    /// A message about this stream: its ID, then the payload.
    func message(_ type: MsgType, _ build: (inout Writer) -> Void = { _ in }) -> Data { WispCommon.message(type, stream: id, build) }

    // MARK: Reassembly and repair, on the client's queue
    //
    // Frames are decoded strictly in order; holes are filled by asking the host to resend just the
    // missing packets (NACK). A stream that stays stuck asks for a keyframe of its own: a lost packet
    // in one window never costs a keyframe in the others.

    private struct Partial {
        var chunks: [Data?]
        var got = 0
        var lastArrival = Date()
        var lastNack: Date?
        var parity: [Int: Data] = [:] // FEC group -> XOR of its chunks
        var groupSize = 0
        var frameLen = 0
        var complete: Bool { got == chunks.count }
        var isKey: Bool { // flags byte follows the FrameTag at the start of chunk 0
            guard complete, let c = chunks[0], c.count > FrameTag.size else { return false }
            return c[c.startIndex + FrameTag.size] & 1 == 1
        }
    }
    private var pending: [UInt32: Partial] = [:]
    private var next: UInt32?            // next frame to decode; nil = waiting for a keyframe
    private var highest: UInt32?         // newest frame number seen
    private var wholeNacked: [UInt32: Date] = [:]
    private var stuckSince: Date?
    private var lastKeyRequest = Date.distantPast

    // Stall detection (checkStall), on the client's queue.
    private var lastProgress = Date()             // a frame decoded (or relayed to a phantom), or the stream opened
    private var lastDatagram = Date.distantPast
    private var datagrams = 0, nacksSent = 0, decodeFailures = 0, framesUnrouted = 0
    private var lastStallCheck = Date.distantPast, lastRecovery = Date.distantPast
    private lazy var stall = StallEpisode("stream #\(id) viewer", .viewer)

    fileprivate func handleVideo(_ r: inout Reader) {
        noteDatagram()
        guard let n = r.u32(), let idx = r.u16(), let count = r.u16(), count > 0, idx < count else { return }
        if let next, n < next { return } // already decoded or skipped
        var p = pending[n] ?? Partial(chunks: Array(repeating: nil, count: Int(count)))
        guard p.chunks.count == Int(count), p.chunks[Int(idx)] == nil else { return }
        p.chunks[Int(idx)] = r.rest()
        p.got += 1
        p.lastArrival = Date()
        if p.groupSize > 0 { recover(&p, group: Int(idx) / p.groupSize) }
        pending[n] = p
        highest = max(highest ?? n, n)
        drain()
    }

    fileprivate func handleParity(_ r: inout Reader) {
        noteDatagram()
        guard let n = r.u32(), let group = r.u16(), let count = r.u16(), let k = r.u8(), let len = r.u32(),
              count > 0, k > 0 else { return }
        if let next, n < next { return }
        var p = pending[n] ?? Partial(chunks: Array(repeating: nil, count: Int(count)))
        guard p.chunks.count == Int(count), !p.complete else { return }
        p.groupSize = Int(k)
        p.frameLen = Int(len)
        p.parity[Int(group)] = r.rest()
        p.lastArrival = Date()
        recover(&p, group: Int(group))
        pending[n] = p
        highest = max(highest ?? n, n)
        drain()
    }

    /// If exactly one chunk of `group` is missing and we hold its parity, rebuild it: no round trip.
    private func recover(_ p: inout Partial, group: Int) {
        guard let parity = p.parity[group] else { return }
        let size = Wire.maxChunkPayload
        let range = group * p.groupSize ..< min((group + 1) * p.groupSize, p.chunks.count)
        let missing = range.filter { p.chunks[$0] == nil }
        guard missing.count == 1, let m = missing.first else { return }
        var acc = [UInt8](repeating: 0, count: size)
        xorInto(&acc, parity)
        for i in range where i != m { xorInto(&acc, p.chunks[i]!) }
        let len = m == p.chunks.count - 1 ? p.frameLen - m * size : size
        guard len > 0, len <= size else { return }
        p.chunks[m] = Data(acc[0 ..< len])
        p.got += 1
        fecRecovered.add(1)
    }

    private func drain() {
        // A complete keyframe ahead of us resets everything: jump straight to it.
        if let k = pending.filter({ $0.value.isKey && (next == nil || $0.key > next!) }).keys.max(),
           next == nil || pending[next!]?.complete != true {
            next = k
        }
        while let n = next, let p = pending[n], p.complete {
            pending[n] = nil
            let payload = p.chunks.reduce(into: Data()) { $0.append($1!) }
            var r = Reader(payload)
            guard let tag = FrameTag.read(&r), tag.stream == id else { next = n &+ 1; continue }
            if relays {
                // The phantom decodes it; it reports the timing back (frameDecoded/frameDisplayed).
                if let relay { relay(payload, nowMicros()) } else { framesUnrouted += 1 }
                frames.add(1)
                if p.isKey { keyframes.add(1) }
                next = n &+ 1
                progressed(n, key: p.isKey)
                continue
            }
            decoding = FrameTiming(tag: tag, decodeStart: nowMicros())
            if decoder.decode(r.rest()) {
                if let t = decoding { client?.latency.frameDecoded(t) }
                frames.add(1)
                if p.isKey { keyframes.add(1) }
                next = n &+ 1
                progressed(n, key: p.isKey)
            } else {
                decodeFailures += 1
                Log.debug(.viewer, "stream #\(id): frame #\(n)\(p.isKey ? " (keyframe)" : "") didn't decode (\(decoder.state)): waiting for a keyframe")
                next = nil
                requestKeyframe()
                break
            }
        }
        if let next {
            pending = pending.filter { $0.key >= next }
            wholeNacked = wholeNacked.filter { $0.key >= next }
        }
    }

    /// Runs every 30 ms: ask for missing packets, and fall back to a keyframe if stuck.
    fileprivate func repair() {
        let now = Date()
        guard let highest, let client else { return }
        let renack = client.renackAfter

        for (n, p) in pending where !p.complete {
            // Holes are real once newer frames are arriving or this frame has gone quiet.
            guard n < highest || now.timeIntervalSince(p.lastArrival) > 0.03 else { continue }
            guard p.lastNack.map({ now.timeIntervalSince($0) > renack }) ?? true else { continue }
            let missing = p.chunks.indices.filter { p.chunks[$0] == nil }
            nack(n, missing.map(UInt16.init))
            pending[n]?.lastNack = now
        }
        // Frames we never saw a single packet of.
        if let next, highest > next {
            for n in next ..< highest where pending[n] == nil {
                guard wholeNacked[n].map({ now.timeIntervalSince($0) > renack }) ?? true else { continue }
                nack(n, nil)
                wholeNacked[n] = now
            }
        }

        let stuck = next == nil || (pending[next!] != nil || highest >= next!)
        if stuck {
            stuckSince = stuckSince ?? now
            if now.timeIntervalSince(stuckSince!) > 1.0 { requestKeyframe() }
        } else {
            stuckSince = nil
        }
        if now.timeIntervalSince(lastStallCheck) >= 0.5 { lastStallCheck = now; checkStall(now) }
    }

    private func noteDatagram() { lastDatagram = Date(); datagrams += 1 }

    /// A frame left reassembly (decoded, or relayed to the phantom): ends a stall. On q.
    private func progressed(_ n: UInt32, key: Bool) {
        lastProgress = Date()
        guard stall.active else { return }
        stall.end("frame #\(n)\(key ? " (a keyframe)" : "") \(relays ? "relayed to the phantom" : "decoded")")
    }

    /// What this stream's reassembly and decoder look like, for a stall report.
    private func stallDetail(_ now: Date) -> String {
        let incomplete = pending.filter { !$0.value.complete }.sorted { $0.key < $1.key }
        let holes = incomplete.prefix(4).map { "#\($0.key) missing \($0.value.chunks.count - $0.value.got)/\($0.value.chunks.count)" }
            .joined(separator: ", ") + (incomplete.count > 4 ? ", …" : "")
        let keyAge = lastKeyRequest == .distantPast ? "never" : String(format: "%.1f s ago", now.timeIntervalSince(lastKeyRequest))
        return "next frame \(next.map { "#\($0)" } ?? "none (waiting for a keyframe)"), highest seen \(highest.map { "#\($0)" } ?? "none"), "
            + "\(pending.count) frames pending (\(incomplete.count) incomplete\(holes.isEmpty ? "" : ": \(holes)")), "
            + "keyframe last asked \(keyAge) (\(keyRequests.total) asks in all), NACKs sent \(nacksSent) (\(wholeNacked.count) whole frames outstanding), "
            + "FEC recoveries \(fecRecovered.total), decode failures \(decodeFailures)"
            + (relays ? ", phantom attached: \(relay != nil ? "yes" : "NO") (\(framesUnrouted) frames had nowhere to go)" : "; decoder: \(decoder.state)")
            + String(format: ", last datagram %.1f s ago (%d in all)", now.timeIntervalSince(lastDatagram), datagrams)
    }

    /// Every 0.5 s: no frame for 2 s although video for this stream keeps arriving (or a frame is
    /// half-received, or we wait for a keyframe) is a stall: say what's stuck. After 3 s, recover:
    /// flush reassembly, recreate the decoder if it failed, ask for a keyframe; again every 3 s.
    /// An idle window (nothing arriving, nothing pending) is not a stall. On q.
    private func checkStall(_ now: Date) {
        guard lastDatagram != .distantPast else { return } // nothing ever arrived: the video path's problem
        let quiet = now.timeIntervalSince(lastProgress)
        let arriving = now.timeIntervalSince(lastDatagram) < 1.5
        let waiting = next == nil || pending.values.contains { !$0.complete }
        guard quiet > 2, arriving || waiting else { return }
        if !stall.active {
            stall.begin(String(format: "no frame %@ for %.1f s while ", relays ? "relayed" : "decoded", quiet)
                + (arriving ? "video for it keeps arriving" : "a frame is incomplete or a keyframe is awaited") + "; " + stallDetail(now),
                at: lastProgress)
            Log.debug(.viewer, "stream #\(id) stall detail: pending frames \(pending.keys.sorted().prefix(20).map { "#\($0)" }.joined(separator: " "))")
        }
        guard quiet > 3, now.timeIntervalSince(lastRecovery) > 3 else { return }
        lastRecovery = now
        Log.debug(.viewer, "stream #\(id) before recovery: \(stallDetail(now))")
        let dropped = pending.count
        pending = [:]
        wholeNacked = [:]
        next = nil
        stuckSince = nil
        if !relays, decoder.hasFailed {
            let was = decoder.state
            decoder.reset()
            stall.act("recreated the decoder (\(was))")
        }
        lastKeyRequest = .distantPast
        requestKeyframe()
        stall.act("flushed reassembly (\(dropped) frames dropped) and asked for a keyframe")
    }

    private func nack(_ frame: UInt32, _ chunks: [UInt16]?) {
        nacksSent += 1
        resent.add(chunks?.count ?? 1)
        client?.send(message(.nack) { w in
            w.u32(frame)
            if let chunks {
                let list = chunks.prefix(500)
                w.u16(UInt16(list.count))
                list.forEach { w.u16($0) }
            } else {
                w.u16(0xFFFF)
            }
        })
    }

    /// On the client's queue; at most once a second.
    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) > 1.0 else { return }
        keyRequests.add(1)
        lastKeyRequest = Date()
        stuckSince = nil
        client?.send(message(.keyframeRequest))
    }
}

/// Hardware decoder producing IOSurface-backed BGRA buffers a CALayer can show directly.
/// After a failed frame the session is thrown away and the next keyframe makes a new one: a session
/// that VideoToolbox invalidated (sleep, a GPU or media-engine reset: kVTInvalidSessionErr) used to
/// be kept as long as the format didn't change, and then every keyframe failed too, for good.
/// Used on one queue (the client's, or a phantom's connection queue).
final class Decoder {
    var onImage: ((CVPixelBuffer) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var failures = 0
    private var lastStatus: OSStatus = noErr
    private var failedSinceGood = false
    private var sessions = 0, noImage = 0
    /// Fault `decoder-fail-once[=<s>]`: that many seconds (default 4) after the first decoded frame,
    /// the session in use "breaks" (every frame fails with kVTInvalidSessionErr) until it is replaced.
    private static let faultAt = Fault.number("decoder-fail-once", default: 4)
    private static let faultLock = NSLock()
    nonisolated(unsafe) private static var faultDone = false
    private var firstFrameAt: Date?
    private var brokenSession: VTDecompressionSession?

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// The last decode failed, and no frame has decoded since.
    var hasFailed: Bool { failedSinceGood }
    /// For stall reports: sessions made, failures, the last OSStatus.
    var state: String {
        "\(session == nil ? "no session" : "session #\(sessions)"), \(failures) failures"
            + (lastStatus != noErr ? ", last OSStatus \(lastStatus)\(lastStatus == kVTInvalidSessionErr ? " (kVTInvalidSessionErr)" : "")" : "")
            + (noImage > 0 ? ", \(noImage) frames without an image" : "")
    }

    /// Throws the session away: the next keyframe makes a new one.
    func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
    }

    private func injectFault(_ session: VTDecompressionSession) -> Bool {
        guard let at = Self.faultAt else { return false }
        if brokenSession === session { return true }
        let first = firstFrameAt ?? Date()
        firstFrameAt = first
        Self.faultLock.lock()
        let fire = !Self.faultDone && Date().timeIntervalSince(first) >= at
        if fire { Self.faultDone = true }
        Self.faultLock.unlock()
        guard fire else { return false }
        brokenSession = session
        Log.warning(.viewer, "FAULT decoder-fail-once: decoder session #\(sessions) now fails every frame (kVTInvalidSessionErr) until it is replaced")
        return true
    }

    func decode(_ payload: Data) -> Bool {
        let ok = decodeFrame(payload)
        if ok { failedSinceGood = false } else { failedSinceGood = true }
        return ok
    }

    private func decodeFrame(_ payload: Data) -> Bool {
        var r = Reader(payload)
        guard let flags = r.u8() else { return false }
        let hevc = flags & 2 != 0
        if flags & 1 != 0 {
            guard let count = r.u8() else { return false }
            var sets: [Data] = []
            for _ in 0 ..< count {
                guard let len = r.u16(), let s = r.bytes(Int(len)) else { return false }
                sets.append(s)
            }
            guard let fd = makeFormat(sets, hevc: hevc) else { failed("the \(hevc ? "HEVC" : "H.264") parameter sets (\(count)) make no format"); return false }
            if session == nil || format == nil || !CMFormatDescriptionEqual(fd, otherFormatDescription: format!) {
                if let s = session { VTDecompressionSessionInvalidate(s) }
                session = makeSession(fd)
                format = fd
                if session != nil { sessions += 1 }
                let dim = CMVideoFormatDescriptionGetDimensions(fd)
                Log.info(.viewer, "decoder \(session == nil ? "couldn't be made" : "session #\(sessions) made") for \(hevc ? "HEVC" : "H.264") \(dim.width)x\(dim.height)"
                         + (failedSinceGood ? " (after a failure: \(lastStatus == noErr ? "no image" : "OSStatus \(lastStatus)"))" : ""))
            }
        }
        guard let session, let format else { return false }

        let sample = r.rest()
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: sample.count,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        guard let bb else { return false }
        sample.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: sample.count) }
        var sb: CMSampleBuffer?
        var size = sample.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sb)
        guard let sb else { return false }

        if injectFault(session) {
            lastStatus = kVTInvalidSessionErr
            failed("decode failed: OSStatus \(kVTInvalidSessionErr) (injected)")
            reset()
            return false
        }
        var ok = false
        var frameStatus: OSStatus = noErr
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            frameStatus = status
            guard status == noErr, let image else { return }
            ok = true
            self?.onImage?(image)
        }
        let status = st != noErr ? st : frameStatus
        if status != noErr {
            lastStatus = status
            failed("decode failed: OSStatus \(status)\(status == kVTInvalidSessionErr ? " (kVTInvalidSessionErr: the session is gone)" : "")")
            // A new session with the next keyframe: this one may be broken for good.
            reset()
        } else if !ok {
            noImage += 1
            if noImage <= 3 || noImage % 100 == 0 { Log.warning(.viewer, "decoder returned no image for a frame (\(noImage) so far): waiting for a keyframe") }
        }
        return st == noErr && ok
    }

    /// A decode failure: the first few, then one in a hundred (a broken stream fails every frame).
    private func failed(_ what: String) {
        failures += 1
        if failures <= 3 || failures % 100 == 0 { Log.warning(.viewer, "\(what) (failure \(failures))") }
    }

    private func makeFormat(_ sets: [Data], hevc: Bool) -> CMVideoFormatDescription? {
        let bufs = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        let ptrs = bufs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let st = hevc
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                                                                   parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
                                                                   parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        return st == noErr ? fd : nil
    }

    private func makeSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        if st != noErr { Log.error(.viewer, "VTDecompressionSessionCreate failed: OSStatus \(st)") }
        if let s { VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        return s
    }
}

func writePNG(_ pb: CVPixelBuffer, to path: String) {
    let ci = CIImage(cvPixelBuffer: pb)
    guard let cg = CIContext().createCGImage(ci, from: ci.extent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

extension Client: StreamLink {}
