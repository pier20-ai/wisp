// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import WispCommon

// The local channel between the main Wisp process (which holds the one connection to the host) and
// its phantom apps (which own the windows): a Unix domain socket, one connection per phantom.
// Each message: [u32 length][u8 type][payload], length = 1 + payload bytes. Private to one Mac and
// one build (a phantom runs a copy of Wisp's own binary), so there is no versioning.

enum PhantomMsg: UInt8 {
    // phantom -> Wisp
    case hello = 1          // str host, str appKey, u32 pid
    case input = 2          // u16 stream, u8 discrete, a complete host input message (u16-length framed)
    case resize = 3         // u16 stream, u16 w, u16 h, u32 requestID
    case closeStream = 4    // u16 stream: stop viewing it (the window stays open on the host)
    case closeRemote = 5    // u16 stream: close the window on the host
    case openWindow = 6     // u32 windowID (0 = this app's frontmost remote window)
    case screen = 7         // u32 CGDirectDisplayID, u16 visible w, u16 visible h (points), u8 scale
    case frameTiming = 8    // FrameTag, u64 reassembled, u64 relayed, u64 decodeStart, u64 decoded, u64 displayed (0 = just decoded)
    case decodeFailed = 9   // u16 stream: needs a keyframe
    case bye = 10           // (empty) quitting: its streams are closed already
    case toHost = 11        // a complete host control message (u16-length framed), passed on as is. Only
                            // menuRequest and menuPress (for this phantom's app) are let through.

    // Wisp -> phantom
    case helloAck = 100     // u8 ok, str hostName, str message (why not, when !ok)
    case streamOpen = 101   // u16 stream, u32 windowID: a window for it follows
    case host = 102         // a host message about one stream, as the host sent it (windowInfo, windowChrome,
                            // windowGone, streamClosed), u16-length framed
    case frame = 103        // u16 stream, u64 reassembled (µs), a complete frame from FrameTag onwards
    case stats = 104        // u16 stream, str line for the title
    case connection = 105   // str (empty = connected): connection trouble
    case hostStatus = 106   // str (empty = all clear)
    case windows = 107      // this app's remote windows: a host windowList message (u16-length framed)
    case notice = 108       // str: e.g. the host refused to open another window (its stream limit)
    case focus = 109        // u16 stream: bring its window to the front
    case stopViewing = 110  // u16 stream: close its window here (test hook; the stream ends)
    case icon = 111         // PNG: a new Dock icon (the remote app's icon changed)
    case quit = 112         // (empty) Wisp is disconnecting: close everything and quit
    case expect = 113       // (empty) a window is on its way: a Dock reopen right now is Wisp activating
                            // the phantom, not the user asking for a window
    case menu = 114         // a host menuTree message for this app (u16-length framed), as the host sent it
}

/// Where Wisp listens for its phantoms. Short enough for sun_path (104 bytes).
enum PhantomPaths {
    static let support = Brand.supportDirectory
    /// WISP_SOCKET overrides it, so a test can run beside a Wisp that's in use (phantoms inherit WISP_*).
    static let socket = ProcessInfo.processInfo.environment["WISP_SOCKET"] ?? support.appendingPathComponent("run/viewer.sock").path
    static let phantoms = support.appendingPathComponent("Phantoms")
}

/// One end of a phantom connection: framing, and a serial queue on which messages arrive.
final class IPCConnection {
    let queue: DispatchQueue
    private let conn: NWConnection
    private var buf = Data()
    /// Each message, on `queue`.
    var onMessage: ((PhantomMsg, Data) -> Void)?
    /// Once, on `queue`, when the connection fails or closes.
    var onClose: (() -> Void)?
    /// When the connection comes up (outgoing connections), on `queue`.
    var onReady: (() -> Void)?
    private var closed = false
    private let label: String
    /// Too many to log, even at debug: video frames and their timings, pointer input, stats.
    private static let chatty: Set<PhantomMsg> = [.frame, .frameTiming, .input, .stats]

    init(_ conn: NWConnection, label: String) {
        self.conn = conn
        self.label = label
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// An outgoing connection to Wisp's socket.
    convenience init(path: String, label: String) {
        self.init(NWConnection(to: .unix(path: path), using: .tcp), label: label)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            Log.debug(.ipc, "\(label): \(st.logDescription)")
            switch st {
            case .ready: onReady?()
            case .failed, .cancelled, .waiting: close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func cancel() { conn.cancel() }

    private func close() {
        guard !closed else { return }
        closed = true
        Log.debug(.ipc, "\(label): closed")
        conn.cancel()
        onClose?()
        onClose = nil
        onMessage = nil
    }

    func send(_ type: PhantomMsg, _ build: (inout Writer) -> Void = { _ in }, completion: (() -> Void)? = nil) {
        var w = Writer()
        w.u32(0)
        w.u8(type.rawValue)
        build(&w)
        var d = w.data
        let len = UInt32(d.count - 4)
        // The length prefix, big-endian (subscripts rather than withUnsafeMutableBytes, which Swift
        // 6.3 finds ambiguous here).
        let i = d.startIndex
        d[i] = UInt8(len >> 24); d[i + 1] = UInt8(len >> 16 & 0xff); d[i + 2] = UInt8(len >> 8 & 0xff); d[i + 3] = UInt8(len & 0xff)
        if !Self.chatty.contains(type) { Log.debug(.ipc, "\(label) → \(type) (\(len - 1) B)") }
        let frame = type == .frame
        if frame { queueLock.lock(); queued += 1; queueLock.unlock() }
        conn.send(content: d, completion: .contentProcessed { [weak self, label] err in
            if let err { Log.debug(.ipc, "\(label): sending \(type) failed: \(err.logDescription)") }
            if frame, let self { queueLock.lock(); queued -= 1; queueLock.unlock() }
            completion?()
        })
    }

    private let queueLock = NSLock()
    private var queued = 0
    /// Video frames handed to the socket that the other side hasn't taken yet (a phantom that stopped
    /// reading lets them pile up). Any queue.
    var framesQueued: Int { queueLock.lock(); defer { queueLock.unlock() }; return queued }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { buf.append(data); parse() }
            if let err { Log.debug(.ipc, "\(label): receive failed: \(err.logDescription)") }
            if done || err != nil { close(); return }
            receive()
        }
    }

    private func parse() {
        var pos = buf.startIndex
        while buf.endIndex - pos >= 4 {
            let len = Int(buf[pos]) << 24 | Int(buf[pos + 1]) << 16 | Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
            guard len >= 1, len < 64 << 20 else { Log.error(.ipc, "\(label): bad message length \(len): closing"); close(); return }
            guard buf.endIndex - pos >= 4 + len else { break }
            let type = buf[pos + 4]
            let body = buf.subdata(in: pos + 5 ..< pos + 4 + len)
            pos += 4 + len
            if let t = PhantomMsg(rawValue: type) {
                if !Self.chatty.contains(t) { Log.debug(.ipc, "\(label) ← \(t) (\(body.count) B)") }
                onMessage?(t, body)
            } else {
                Log.debug(.ipc, "\(label) ← unknown message type \(type) (\(body.count) B): ignored")
            }
        }
        buf = pos == buf.endIndex ? Data() : buf.subdata(in: pos ..< buf.endIndex)
    }
}

/// Wisp's listening socket for its phantoms.
final class IPCListener {
    private let listener: NWListener
    var onConnection: ((IPCConnection) -> Void)?
    private var count = 0

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if unlink(path) == 0 { Log.info(.ipc, "removed a socket left by an earlier \(Brand.name): \(path)") } // a socket left by an earlier Wisp
        if path.utf8.count >= 104 { Log.error(.ipc, "the socket path is \(path.utf8.count) bytes, longer than a Unix socket allows (103): \(path)") }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            count += 1
            let conn = IPCConnection(c, label: "wisp.phantom-link.\(count)")
            Log.debug(.ipc, "phantom connection #\(count) accepted")
            onConnection?(conn)
            conn.start()
        }
        listener.stateUpdateHandler = { st in
            switch st {
            case .failed, .waiting: Log.error(.ipc, "phantom socket listener \(st.logDescription)")
            default: Log.debug(.ipc, "phantom socket listener \(st.logDescription)")
            }
        }
        listener.start(queue: DispatchQueue(label: "wisp.phantom-listener"))
    }

    func stop() { listener.cancel() }
}

extension Writer {
    mutating func timing(_ t: FrameTiming, displayed: UInt64) {
        t.tag.write(&self)
        u64(t.reassembled); u64(t.relayed); u64(t.decodeStart); u64(t.decoded); u64(displayed)
    }
}

extension Reader {
    mutating func timing() -> (FrameTiming, displayed: UInt64)? {
        guard let tag = FrameTag.read(&self), let re = u64(), let rel = u64(), let ds = u64(), let dec = u64(), let disp = u64() else { return nil }
        var t = FrameTiming(tag: tag, decodeStart: ds, reassembled: re, relayed: rel)
        t.decoded = dec
        return (t, disp)
    }
}
