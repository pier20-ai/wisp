// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import Network
import Tailnet
import ScreenCaptureKit
import WispCommon

struct HostOptions {
    var kbps = 10000 // ceiling for all streams together; backs off automatically when the viewer reports loss
    var fps = 60
    var fec = 8 // FEC group size: one parity packet per this many video packets (0 = off)
    var scale: Double?
    var hevc = true
    var refine = 3
    var paceMbps = 60.0 // ceiling; scaled down together with the bitrate
    /// Put the shared windows on a HiDPI virtual display sized to the viewer's screen, so a headless
    /// host (1x framebuffer only) still renders them at 2x.
    var virtualDisplay = true
    /// Most windows streamed at once (each is a capture plus a hardware encoder session).
    // An M4 Mac mini runs at most 3 low-latency HEVC encoders before every session drops to ~93 ms per
    // frame (scripts/hevc-sessions.swift, 2026-11-03); 16 stopped producing frames altogether.
    var maxStreams = 3
    /// Sync the clipboard with viewers that support it (whether it's on is the setting
    /// ClipboardSync.hostKey, read live). The CLI's synthetic host leaves it off unless WISP_PASTEBOARD is set.
    var clipboard = true

    /// The app reads overrides from its defaults, e.g. `defaults write <Brand.defaultsDomain> codec h264`.
    static func fromDefaults() -> HostOptions {
        let d = Brand.defaults
        var o = HostOptions()
        if d.object(forKey: "kbps") != nil { o.kbps = d.integer(forKey: "kbps") }
        if d.object(forKey: "fps") != nil { o.fps = d.integer(forKey: "fps") }
        if d.object(forKey: "scale") != nil { o.scale = d.double(forKey: "scale") }
        if let c = d.string(forKey: "codec") { o.hevc = c.lowercased() != "h264" }
        if d.object(forKey: "refine") != nil { o.refine = d.integer(forKey: "refine") }
        if d.object(forKey: "paceMbps") != nil { o.paceMbps = d.double(forKey: "paceMbps") }
        if d.object(forKey: "fec") != nil { o.fec = d.integer(forKey: "fec") }
        if d.object(forKey: "virtualDisplay") != nil { o.virtualDisplay = d.bool(forKey: "virtualDisplay") }
        if d.object(forKey: "maxStreams") != nil { o.maxStreams = max(1, d.integer(forKey: "maxStreams")) }
        return o
    }
}

// MARK: - Network

/// One viewer at a time, with any number of streams. TCP carries input and control; UDP carries video.
/// Frame numbering, FEC and the resend cache are per stream; the pacer is shared, since all streams
/// go over the same link.
final class Server {
    private let q = DispatchQueue(label: "wisp.net")
    private let lock = NSLock()
    private var viewer: NWConnection?
    private var session: UInt32 = 0
    private var udpPeer: NWConnection?

    // Per stream: frame numbers, and recently sent packets kept so the viewer can ask for just the ones it lost.
    private struct Tx {
        var frameNo: UInt32 = 0
        var cache: [UInt32: [Data]] = [:]
        var order: [UInt32] = []
        var nacksServed = 0, packetsResent = 0, nacksMissed = 0 // missed: the frame had left the cache
        var lastSentAt: UInt64 = 0
        var lastTooOldKey: UInt64 = 0
    }
    private var tx: [UInt16: Tx] = [:]
    private let cacheFrames = 240

    // Pacing: big frames (keyframes, fast scrolling) go out at a steady rate instead of one
    // burst that overflows router buffers on a long path. Small frames go straight through.
    private let pacer = DispatchQueue(label: "wisp.pacer", qos: .userInteractive)
    private var bytesPerSecond: Double // only touched on pacer
    private let burstSeconds = 0.006
    private var sendClock = 0.0 // only touched on pacer

    private let fecGroup: Int
    let hostName = Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    // Protocol-1 viewers: told to update, then dropped (see LegacyNotice).
    private var legacy: [ObjectIdentifier: (c: NWConnection, host: String, frameNo: UInt32)] = [:] // q
    private lazy var notice = LegacyNotice(text: "\(Brand.name) on \(hostName) is newer (protocol \(Wire.protocolVersion)): update \(Brand.name) on this Mac")

    init(paceMbps: Double, fecGroup: Int) {
        bytesPerSecond = paceMbps * 1_000_000 / 8
        self.fecGroup = fecGroup
    }

    // Callbacks, all on the network queue. Stream 0 from a control-only connection means "the primary stream".
    var onInput: ((UInt16, MsgType, Data) -> Void)?
    var onKeyframeRequest: ((UInt16) -> Void)?
    var onOpenStream: ((UInt32) -> Void)?
    var onCloseStream: ((UInt16) -> Void)?
    var onStats: ((ViewerStats, NWEndpoint) -> Void)?
    /// helloAck has been sent to a new viewer.
    var onViewerReady: (() -> Void)?
    /// The new viewer's UDP path is open: every stream it has open needs a keyframe.
    var onVideoPathOpen: (() -> Void)?
    var hasViewerConnection: Bool { lock.lock(); defer { lock.unlock() }; return viewer != nil }
    var onWindowListRequest: (() -> Void)?
    /// The viewer wants an app's icon at a size (appKey, px).
    var onIconRequest: ((String, Int) -> Void)?
    /// The viewer wants an app's menu bar (appKey, MenuTree.wholeBar or one top-level menu's AX index).
    var onMenuRequest: ((String, UInt16) -> Void)?
    /// The viewer chose a menu item.
    var onMenuPress: ((MenuPress) -> Void)?
    /// The viewer's usable screen size in points, and its backing scale.
    var onViewerScreen: ((CGSize, Int) -> Void)?
    /// The viewer resized a window: (stream, size in points, request ID).
    var onResizeWindow: ((UInt16, CGSize, UInt32) -> Void)?
    var onWindowAction: ((UInt16, UInt8) -> Void)?
    /// The viewer wants an app reopened, as a Dock click would (appKey).
    var onReopenApp: ((String) -> Void)?
    /// The viewer connection closed (not called when a new viewer replaces the old one).
    var onViewerGone: (() -> Void)?
    /// A new viewer said hello (it replaces any earlier one, whose streams are over).
    var onViewerConnected: (() -> Void)?
    /// A clipboard message from the current viewer (only from it; see ClipboardSync).
    var onClipboard: ((MsgType, Data) -> Void)?
    /// Feature bits this host announces in helloAck (Wire.Feature.clipboard when it can sync). Set before start().
    var hostFeatures: UInt32 = 0

    /// Input messages injected so far for each stream of the current viewer, stamped on that stream's
    /// frames, and when the last one was (µs), to time how long the app takes to show it.
    private var injected: [UInt16: (count: UInt32, at: UInt64)] = [:]
    func inputsApplied(_ s: UInt16) -> UInt32 { lock.lock(); defer { lock.unlock() }; return injected[s]?.count ?? 0 }
    func lastInjectAt(_ s: UInt16) -> UInt64 { lock.lock(); defer { lock.unlock() }; return injected[s]?.at ?? 0 }
    /// Clicks and key presses (down and up) received for each stream of the current viewer (Host/Health.swift).
    private var presses: [UInt16: UInt32] = [:]
    func pressesReceived(_ s: UInt16) -> UInt32 { lock.lock(); defer { lock.unlock() }; return presses[s] ?? 0 }
    func noteInjected(_ s: UInt16) {
        lock.lock()
        injected[s] = ((injected[s]?.count ?? 0) &+ 1, nowMicros())
        lock.unlock()
    }

    /// Time frames wait in the pacer before their last packet leaves.
    let pacingDelay = Samples()
    let bytesOut = Counter(), bytesIn = Counter(), framesOut = Counter(), keyframesOut = Counter(), resent = Counter()
    /// Packets the viewer had to ask for again: the congestion signal (FEC hides isolated losses).
    let lossSignal = Counter()
    /// Frames sent per stream since the last call to takeStreamFrames.
    private var streamFrames: [UInt16: Int] = [:]
    private var streamFramesTotal: [UInt16: Int] = [:]
    /// Frames sent on stream `s` so far (for the host window's fps).
    func framesSent(_ s: UInt16) -> Int { lock.lock(); defer { lock.unlock() }; return streamFramesTotal[s] ?? 0 }
    func takeStreamFrames() -> [UInt16: Int] { lock.lock(); defer { streamFrames = [:]; lock.unlock() }; return streamFrames }

    func setPace(mbps: Double) { pacer.async { [self] in bytesPerSecond = mbps * 1_000_000 / 8 } }

    var hasViewer: Bool { lock.lock(); defer { lock.unlock() }; return udpPeer != nil }

    // Per viewer: whether it has asked for the window list, and which app icons it already has.
    private var listWanted = false
    private var iconsSent: Set<String> = []
    var wantsWindowList: Bool { lock.lock(); defer { lock.unlock() }; return listWanted }
    /// True the first time `key` is asked about for the current viewer.
    func needsIcon(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return iconsSent.insert(key).inserted }

    private var listeners: [NWListener] = []

    /// Who may connect (see Access.swift).
    lazy var access = AccessControl(hostName: hostName)
    /// The probe's answer (called on the main queue); the host fills it in.
    var probeInfo: (() -> ProbeReply)?
    // The current viewer: who (from whois), the name its hello gave, since when. Under lock.
    private var viewerIdentity: PeerIdentity?
    private var viewerName = ""
    private var viewerSince: Date?
    private var viewerFeatures: UInt32 = 0
    /// The current viewer lets us open streams for new windows by themselves (Wire.Feature.followsNewWindows).
    var viewerFollowsNewWindows: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewer != nil && viewerFeatures & Wire.Feature.followsNewWindows != 0
    }
    /// The current viewer announced Wire.Feature.clipboard.
    var viewerSyncsClipboard: Bool {
        lock.lock(); defer { lock.unlock() }
        return viewer != nil && viewerFeatures & Wire.Feature.clipboard != 0
    }
    /// The current viewer, for the host window.
    var currentViewer: (who: PeerIdentity, name: String, since: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard viewer != nil, let w = viewerIdentity else { return nil }
        return (w, viewerName, viewerSince ?? Date())
    }

    /// Disconnects the current viewer (the host window's Disconnect); it may connect again.
    func disconnectViewer() {
        lock.lock(); let c = viewer; lock.unlock()
        guard let c else { return }
        Log.info(.host, "disconnecting the viewer (\(c.endpoint))")
        q.async { [self] in c.cancel(); dropViewer(c) }
    }

    /// Stops listening and drops the viewer: sharing is over (the host window closed).
    func stop() {
        q.async { [self] in
            Log.info(.net, "stopping the listeners on TCP \(Wire.tcpPort) / UDP \(Wire.udpPort)")
            listeners.forEach { $0.cancel() }
            listeners = []
            lock.lock(); let c = viewer; lock.unlock()
            if let c { c.cancel(); dropViewer(c) }
            legacy.values.forEach { $0.c.cancel() }
            legacy = [:]
        }
    }

    /// Listens on TCP 7878 and UDP 7879, or throws if either port is taken. The ports are bound
    /// exclusively (no SO_REUSEADDR/SO_REUSEPORT), and this waits until both listeners are actually
    /// up: NWListener reports a bind failure only later, through its state, so a second host used to
    /// log "listening" while a stale one kept answering viewers.
    func start() throws {
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true // input events are tiny; never wait to batch them
        let tcpParams = NWParameters(tls: nil, tcp: tcpOpts)
        tcpParams.allowLocalEndpointReuse = false
        let tcp = try NWListener(using: tcpParams, on: NWEndpoint.Port(rawValue: Wire.tcpPort)!)
        tcp.newConnectionHandler = { [weak self] c in self?.accept(c) }

        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = false
        let udp = try NWListener(using: udpParams, on: NWEndpoint.Port(rawValue: Wire.udpPort)!)
        udp.newConnectionHandler = { [weak self] c in
            Log.debug(.net, "UDP flow from \(c.endpoint)")
            c.start(queue: self!.q)
            self?.receiveHello(c)
        }

        for (l, what, port) in [(tcp, "tcp", Wire.tcpPort), (udp, "udp", Wire.udpPort)] {
            let t0 = Date()
            if let err = Self.startAndWait(l, queue: q) {
                Log.error(.net, "\(what.uppercased()) listener on port \(port) failed to start: \(err.logDescription)")
                listeners.forEach { $0.cancel() }
                listeners = []
                l.cancel()
                throw HostError(Self.describeBindFailure(err, proto: what, port: port))
            }
            Log.debug(.net, "\(what.uppercased()) listener on port \(port) \(l.state.logDescription) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            listeners.append(l)
        }
        Log.info(.net, "listening on TCP \(Wire.tcpPort) / UDP \(Wire.udpPort) (protocol \(Wire.protocolVersion), host name \"\(hostName)\")")
    }

    /// Starts `l` and waits (at most 5 s) for it to be ready; returns the error if it fails.
    private static func startAndWait(_ l: NWListener, queue: DispatchQueue) -> NWError? {
        let done = DispatchSemaphore(value: 0)
        var result: NWError?
        var finished = false
        l.stateUpdateHandler = { st in
            switch st {
            case .ready: if !finished { finished = true; done.signal() }
            case .cancelled: Log.debug(.net, "listener on port \(l.port?.rawValue ?? 0) cancelled")
            case .failed(let e):
                result = e
                if !finished { finished = true; done.signal() }
                // A listener that fails after start-up (e.g. the network stack went away) is logged.
                else { Log.error(.net, "listener on port \(l.port?.rawValue ?? 0) failed: \(e.logDescription)") }
            case .waiting(let e):
                // No usable network yet: it starts listening once there is one.
                Log.warning(.net, "listener on port \(l.port?.rawValue ?? 0) is waiting for the network: \(e.logDescription)")
                if !finished { finished = true; done.signal() }
            default: break
            }
        }
        l.start(queue: queue)
        if done.wait(timeout: .now() + 5) == .timedOut { return .posix(.ETIMEDOUT) }
        return queue.sync { result }
    }

    private static func describeBindFailure(_ e: NWError, proto: String, port: UInt16) -> String {
        if case .posix(.EADDRINUSE) = e {
            let who = portOwner(proto: proto, port: port).map { " by \($0)" } ?? ""
            return "\(proto.uppercased()) port \(port) is already in use\(who). Another \(Brand.name) or `\(Brand.cli) send` "
                + "is probably still sharing on this Mac: quit it (or kill it) and try again."
        }
        return "couldn't listen on \(proto.uppercased()) port \(port): \(e.localizedDescription)"
    }

    /// The process listening on a port, e.g. "wisp (pid 123)", via lsof; nil if unknown.
    private static func portOwner(proto: String, port: UInt16) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", proto == "tcp" ? "-iTCP:\(port)" : "-iUDP:\(port)"] + (proto == "tcp" ? ["-sTCP:LISTEN"] : []) + ["-Fpc"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.failed(.net, "running lsof to find who has port \(port)", error); return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var pid: String?, cmd: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), cmd == nil { cmd = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return "\(cmd ?? "a process") (pid \(pid))"
    }

    /// Every connection is checked first (AccessControl: Tailscale, the allow-list, loopback); a refused
    /// one is told why (`refused`) and closed. Then its first message says what it is: `hello` (a
    /// viewer, which replaces any other), `sideChannel` (`wisp poke`: control only, the current viewer
    /// keeps its session), `probe` (the viewer's list of Macs: answered and closed), or anything else, or
    /// nothing within 0.5 s: a protocol-1 viewer, which is told to update. Everything on q.
    private func accept(_ c: NWConnection) {
        let ip = Self.hostKey(c.endpoint)
        let kind = Tailnet.isLoopback(ip) ? "loopback" : Tailnet.isTailscaleAddress(ip) ? "tailnet" : "LAN/other"
        Log.debug(.net, "incoming TCP connection from \(c.endpoint) (\(kind)); checking access")
        access.check(ip) { [weak self] decision in
            self?.q.async {
                guard let self else { return }
                switch decision {
                case .allow(let who): self.serve(c, who)
                case .refuse(let why, let who):
                    Log.warning(.access, "refused \(who.label) at \(c.endpoint): \(why)")
                    c.start(queue: self.q)
                    c.send(content: message(.refused) { $0.str(why, max: 600) }, completion: .contentProcessed { _ in c.cancel() })
                    self.q.asyncAfter(deadline: .now() + 5) { c.cancel() }
                }
            }
        }
    }

    private func serve(_ c: NWConnection, _ who: PeerIdentity) {
        enum Role { case undecided, viewer, side, probe, legacy }
        var role = Role.undecided
        let parser = MessageParser()
        func legacyViewer(_ why: String) {
            guard role == .undecided else { return }
            role = .legacy
            startLegacy(c, why: why)
        }
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .waiting: Log.info(.net, "connection from \(c.endpoint) \(st.logDescription)")
            default: Log.debug(.net, "connection from \(c.endpoint) \(st.logDescription)")
            }
            switch st {
            case .ready:
                Log.debug(.net, "connection from \(c.endpoint) ready, path: \(c.currentPath?.logDescription ?? "?")")
                self?.q.asyncAfter(deadline: .now() + 0.5) { legacyViewer("it sent no hello") }
            case .failed, .cancelled: self?.dropViewer(c); self?.legacy[ObjectIdentifier(c)] = nil
            default: break
            }
        }
        c.start(queue: q)
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.bytesIn.add(data.count)
                    for (t, p) in parser.feed(data) {
                        if role == .undecided {
                            switch t {
                            case .hello:
                                let h = Hello.decode(p)
                                guard let h, h.version >= 2 else { legacyViewer("it speaks protocol \(h?.version ?? 1)"); continue }
                                role = .viewer
                                self.promote(c, h, who)
                                continue
                            case .sideChannel:
                                var r = Reader(p)
                                guard let v = r.u16(), v >= 2 else {
                                    Log.warning(.host, "an older `\(Brand.cli) poke` (protocol 1) connected from \(c.endpoint): ignored, update it")
                                    role = .legacy
                                    c.cancel()
                                    continue
                                }
                                role = .side
                                Log.info(.host, "control-only connection (side channel, protocol \(v)) from \(who.label) at \(c.endpoint)")
                                // Acknowledged like a hello, so `wisp poke` never sends protocol-2 input to an older host.
                                c.send(content: Hello(version: min(v, Wire.protocolVersion), name: self.hostName).encodeAck(), completion: .idempotent)
                                continue
                            case .probe:
                                Log.debug(.host, "probe from \(who.label) at \(c.endpoint)")
                                role = .probe
                                self.answerProbe(c)
                                continue
                            default:
                                legacyViewer("its first message was \(t)")
                            }
                        }
                        switch role {
                        case .undecided, .legacy, .probe: continue
                        case .side:
                            // A control-only connection may resize, close and send input; nothing else.
                            guard t.isInput || t == .resizeWindow || t == .windowAction else { continue }
                        case .viewer: break
                        }
                        self.handle(t, p, from: c)
                    }
                }
                if done || err != nil {
                    if role == .viewer || role == .side {
                        Log.info(.net, "\(role == .viewer ? "viewer" : "side channel") connection from \(c.endpoint) closed: \(err.map { $0.logDescription } ?? "the other side closed it")")
                    }
                    self.dropViewer(c); c.cancel(); return
                }
                loop()
            }
        }
        loop()
    }

    /// A probe: who we are and how busy (asked on the main queue), then close.
    private func answerProbe(_ c: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let reply = probeInfo?() ?? ProbeReply(hostName: hostName, hasPrimary: false, viewerConnected: hasViewerConnection, openStreams: 0, maxStreams: 0)
            q.async { c.send(content: reply.encode(), completion: .contentProcessed { _ in c.cancel() }) }
        }
    }

    private func handle(_ t: MsgType, _ p: Data, from c: NWConnection) {
        var r = Reader(p)
        // Not the many: pointer motion, scrolls, pings, NACKs, stats, clipboard chunks. Never a key's code (it could be a password).
        if ![.mouseMove, .mouseDrag, .scroll, .ping, .nack, .stats, .clipboardChunk].contains(t) { Log.debug(.host, "← \(t) (\(p.count) B)") }
        if t.isPerStream {
            guard let s = r.u16() else { return }
            switch t {
            case .keyframeRequest: onKeyframeRequest?(s)
            case .nack: resend(s, r)
            case .closeStream:
                Log.info(.host, "← closeStream #\(s)")
                onCloseStream?(s)
            case .resizeWindow:
                if let w = r.u16(), let h = r.u16(), let id = r.u32(), w > 0, h > 0 {
                    onResizeWindow?(s, CGSize(width: Int(w), height: Int(h)), id)
                }
            case .windowAction:
                if let a = r.u8() { onWindowAction?(s, a) }
            default:
                if t == .mouseDown || t == .key {
                    // Clicks and key presses usually change the window: the capture check counts them.
                    lock.lock(); presses[s, default: 0] &+= 1; lock.unlock()
                }
                if t.isInput { onInput?(s, t, r.rest()) }
            }
            return
        }
        switch t {
        case .ping:
            if let seq = r.u32() { sendControl(message(.pong) { $0.u32(seq); $0.u64(nowMicros()) }) }
        case .stats:
            if let s = ViewerStats.decode(p) { onStats?(s, c.endpoint) }
        case .windowListRequest:
            lock.lock(); listWanted = true; lock.unlock()
            onWindowListRequest?()
        case .viewerScreen:
            if let w = r.u16(), let h = r.u16() {
                let scale = Int(r.u8() ?? 1)
                Log.info(.host, "← viewerScreen \(w)x\(h) pt @\(scale)x")
                onViewerScreen?(CGSize(width: Int(w), height: Int(h)), scale)
            }
        case .openStream:
            if let id = r.u32() {
                Log.info(.host, "← openStream window \(id == 0 ? "0 (the shared window)" : "\(id)")")
                onOpenStream?(id)
            }
        case .iconRequest:
            if let key = r.str(), let px = r.u16() { onIconRequest?(key, Int(px)) }
        case .reopenApp:
            if let key = r.str() { Log.info(.host, "← reopenApp \(key)"); onReopenApp?(key) }
        case .menuRequest:
            if let (key, menu) = MenuTree.decodeRequest(p) { onMenuRequest?(key, menu) }
        case .menuPress:
            if let m = MenuPress.decode(p) { onMenuPress?(m) }
        case .clipboardBegin, .clipboardChunk, .clipboardState:
            // Only the admitted, current viewer (not a replaced one still sending, not a side channel).
            lock.lock(); let current = viewer === c; lock.unlock()
            if current { onClipboard?(t, p) }
        default: break
        }
    }

    private func promote(_ c: NWConnection, _ h: Hello, _ who: PeerIdentity) {
        lock.lock()
        let old = viewer, oldPeer = udpPeer
        viewer = c
        viewerIdentity = who
        viewerName = h.name
        viewerFeatures = h.features
        viewerSince = Date()
        session = UInt32.random(in: 1 ... .max)
        udpPeer = nil
        injected = [:]
        presses = [:]
        tx = [:]
        listWanted = false
        iconsSent = []
        var ack = Hello(version: min(h.version, Wire.protocolVersion), name: hostName, session: session)
        ack.features = hostFeatures
        lock.unlock()
        old?.cancel()
        oldPeer?.cancel()
        Log.info(.host, "viewer connected: \(who.label) at \(c.endpoint) (\(h.name.isEmpty ? "unnamed" : h.name), protocol \(h.version), "
                 + "features \(Wire.Feature.describe(h.features))); session \(ack.session)\(old == nil ? "" : ", replacing the previous viewer")")
        onViewerConnected?()
        sendControl(ack.encodeAck())
        onViewerReady?()
    }

    private func dropViewer(_ c: NWConnection) {
        lock.lock()
        guard viewer === c else { lock.unlock(); return }
        viewer = nil
        viewerIdentity = nil
        viewerName = ""
        viewerFeatures = 0
        let peer = udpPeer
        udpPeer = nil
        tx = [:]
        lock.unlock()
        peer?.cancel()
        Log.info(.host, "viewer disconnected (\(c.endpoint))")
        onViewerGone?()
    }

    private func receiveHello(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, data.first == Wire.Datagram.hello.rawValue {
                if data.count >= 5 {
                    var r = Reader(data.dropFirst())
                    let s = r.u32()
                    lock.lock()
                    let old = udpPeer
                    let isNew = udpPeer !== c && viewer != nil && s == session
                    if isNew { udpPeer = c }
                    let current = session, isPeer = udpPeer === c
                    lock.unlock()
                    if !isNew, s != current, !isPeer { Log.debug(.net, "UDP hello from \(c.endpoint) for session \(s.map { "\($0)" } ?? "?") (current \(current)): ignored") }
                    if isNew {
                        if let old {
                            // The viewer's address or source port changed (it made a new UDP flow, or a NAT
                            // rebound it): video follows the latest hello.
                            Log.warning(.net, "video path (UDP) moved: \(old.endpoint) (\(old.state.logDescription)) → \(c.endpoint); "
                                + "following the viewer's latest hello, keyframes for every stream")
                            old.cancel()
                        } else {
                            Log.info(.net, "video path (UDP) open to \(c.endpoint), path: \(c.currentPath?.logDescription ?? "?")")
                        }
                        watchFlow(c)
                        onVideoPathOpen?()
                    }
                    if isPeer, let s {
                        // The echo: tells the viewer this path works both ways, even when no video is flowing.
                        var w = Writer()
                        w.u8(Wire.Datagram.helloEcho.rawValue)
                        w.u32(s)
                        c.send(content: w.data, completion: .contentProcessed { [weak self] err in if let err { self?.sendFailed(err, on: c) } })
                    }
                } else {
                    sendLegacyFrame(on: c) // a protocol-1 viewer's 1-byte hello
                }
            }
            if let err { Log.debug(.net, "UDP flow from \(c.endpoint) ended: \(err.logDescription)"); return }
            receiveHello(c)
        }
    }

    /// Logs the video flow's state changes (it used to fail silently: sends then go nowhere).
    private func watchFlow(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            lock.lock(); let current = udpPeer === c; lock.unlock()
            switch st {
            case .failed, .waiting:
                Log.warning(.net, "video path (UDP) to \(c.endpoint) \(st.logDescription)"
                    + (current ? ": video can't reach the viewer until it sends a hello from a new flow" : " (no longer used)"))
            case .cancelled: Log.debug(.net, "video path (UDP) to \(c.endpoint) cancelled")
            default: Log.debug(.net, "video path (UDP) to \(c.endpoint) \(st.logDescription)")
            }
        }
    }

    func sendControl(_ d: Data) {
        lock.lock(); let c = viewer; lock.unlock()
        bytesOut.add(d.count)
        c?.send(content: d, completion: .idempotent)
    }

    /// A control message, with `done` called once it has left (or at once if there's no viewer): for
    /// bulk data (the clipboard) that must not pile up in front of everything else.
    func sendControl(_ d: Data, done: @escaping () -> Void) {
        lock.lock(); let c = viewer; lock.unlock()
        guard let c else { done(); return }
        bytesOut.add(d.count)
        c.send(content: d, completion: .contentProcessed { _ in done() })
    }

    /// Forgets a stream's frame numbers and resend cache (it was closed).
    func dropStream(_ s: UInt16) { lock.lock(); tx[s] = nil; lock.unlock() }

    /// Splits one encoded frame of stream `s` into datagrams that each fit inside Tailscale's MTU.
    func sendFrame(stream s: UInt16, tag: FrameTag, body: Data, isKey: Bool) {
        var w = Writer()
        tag.write(&w)
        w.bytes(body)
        let payload = w.data
        lock.lock()
        guard let c = udpPeer else { lock.unlock(); return }
        var t = tx[s] ?? Tx()
        t.frameNo &+= 1
        let n = t.frameNo
        let chunks = (payload.count + Wire.maxChunkPayload - 1) / Wire.maxChunkPayload
        let packets = (0 ..< chunks).map { i -> Data in
            var w = Writer()
            w.u8(Wire.Datagram.video.rawValue)
            w.u16(s)
            w.u32(n)
            w.u16(UInt16(i))
            w.u16(UInt16(chunks))
            let lo = i * Wire.maxChunkPayload
            w.bytes(payload[lo ..< min(lo + Wire.maxChunkPayload, payload.count)])
            return w.data
        }
        t.cache[n] = packets
        t.order.append(n)
        if t.order.count > cacheFrames { t.cache[t.order.removeFirst()] = nil }
        t.lastSentAt = nowMicros()
        tx[s] = t
        streamFrames[s, default: 0] += 1
        streamFramesTotal[s, default: 0] += 1
        lock.unlock()
        transmit(packets + parity(for: payload, stream: s, frame: n, chunks: chunks), on: c)
        framesOut.add(1)
        if isKey { keyframesOut.add(1) }
    }

    /// One XOR parity packet per group of `fecGroup` chunks, sent after the frame's data.
    private func parity(for payload: Data, stream s: UInt16, frame n: UInt32, chunks: Int) -> [Data] {
        guard fecGroup > 0 else { return [] }
        let size = Wire.maxChunkPayload
        return stride(from: 0, to: chunks, by: fecGroup).map { first in
            var acc = [UInt8](repeating: 0, count: size)
            for i in first ..< min(first + fecGroup, chunks) {
                xorInto(&acc, payload[i * size ..< min((i + 1) * size, payload.count)])
            }
            var w = Writer()
            w.u8(Wire.Datagram.parity.rawValue)
            w.u16(s)
            w.u32(n)
            w.u16(UInt16(first / fecGroup))
            w.u16(UInt16(chunks))
            w.u8(UInt8(fecGroup))
            w.u32(UInt32(payload.count))
            w.bytes(Data(acc))
            return w.data
        }
    }

    private func resend(_ s: UInt16, _ r: Reader) {
        var r = r
        guard let n = r.u32(), let count = r.u16() else { return }
        lock.lock()
        let c = udpPeer, packets = tx[s]?.cache[n]
        var tooOld = false
        if tx[s] != nil {
            tx[s]!.nacksServed += 1
            if let packets { tx[s]!.packetsResent += count == 0xFFFF ? packets.count : Int(count) } else { tx[s]!.nacksMissed += 1 }
            // A frame no longer cached can't be repaired: the viewer waits for a keyframe, so send one now
            // (at most one a second) rather than after its own timeout.
            if packets == nil, n < tx[s]!.frameNo, nowMicros() - tx[s]!.lastTooOldKey > 1_000_000 { tx[s]!.lastTooOldKey = nowMicros(); tooOld = true }
        }
        lock.unlock()
        if tooOld {
            Log.debug(.net, "stream #\(s): NACK for frame #\(n), no longer cached: sending a keyframe")
            onKeyframeRequest?(s)
        }
        guard let c, let packets else { return }
        var out: [Data] = []
        if count == 0xFFFF {
            out = packets
        } else {
            for _ in 0 ..< count {
                if let i = r.u16(), Int(i) < packets.count { out.append(packets[Int(i)]) }
            }
        }
        resent.add(out.count)
        lossSignal.add(out.count)
        transmit(out, on: c)
    }

    private func transmit(_ packets: [Data], on c: NWConnection) {
        let queued = nowMicros()
        lock.lock(); pacerQueued += packets.count; pacerPeak = max(pacerPeak, pacerQueued); lock.unlock()
        pacer.async { [self] in
            defer {
                let waited = nowMicros() - queued
                pacingDelay.add(Int64(waited))
                lock.lock(); pacerQueued -= packets.count; pacerMaxWait = max(pacerMaxWait, waited); lock.unlock()
            }
            for pkt in packets {
                let now = CACurrentMediaTime()
                sendClock = max(sendClock, now - burstSeconds) + Double(pkt.count) / bytesPerSecond
                if sendClock > now { usleep(useconds_t((sendClock - now) * 1_000_000)) }
                bytesOut.add(pkt.count)
                c.send(content: pkt, completion: .contentProcessed { [weak self] err in if let err { self?.sendFailed(err, on: c) } })
            }
        }
    }

    // The send path, for the health checks. Under lock.
    private var pacerQueued = 0, pacerPeak = 0
    private var pacerMaxWait: UInt64 = 0
    private var sendErrors = 0
    private var lastSendError: String?
    private var sendErrorsLoggedAt: UInt64 = 0, sendErrorsSinceLog = 0

    /// A UDP send failed (it used to be invisible): a warning at most every 5 s, with the count since.
    private func sendFailed(_ err: NWError, on c: NWConnection) {
        let now = nowMicros()
        lock.lock()
        sendErrors += 1
        sendErrorsSinceLog += 1
        lastSendError = err.logDescription
        let due = now - sendErrorsLoggedAt > 5_000_000
        let n = sendErrorsSinceLog
        if due { sendErrorsLoggedAt = now; sendErrorsSinceLog = 0 }
        lock.unlock()
        if due { Log.warning(.net, "UDP send to \(c.endpoint) failed: \(err.logDescription) (\(n) failed sends since the last such line; flow \(c.state.logDescription))") }
    }

    /// The send path, for the health line: the UDP peer, the pacer's backlog, send errors.
    struct NetHealth {
        var peer: String?
        var peerState: String?
        var queued = 0, peak = 0
        var maxWait: UInt64 = 0
        var sendErrors = 0
        var lastSendError: String?
        var description: String {
            "UDP peer \(peer ?? "none")\(peerState.map { " (\($0))" } ?? ""), pacer backlog \(queued) pkts (peak \(peak)), longest pacer wait "
                + String(format: "%.0f ms", Double(maxWait) / 1000) + ", send errors \(sendErrors)\(lastSendError.map { " (last: \($0))" } ?? "")"
        }
    }
    /// Takes the pacer's peak backlog and longest wait since the last call.
    func takeNetHealth() -> NetHealth {
        lock.lock(); defer { pacerPeak = pacerQueued; pacerMaxWait = 0; lock.unlock() }
        return NetHealth(peer: udpPeer.map { "\($0.endpoint)" }, peerState: udpPeer?.state.logDescription, queued: pacerQueued, peak: pacerPeak,
                         maxWait: pacerMaxWait, sendErrors: sendErrors, lastSendError: lastSendError)
    }
    /// Stream `s`'s send side: NACKs served (and those for frames no longer cached), packets resent, last frame sent (µs).
    func streamNet(_ s: UInt16) -> (nacks: Int, missed: Int, resent: Int, lastSent: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let t = tx[s]
        return (t?.nacksServed ?? 0, t?.nacksMissed ?? 0, t?.packetsResent ?? 0, t?.lastSentAt ?? 0)
    }

    // MARK: Protocol-1 viewers

    /// A protocol-1 viewer understands only its old windowInfo and video, so it gets a window titled
    /// with the problem, and (once its UDP hello arrives) a video frame that says the same. It is
    /// disconnected after 30 s. It never becomes the viewer, so a connected viewer is undisturbed.
    private func startLegacy(_ c: NWConnection, why: String) {
        Log.warning(.host, "viewer \(c.endpoint) runs an older \(Brand.name) (protocol 1: \(why)); this host needs protocol \(Wire.protocolVersion). "
            + "Update \(Brand.name) on that Mac to the same version as this one. Telling it so, then disconnecting it in 30 s.")
        notice.prepare()
        let title = notice.text
        c.send(content: WindowInfo(points: CGSize(width: 640, height: 160), pixels: LegacyNotice.pixels, title: title, requestID: nil).encodeV1(),
               completion: .idempotent)
        legacy[ObjectIdentifier(c)] = (c, Self.hostKey(c.endpoint), 0)
        q.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.legacy[ObjectIdentifier(c)] = nil
            c.cancel()
        }
    }

    private func sendLegacyFrame(on udp: NWConnection) {
        let host = Self.hostKey(udp.endpoint)
        guard let (key, entry) = legacy.first(where: { $0.value.host == host }), let body = notice.body else { return }
        let n = entry.frameNo &+ 1
        legacy[key]?.frameNo = n
        var w = Writer()
        FrameTag(stream: 0, encodedAt: nowMicros(), inputsApplied: 0, refinement: false).writeV1(&w)
        w.bytes(body)
        let payload = w.data
        let chunks = (payload.count + Wire.maxChunkPayload - 1) / Wire.maxChunkPayload
        for i in 0 ..< chunks {
            var d = Writer()
            d.u8(Wire.Datagram.videoV1.rawValue); d.u32(n); d.u16(UInt16(i)); d.u16(UInt16(chunks))
            let lo = i * Wire.maxChunkPayload
            d.bytes(payload[lo ..< min(lo + Wire.maxChunkPayload, payload.count)])
            udp.send(content: d.data, completion: .idempotent)
        }
    }

    /// The IP address of an endpoint, without port, scope or IPv4-mapped prefix.
    private static func hostKey(_ e: NWEndpoint) -> String {
        guard case .hostPort(let h, _) = e else { return "\(e)" }
        var s = "\(h)"
        if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }
}

/// The "please update" frame for protocol-1 viewers: the sentence drawn on a plain background, encoded
/// once as an H.264 keyframe (any protocol-1 viewer decodes it).
final class LegacyNotice {
    static let pixels = CGSize(width: 1280, height: 320)
    let text: String
    private let lock = NSLock()
    private var encoded: Data?
    private var encoder: Encoder?
    init(text: String) { self.text = text }

    /// The frame after its tag, once encoded.
    var body: Data? { lock.lock(); defer { lock.unlock() }; return encoded }

    func prepare() {
        lock.lock()
        guard encoded == nil, encoder == nil else { lock.unlock(); return }
        let w = Int(Self.pixels.width), h = Int(Self.pixels.height)
        guard let enc = Encoder(width: w, height: h, preferHEVC: false, kbps: 2000, fps: 1, label: " (update notice)"),
              let pb = drawText(text, width: w, height: h) else { lock.unlock(); return }
        enc.onFrame = { [weak self] _, body, _ in
            guard let self else { return }
            lock.lock(); encoded = body; lock.unlock()
            DispatchQueue.main.async { self.lock.lock(); self.encoder = nil; self.lock.unlock() }
        }
        encoder = enc
        lock.unlock()
        enc.encode(pb, forceKey: true, tag: FrameTag(stream: 0, encodedAt: nowMicros(), inputsApplied: 0, refinement: false))
    }
}

/// A BGRA pixel buffer with `text` centred on a light background (2 px per point).
func drawText(_ text: String, width: Int, height: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold),
                                                .foregroundColor: NSColor.black, .paragraphStyle: style]
    let box = CGRect(x: 40, y: 0, width: CGFloat(width) - 80, height: CGFloat(height))
    let need = (text as NSString).boundingRect(with: box.size, options: [.usesLineFragmentOrigin], attributes: attrs)
    (text as NSString).draw(with: CGRect(x: box.minX, y: (CGFloat(height) - need.height) / 2, width: box.width, height: need.height),
                            options: [.usesLineFragmentOrigin], attributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return pb
}

// MARK: - Pipeline: capture -> encode -> send, one per stream

final class Pipeline {
    let stream: UInt16
    let q: DispatchQueue
    private let opts: HostOptions
    private let server: Server
    private var encoder: Encoder? { didSet { lock.lock(); encoderRef = encoder; lock.unlock() } }
    private var lastBuffer: CVPixelBuffer?
    private var lastInjectSeen: UInt64 = 0
    private var forceKey = true
    private var refineLeft = 0
    private var refineItem: DispatchWorkItem?
    private var stopped = false
    private var kbps: Int? // current target (this stream's share of the budget)
    /// The encoder stopped answering (frames in flight too long) or broke; on q.
    private lazy var encoderStall = StallEpisode("stream #\(stream) encoder", .encode)
    private var lastEncoderReset: Date? // on q

    private let lock = NSLock()
    private var on = false
    private var changedAt: UInt64 = 0
    /// What went through this pipeline, for the health checks (Host/Health.swift). Under lock.
    private var counts = Counts()
    private var encoderRef: Encoder? // the encoder, for other queues
    private var stoppedFlag = false

    struct Counts {
        var captured = 0, submitted = 0, skippedBusy = 0, refinements = 0, forcedKeys = 0, sent = 0, encoderResets = 0, encoderRebuilds = 0
        var lastCaptureAt: UInt64 = 0, lastSentAt: UInt64 = 0, lastSubmitAt: UInt64 = 0
        /// Clicks and key presses received for this stream by the time of the last captured frame.
        var pressesAtLastCapture: UInt32 = 0
    }

    init(stream: UInt16, opts: HostOptions, server: Server) {
        self.stream = stream
        self.opts = opts
        self.server = server
        q = DispatchQueue(label: "wisp.pipe.\(stream)", qos: .userInteractive)
        HostHealth.shared.add(self, server: server)
    }

    /// The viewer has this stream open, so its frames are encoded and sent.
    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }
    /// When the window last really changed (µs), for the bitrate split; 0 = never.
    var lastChange: UInt64 { lock.lock(); defer { lock.unlock() }; return changedAt }
    /// The counters so far. Any queue.
    var snapshot: Counts { lock.lock(); defer { lock.unlock() }; return counts }
    /// The encoder's in-flight state, for the health line. Any queue (the encoder is replaced on q,
    /// so this may describe the previous one for a moment).
    var encoderSummary: String { lock.lock(); let e = encoderRef; lock.unlock(); return e?.summary ?? "no encoder" }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stoppedFlag }

    private func count(_ f: (inout Counts) -> Void) { lock.lock(); f(&counts); lock.unlock() }

    func setBitrate(kbps: Int) {
        q.async {
            guard self.kbps != kbps else { return }
            self.kbps = kbps
            self.encoder?.setBitrate(kbps: kbps)
        }
    }

    func stop() {
        enabled = false
        lock.lock(); stoppedFlag = true; lock.unlock()
        q.async { self.stopped = true; self.refineItem?.cancel(); self.encoder = nil; self.lastBuffer = nil }
    }

    /// Called on `q` for every changed frame from the capture source.
    func push(_ pb: CVPixelBuffer, capturedAt: UInt64) {
        guard !stopped else { return }
        let presses = server.pressesReceived(stream)
        count { $0.captured += 1; $0.lastCaptureAt = nowMicros(); $0.pressesAtLastCapture = presses }
        lastBuffer = pb
        refineLeft = opts.refine
        if enabled { lock.lock(); changedAt = nowMicros(); lock.unlock() }
        // First frame composited after an injected input: that gap is the app's own reaction time.
        var appRender: UInt64 = 0
        let injected = server.lastInjectAt(stream)
        if injected > lastInjectSeen, capturedAt > injected {
            appRender = capturedAt - injected
            lastInjectSeen = injected
        }
        encode(pb, refinement: false, capturedAt: capturedAt, appRender: appRender)
        scheduleRefine()
    }

    private static let thumbnailContext = CIContext(options: [.cacheIntermediates: false])

    /// The latest captured frame, scaled down to `width` pixels wide, for the host window's cards.
    /// `done` runs on the main queue (nil before the first frame).
    func thumbnail(width: CGFloat, _ done: @escaping (CGImage?) -> Void) {
        q.async {
            guard let pb = self.lastBuffer else { DispatchQueue.main.async { done(nil) }; return }
            let img = CIImage(cvPixelBuffer: pb)
            let s = min(1, width / max(1, img.extent.width))
            let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let cg = Self.thumbnailContext.createCGImage(scaled, from: scaled.extent)
            DispatchQueue.main.async { done(cg) }
        }
    }

    func requestKeyframe() {
        q.async {
            self.forceKey = true
            if let pb = self.lastBuffer { self.encode(pb, refinement: true) } // window may be idle: don't wait for a change
        }
    }

    private func makeEncoder(width w: Int, height h: Int) {
        encoder = Encoder(width: w, height: h, preferHEVC: opts.hevc, kbps: kbps ?? opts.kbps, fps: opts.fps, label: " #\(stream)")
        encoder?.onFrame = { [weak self, server, stream] tag, body, key in
            server.sendFrame(stream: stream, tag: tag, body: body, isKey: key)
            guard let self else { return }
            count { $0.sent += 1; $0.lastSentAt = nowMicros() }
            q.async { if self.encoderStall.active { self.encoderStall.end("the encoder's output resumed\(key ? " with a keyframe" : "")") } }
        }
        encoder?.onDroppedKey = { [weak self] in self?.q.async { self?.forceKey = true } }
        forceKey = true
    }

    /// The encoder lost frames (VideoToolbox never called back for them: the pipeline would skip every
    /// later frame as "busy" forever) or broke (its session was invalidated). On q.
    private func recoverEncoder(_ e: Encoder, why: String, stuckFor: Double = 0, w: Int, h: Int) {
        let detail = e.summary
        encoderStall.begin("\(why); \(detail)", at: Date(timeIntervalSinceNow: -stuckFor))
        Log.debug(.encode, "stream #\(stream) encoder stall detail: \(detail); \(snapshot)")
        let recent = lastEncoderReset.map { Date().timeIntervalSince($0) < 30 } ?? false
        if e.broken || recent {
            e.markWedged()
            makeEncoder(width: w, height: h)
            count { $0.encoderRebuilds += 1 }
            encoderStall.act(e.broken ? "made a new encoder (the old session is broken), keyframe forced"
                                      : "made a new encoder (stuck again \(Int(Date().timeIntervalSince(lastEncoderReset!).rounded())) s after the last recovery), keyframe forced")
        } else {
            e.forgetInFlight()
            count { $0.encoderResets += 1 }
            forceKey = true
            encoderStall.act("forgot the lost frames (in-flight count reset), keyframe forced")
        }
        lastEncoderReset = Date()
    }

    /// False if the frame was skipped because the encoder is still busy with earlier ones.
    @discardableResult
    private func encode(_ pb: CVPixelBuffer, refinement: Bool, capturedAt: UInt64 = 0, appRender: UInt64 = 0) -> Bool {
        guard !stopped, enabled, server.hasViewer else { return true }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if encoder?.width != w || encoder?.height != h { makeEncoder(width: w, height: h) }
        if let e = encoder, e.broken { recoverEncoder(e, why: "the encoder's session is broken (invalidated, or 10 frames in a row failed)", w: w, h: h) }
        // The media engine is shared by every stream. When it falls behind, queueing more frames only
        // adds latency: skip this one (a keyframe is never skipped); the next change or the refinement
        // pass after the window goes still brings the latest pixels. Frames stuck in flight for over a
        // second were lost by VideoToolbox: without a reset, every later frame would be skipped.
        if let e = encoder, e.inFlight >= 2 {
            let waited = e.oldestInFlightAge
            if waited > 1 {
                recoverEncoder(e, why: String(format: "%d frames in flight for %.1f s, every new frame skipped as busy", e.inFlight, waited), stuckFor: waited, w: w, h: h)
            } else if !forceKey {
                Encoder.skipped.add(1)
                count { $0.skippedBusy += 1 }
                return false
            }
        }
        let now = nowMicros()
        var tag = FrameTag(stream: stream, encodedAt: now, inputsApplied: server.inputsApplied(stream), refinement: refinement)
        if capturedAt > 0, now > capturedAt { tag.captureLag = UInt32(clamping: now - capturedAt) }
        tag.appRender = UInt32(clamping: appRender)
        let key = forceKey
        count { $0.submitted += 1; $0.lastSubmitAt = now; if refinement { $0.refinements += 1 }; if key { $0.forcedKeys += 1 } }
        encoder?.encode(pb, forceKey: key, tag: tag)
        forceKey = false
        return true
    }

    /// At a low bitrate the first frame after a change is a little soft. When the window
    /// goes still, re-send the same pixels a few times: each pass is a tiny delta that
    /// sharpens the text, then we go fully silent.
    private func scheduleRefine() {
        refineItem?.cancel()
        guard refineLeft > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let pb = self.lastBuffer else { return }
            if self.encode(pb, refinement: true) { self.refineLeft -= 1 } // skipped (encoder busy): try again
            self.scheduleRefine()
        }
        refineItem = item
        // First pass soon after motion stops (text sharp within ~50 ms), then slower ones.
        q.asyncAfter(deadline: .now() + (refineLeft == opts.refine ? 0.05 : 0.15), execute: item)
    }
}

// MARK: - Stats log

/// Appends the viewer's reports to ~/Library/Logs/<Brand.name>/stats.csv (wherever the app was launched from).
enum StatsLog {
    static let stageNames = ["capture", "encode", "network", "decode", "display", "total", "app"]

    static func append(_ s: ViewerStats, from: String) {
        func v(_ x: UInt16) -> String { x == 0xFFFF ? "" : "\(x)" }
        var cols = [ISO8601DateFormatter().string(from: Date()), from, v(s.rttMin), v(s.rttAvg), v(s.videoP50), v(s.videoP95),
                    v(s.inputP50), v(s.inputP95), "\(s.inputSamples)", "\(s.fps)"]
        for name in stageNames {
            let st = s.stages.first { $0.name == name }
            cols += [v(st?.p50 ?? 0xFFFF), v(st?.p95 ?? 0xFFFF)]
        }
        let header = (["time", "viewer", "rtt_min_ms", "rtt_avg_ms", "video_p50_ms", "video_p95_ms", "click_p50_ms",
                       "click_p95_ms", "click_samples", "fps"] + stageNames.flatMap { ["\($0)_p50_ms", "\($0)_p95_ms"] })
            .joined(separator: ",")
        LogFile.append("stats.csv", cols.joined(separator: ","), header: header)
    }
}

// MARK: - Helpers

func cgBounds(of id: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[CFString: Any]],
          let dict = list.first?[kCGWindowBounds] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dict)
}

func even(_ v: Double) -> Double { (v / 2).rounded() * 2 } // encoders want even dimensions
