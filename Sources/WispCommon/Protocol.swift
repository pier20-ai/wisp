// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

// Wire protocol shared by `wisp send` (the host, the Mac being controlled) and `wisp view`.
// Protocol version 2: several windows ("streams") at once. See docs/multi-window.md §2.
//
// Two channels:
//   TCP 7878  control + input. Tiny, must be reliable and ordered (a lost mouse-up is bad).
//             Each message: [u16 length][u8 type][payload], length = 1 + payload bytes.
//             The viewer's first message is `hello`; the host answers `helloAck`. Every message about
//             one window (MsgType.isPerStream) starts with that window's u16 stream ID.
//   UDP 7879  video only. A lost packet never stalls anything: the viewer asks for the missing
//             packets (nack), or for a keyframe of that stream only.
//             Each datagram: [u8 kind=3][u16 stream][u32 frameNo][u16 chunkIndex][u16 chunkCount][bytes]
//             Parity (FEC):  [u8 kind=4][u16 stream][u32 frameNo][u16 group][u16 chunkCount][u8 groupSize][u32 frameLen][xor]
//             frameNo counts per stream. XOR of up to groupSize consecutive chunks (zero-padded): recovers
//             any one lost chunk of that group without waiting a round trip for a resend.
//             The viewer's datagram hello is [u8 kind=1][u32 session from helloAck], once a second.
//             The host answers each one from its current viewer with [u8 kind=5][u32 session]
//             (helloEcho): it tells the viewer the video path works both ways even while every window
//             is idle (no video). Older viewers ignore it; a viewer that never gets one (an older host)
//             doesn't judge the path by it.
//
// A video frame (before chunking) is: [FrameTag][u8 flags][param sets if keyframe][AVCC sample data]
//   flags bit0 = keyframe, bit1 = HEVC (else H.264)
//   param sets = [u8 count] then count x ([u16 len][bytes])
//
// Protocol 1 (one window, no stream IDs, datagram kinds 0 and 2) is not served. A protocol-1 viewer
// gets a window titled with an "update Wisp" message and a video frame that says the same; a
// protocol-2 viewer that reaches a protocol-1 host notices (windowInfo arrives before helloAck) and
// says so.

public enum Wire {
    public static let tcpPort: UInt16 = 7878
    public static let udpPort: UInt16 = 7879
    /// Tailscale's MTU is 1280; keep every datagram well under it so nothing fragments.
    public static let maxChunkPayload = 1100
    /// This build's protocol version (sent in hello / helloAck / sideChannel).
    public static let protocolVersion: UInt16 = 2

    /// Bits of hello's `features`: what this viewer can do beyond protocol 2 itself.
    public enum Feature {
        /// The host may open a stream unasked when an app the viewer is showing opens a new window
        /// (and say `newWindowHeld` when it can't). Without it the host never does.
        public static let followsNewWindows: UInt32 = 1 << 0
        /// Clipboard sync (the clipboard* messages). Sent in hello by a viewer and in helloAck by a host
        /// that can sync; each side sends clipboard messages only to a peer that announced it.
        public static let clipboard: UInt32 = 1 << 1

        /// "0x1 (followsNewWindows)", for the log.
        public static func describe(_ bits: UInt32) -> String {
            var names: [String] = []
            if bits & followsNewWindows != 0 { names.append("followsNewWindows") }
            if bits & clipboard != 0 { names.append("clipboard") }
            let unknown = bits & ~(followsNewWindows | clipboard)
            if unknown != 0 { names.append("unknown 0x\(String(unknown, radix: 16))") }
            return "0x\(String(bits, radix: 16))" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
        }
    }

    public enum Datagram: UInt8 {
        case videoV1 = 0  // protocol 1: [u8 0][u32 frameNo][u16 chunkIndex][u16 chunkCount][bytes]
        case hello = 1    // viewer -> host, also serves as keepalive. Protocol 2 appends u32 session.
        case parityV1 = 2 // protocol 1
        case video = 3
        case parity = 4
        case helloEcho = 5 // host -> viewer: [u8 5][u32 session], the answer to each UDP hello
    }
}

/// Why a stream ended (streamClosed).
public enum StreamCloseReason: UInt8 {
    case asked = 0       // the viewer closed it
    case windowGone = 1  // the window was closed on the host (or its app quit)
    case replaced = 2    // the host operator chose another window to share instead
    case limit = 3       // too many streams open
    case failed = 4      // the window doesn't exist or couldn't be captured

    public var text: String {
        switch self {
        case .asked: "closed"
        case .windowGone: "the window was closed on the host"
        case .replaced: "the host shares another window now"
        case .limit: "too many windows are open at once"
        case .failed: "the window isn't available on the host"
        }
    }
}

public enum MsgType: UInt8 {
    // viewer -> host. "stream" = u16 stream ID, first in the payload.
    case mouseMove = 1        // stream, u16 x, u16 y            (normalised 0...65535 across the window)
    case mouseDrag = 2        // stream, u8 button, u16 x, u16 y
    case mouseDown = 3        // stream, u8 button, u8 clicks, u16 x, u16 y
    case mouseUp = 4          // stream, u8 button, u8 clicks, u16 x, u16 y
    case scroll = 5           // stream, i16 dx, i16 dy (points), u8 phase, u8 momentumPhase (NSEvent.Phase raw; 0 = wheel),
                              // then (since the e2e harness; older hosts ignore them) u8 flags (bit 0: dx, dy are 1/16
                              // lines, from a wheel: the host posts a line scroll), u16 x, u16 y (the pointer, as in
                              // mouseMove: the host scrolls there). Older viewers' scrolls are points at the last move.
    case key = 6              // stream, u16 virtual keycode, u8 down, u32 modifier flags (goes to that stream's window)
    case keyframeRequest = 7  // stream
    case nack = 8             // stream, u32 frameNo, u16 n, n x u16 chunk index  (n = 0xFFFF: resend whole frame)
    case ping = 9             // u32 seq
    case stats = 10           // viewer's measurements every 5 s, see ViewerStats
    case windowListRequest = 11 // (empty) the host answers with appIcon messages, then windowList
    case viewerScreen = 13    // u16 pointW, u16 pointH, u8 backingScale: the viewer's usable screen area
                              // (visibleFrame). Sent on connect and when it changes; the host sizes a
                              // HiDPI virtual display to it.
    case resizeWindow = 14    // stream, u16 pointW, u16 pointH, u32 requestID: the user resized that viewer window;
                              // the host sets the shared window to that size (the app may clamp it).
    case sideChannel = 15     // u16 version, as the FIRST message: a control-only connection (`wisp poke`). The host
                              // keeps its current viewer and only takes input, resizeWindow and windowAction from it.
                              // Stream 0 on it means the host's primary stream.
    case windowAction = 16    // stream, u8 action (1 = close): done through Accessibility on the host. A click on the
                              // remote close button can't work: macOS draws its screen-sharing badge over it.
                              // 2 = new window: the synthetic host gives that stream's app a new window (a test hook,
                              // `wisp poke … action new-window`); a real host ignores it. 3 = open panel: the
                              // synthetic host shows a fake out-of-process Open panel in that stream (test hook).
    case iconRequest = 17     // str appKey, u16 px: send that app's icon at px×px (for a phantom app's Dock icon).
                              // Answered by appIconLarge chunks; an older host ignores it.
    case menuRequest = 18     // str appKey, u16 menu: that app's menu bar (menu = 0xFFFF: all of it; else one top-level
                              // menu's subtree, by its index in the app's AXMenuBar). Answered by menuTree messages;
                              // an older host ignores it. See MenuNode.
    case menuPress = 19       // str appKey, u16 stream (0 = no window in particular), u8 depth, depth x (u16 index,
                              // str title): choose that menu item. The host brings the stream's window forward, finds
                              // the item by index (checking each title) and presses it through Accessibility.
    case hello = 20           // u16 version, u32 features, str viewerName. The first message on a viewer connection.
    case openStream = 21      // u32 windowID (0 = the window the host is sharing: its primary stream).
                              // Answered by streamOpened, or by streamClosed(stream 0, reason, windowID).
    case closeStream = 22     // stream: stop sending it (the window stays open on the host)
    case probe = 23           // u16 version, as the FIRST message: a probe (the viewer's list of Macs on the tailnet).
                              // The host answers probeAck (or refused) and closes; the connection never becomes the
                              // viewer. An older host takes it for a protocol-1 viewer.
    case reopenApp = 24       // str appKey: the app's phantom was clicked in the Dock with no windows open, and the host
                              // lists none of that app. The host sends the app a reopen event, as a Dock click there
                              // would (launching it if it isn't running); with followsNewWindows its new window then
                              // opens as a stream by itself. An older host ignores it.
    // Clipboard sync, both ways (only to a peer whose hello/helloAck has Wire.Feature.clipboard; see
    // Sources/wisp/Clipboard.swift). The same three messages host -> viewer are 130, 131 and 132.
    case clipboardBegin = 30  // u32 id, u32 totalBytes, u8 n, n x (str UTI, u32 bytes): a new clipboard (one item's
                              // representations, in order). Its bytes follow in clipboardChunk messages. A newer
                              // id replaces any transfer still in flight.
    case clipboardChunk = 31  // u32 id, u32 offset, bytes (≤ 60000): the next part of transfer id, in order.
    case clipboardState = 32  // u8 on: whether this side shares its clipboard now (its setting). Sent after the
                              // hello exchange and whenever the setting changes; nothing is sent to a side that is off.
    // host -> viewer
    case windowInfo = 100     // stream, then WindowInfo
    case pong = 101           // u32 seq, u64 host clock (µs)
    case windowList = 102     // see WindowEntry. Also re-sent unasked when the set of streamed windows changes.
    case appIcon = 103        // str appKey, PNG bytes (32×32 px). Once per app per connection,
                              // before the first windowList that mentions it.
    case hostStatus = 104     // str: a condition the viewer should show (e.g. the screen is locked); "" = all clear
    case windowChrome = 105   // stream, then WindowChrome: where that window's title bar and traffic lights are.
                              // Sent after windowInfo, and again when the window changes or resizes.
    case windowGone = 106     // stream: the window was closed on the host. The stream is over.
    case appIconLarge = 107   // str appKey, u16 px, u32 totalBytes, u32 offset, PNG bytes from offset: one chunk
                              // (≤ 60000 B) of a large icon answering iconRequest. The chunks arrive in order.
    case menuTree = 108       // str appKey, u8 kind, then by kind (see MenuTree):
                              //   0 bar:  u16 count, count x (u16 index, str title)  the top-level menus, in order
                              //   1 menu: one MenuNode (a top-level menu and its items)  ≤ 60000 B, cut if bigger
                              //   2 none: str why (the app isn't running, has no menu bar, no Accessibility)
    case helloAck = 110       // u16 version, u32 features, u32 session, str hostName
    case streamOpened = 111   // stream, u32 windowID, str appKey, str appName (the app fields since stage 3; older
                              // hosts leave them out). windowInfo, windowChrome and a keyframe follow.
                              // Also sent unasked when the host operator shares another window.
    case streamClosed = 112   // stream (0 = an openStream that failed), u8 reason (StreamCloseReason), u32 windowID
    case probeAck = 113       // answers probe: see ProbeReply
    case refused = 114        // str why: the host won't serve this connection (not on its allow-list, not over
                              // Tailscale…). Sent instead of helloAck / probeAck, then the host closes it.
    case newWindowHeld = 115  // u32 windowID, str appKey, str appName, u8 open, u8 max: an app the viewer is showing
                              // opened a new window, which isn't streamed because `open` windows already are (the
                              // limit, `max`). It opens by itself once a stream closes. Only with followsNewWindows.
    case hostClipboardBegin = 130 // as clipboardBegin, host -> viewer
    case hostClipboardChunk = 131 // as clipboardChunk
    case hostClipboardState = 132 // as clipboardState

    /// The payload starts with a u16 stream ID.
    public var isPerStream: Bool {
        switch self {
        case .mouseMove, .mouseDrag, .mouseDown, .mouseUp, .scroll, .key, .keyframeRequest, .nack,
             .resizeWindow, .windowAction, .closeStream, .windowInfo, .windowChrome, .windowGone,
             .streamOpened, .streamClosed: true
        default: false
        }
    }
    public var isInput: Bool { rawValue >= 1 && rawValue <= 6 }
}

/// The host's answer to a probe: who it is and how busy, without connecting as the viewer.
public struct ProbeReply: Equatable {
    public var version: UInt16 = Wire.protocolVersion
    public var hostName: String
    /// The host operator has chosen a window to share (the primary one).
    public var hasPrimary: Bool
    /// A viewer is connected (connecting replaces it).
    public var viewerConnected: Bool
    /// Windows streamed to the viewer now, and at most.
    public var openStreams: Int
    public var maxStreams: Int

    public init(hostName: String, hasPrimary: Bool, viewerConnected: Bool, openStreams: Int, maxStreams: Int) {
        self.hostName = hostName; self.hasPrimary = hasPrimary; self.viewerConnected = viewerConnected
        self.openStreams = openStreams; self.maxStreams = maxStreams
    }

    // u16 version, u8 flags (bit0 hasPrimary, bit1 viewerConnected), u8 openStreams, u8 maxStreams, str hostName
    public func encode() -> Data {
        message(.probeAck) {
            $0.u16(version)
            $0.u8((hasPrimary ? 1 : 0) | (viewerConnected ? 2 : 0))
            $0.u8(UInt8(clamping: openStreams)); $0.u8(UInt8(clamping: maxStreams))
            $0.str(hostName)
        }
    }
    public static func decode(_ d: Data) -> ProbeReply? {
        var r = Reader(d)
        guard let v = r.u16(), let f = r.u8(), let open = r.u8(), let max = r.u8() else { return nil }
        var p = ProbeReply(hostName: r.str() ?? "", hasPrimary: f & 1 != 0, viewerConnected: f & 2 != 0, openStreams: Int(open), maxStreams: Int(max))
        p.version = v
        return p
    }
}

/// The viewer's hello and the host's helloAck.
public struct Hello {
    public var version: UInt16
    public var features: UInt32 = 0
    public var name: String
    public var session: UInt32 = 0 // helloAck only

    public init(version: UInt16 = Wire.protocolVersion, name: String, session: UInt32 = 0) {
        self.version = version; self.name = name; self.session = session
    }
    public func encode() -> Data { message(.hello) { $0.u16(version); $0.u32(features); $0.str(name) } }
    public func encodeAck() -> Data { message(.helloAck) { $0.u16(version); $0.u32(features); $0.u32(session); $0.str(name) } }

    public static func decode(_ d: Data) -> Hello? {
        var r = Reader(d)
        guard let v = r.u16(), let f = r.u32() else { return nil }
        var h = Hello(version: v, name: r.str() ?? "")
        h.features = f
        return h
    }
    public static func decodeAck(_ d: Data) -> Hello? {
        var r = Reader(d)
        guard let v = r.u16(), let f = r.u32(), let s = r.u32() else { return nil }
        var h = Hello(version: v, name: r.str() ?? "", session: s)
        h.features = f
        return h
    }
}

public struct Writer {
    public private(set) var data = Data()
    public init() {}
    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    public mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    /// u16 byte length + UTF-8, cut to at most `max` bytes on a character boundary.
    public mutating func str(_ s: String, max: Int = 200) {
        var cut = Substring(s)
        while cut.utf8.count > max { cut = cut.dropLast() }
        u16(UInt16(cut.utf8.count)); bytes(Data(cut.utf8))
    }
}

public struct Reader {
    private let data: Data
    private var pos: Int
    public init(_ d: Data) { data = d; pos = d.startIndex }
    public var remaining: Int { data.endIndex - pos }

    public mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { pos += 1 }
        return data[pos]
    }
    public mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) << 8 | UInt16(b)
    }
    public mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    public mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) << 16 | UInt32(b)
    }
    public mutating func u64() -> UInt64? {
        guard let a = u32(), let b = u32() else { return nil }
        return UInt64(a) << 32 | UInt64(b)
    }
    public mutating func bytes(_ n: Int) -> Data? {
        guard remaining >= n else { return nil }
        defer { pos += n }
        return Data(data[pos ..< pos + n])
    }
    public mutating func rest() -> Data { bytes(remaining) ?? Data() }
    public mutating func str() -> String? {
        guard let n = u16(), let d = bytes(Int(n)) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

/// XORs `d` into `acc` (which must be at least as long). Used for FEC parity.
public func xorInto(_ acc: inout [UInt8], _ d: Data) {
    d.withUnsafeBytes { src in
        for i in 0 ..< src.count { acc[i] ^= src[i] }
    }
}

/// Monotonic clock in microseconds. Each Mac has its own; the viewer estimates the offset from pings.
public func nowMicros() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }

/// Prepended to every video frame so the viewer can measure latency and route the frame to its stream.
public struct FrameTag {
    public static let size = 27
    public static let sizeV1 = 25
    public var stream: UInt16
    public var encodedAt: UInt64   // host clock, µs, when the frame was handed to the encoder
    public var inputsApplied: UInt32 // how many input messages for this stream the host had injected by then
    public var refinement: Bool    // a sharpening re-send of an unchanged frame (not a real update)
    // Where the host's share of the latency went (µs; 0 = not measured for this frame):
    public var captureLag: UInt32 = 0 // window server composited the frame → handed to the encoder
    public var encodeTime: UInt32 = 0 // handed to the encoder → compressed
    public var appRender: UInt32 = 0  // an input was injected → the first frame captured after it

    public init(stream: UInt16, encodedAt: UInt64, inputsApplied: UInt32, refinement: Bool) {
        self.stream = stream; self.encodedAt = encodedAt; self.inputsApplied = inputsApplied; self.refinement = refinement
    }
    public func write(_ w: inout Writer) {
        w.u16(stream); w.u64(encodedAt); w.u32(inputsApplied); w.u8(refinement ? 1 : 0)
        w.u32(captureLag); w.u32(encodeTime); w.u32(appRender)
    }
    /// The protocol-1 layout (no stream ID). Only for the "please update" frame sent to old viewers.
    public func writeV1(_ w: inout Writer) {
        w.u64(encodedAt); w.u32(inputsApplied); w.u8(refinement ? 1 : 0)
        w.u32(captureLag); w.u32(encodeTime); w.u32(appRender)
    }
    public static func read(_ r: inout Reader) -> FrameTag? {
        guard let s = r.u16(), let t = r.u64(), let n = r.u32(), let f = r.u8(),
              let c = r.u32(), let e = r.u32(), let a = r.u32() else { return nil }
        var tag = FrameTag(stream: s, encodedAt: t, inputsApplied: n, refinement: f & 1 != 0)
        (tag.captureLag, tag.encodeTime, tag.appRender) = (c, e, a)
        return tag
    }
}

/// Thread-safe sample collector: add microsecond samples, take p50/p95 in ms (0xFFFF = none).
public final class Samples {
    private let lock = NSLock()
    private var values: [Int64] = []
    public init() {}
    public func add(_ us: Int64) { lock.lock(); values.append(us); lock.unlock() }
    public func take() -> (p50: UInt16, p95: UInt16, count: Int) {
        lock.lock(); let v = values.sorted(); values = []; lock.unlock()
        guard !v.isEmpty else { return (0xFFFF, 0xFFFF, 0) }
        func q(_ f: Double) -> UInt16 { UInt16(clamping: max(0, v[min(v.count - 1, Int(Double(v.count) * f))]) / 1000) }
        return (q(0.5), q(0.95), v.count)
    }
}

/// What the viewer measured over the last reporting window, across all its streams. Times in ms;
/// 0xFFFF = no samples. `streams` adds the per-stream frame rate and video delay.
public struct ViewerStats {
    public var rttMin: UInt16 = 0xFFFF, rttAvg: UInt16 = 0xFFFF
    public var videoP50: UInt16 = 0xFFFF, videoP95: UInt16 = 0xFFFF
    public var inputP50: UInt16 = 0xFFFF, inputP95: UInt16 = 0xFFFF
    public var inputSamples: UInt16 = 0
    public var fps: UInt16 = 0
    /// Per-stage latency breakdown, in pipeline order: (name, p50 ms, p95 ms).
    public var stages: [(name: String, p50: UInt16, p95: UInt16)] = []
    /// Per stream: (stream, fps, video delay p50 ms).
    public var streams: [(stream: UInt16, fps: UInt16, videoP50: UInt16)] = []
    public init() {}

    public func encode() -> Data {
        message(.stats) { w in
            for v in [rttMin, rttAvg, videoP50, videoP95, inputP50, inputP95, inputSamples, fps] { w.u16(v) }
            w.u8(UInt8(stages.count))
            for s in stages { w.str(s.name); w.u16(s.p50); w.u16(s.p95) }
            let list = streams.prefix(255)
            w.u8(UInt8(list.count))
            for s in list { w.u16(s.stream); w.u16(s.fps); w.u16(s.videoP50) }
        }
    }

    /// e.g. "capture 4/9 · encode 6/8 · network 12/40 …" (p50/p95 ms)
    public var breakdown: String {
        stages.map { "\($0.name) \(ms($0.p50))/\(ms($0.p95))" }.joined(separator: " · ")
    }
    /// e.g. "#1 60 fps (video 12 ms) · #2 30 fps (video 14 ms)"
    public var perStream: String {
        streams.map { "#\($0.stream) \($0.fps) fps (video \(ms($0.videoP50)) ms)" }.joined(separator: " · ")
    }

    public static func decode(_ d: Data) -> ViewerStats? {
        var r = Reader(d)
        var s = ViewerStats()
        guard let a = r.u16(), let b = r.u16(), let c = r.u16(), let e = r.u16(), let f = r.u16(),
              let g = r.u16(), let h = r.u16(), let i = r.u16() else { return nil }
        (s.rttMin, s.rttAvg, s.videoP50, s.videoP95, s.inputP50, s.inputP95, s.inputSamples, s.fps) = (a, b, c, e, f, g, h, i)
        if let n = r.u8() {
            for _ in 0 ..< n {
                guard let name = r.str(), let p50 = r.u16(), let p95 = r.u16() else { break }
                s.stages.append((name, p50, p95))
            }
        }
        if let n = r.u8() {
            for _ in 0 ..< n {
                guard let id = r.u16(), let fps = r.u16(), let v = r.u16() else { break }
                s.streams.append((id, fps, v))
            }
        }
        return s
    }
}

/// One shareable window on the host, as listed in a windowList message:
/// [u16 count] then count x ([u32 id][str appKey][str appName][str title][u16 pointW][u16 pointH][u8 flags]),
/// flags bit0 = streamed (open in a stream right now).
public struct WindowEntry: Equatable {
    public var id: UInt32
    public var appKey: String  // bundle ID, or "pid:<n>" for an app without one; keys appIcon
    public var appName: String
    public var title: String
    public var points: (w: UInt16, h: UInt16)
    public var shared: Bool

    public init(id: UInt32, appKey: String, appName: String, title: String, points: (w: UInt16, h: UInt16), shared: Bool) {
        self.id = id; self.appKey = appKey; self.appName = appName; self.title = title; self.points = points; self.shared = shared
    }
    public static func == (a: WindowEntry, b: WindowEntry) -> Bool {
        a.id == b.id && a.appKey == b.appKey && a.appName == b.appName && a.title == b.title
            && a.points == b.points && a.shared == b.shared
    }

    /// Control messages carry at most 64 KB; entries past that are left out.
    public static func encode(_ list: [WindowEntry]) -> Data {
        var items: [Data] = []
        var total = 2
        for e in list {
            var w = Writer()
            w.u32(e.id); w.str(e.appKey); w.str(e.appName); w.str(e.title, max: 160)
            w.u16(e.points.w); w.u16(e.points.h); w.u8(e.shared ? 1 : 0)
            guard total + w.data.count < 60000 else { break }
            total += w.data.count
            items.append(w.data)
        }
        return message(.windowList) { w in
            w.u16(UInt16(items.count))
            items.forEach { w.bytes($0) }
        }
    }

    public static func decode(_ d: Data) -> [WindowEntry]? {
        var r = Reader(d)
        guard let n = r.u16() else { return nil }
        var out: [WindowEntry] = []
        for _ in 0 ..< n {
            guard let id = r.u32(), let key = r.str(), let app = r.str(), let title = r.str(),
                  let pw = r.u16(), let ph = r.u16(), let f = r.u8() else { return nil }
            out.append(WindowEntry(id: id, appKey: key, appName: app, title: title, points: (pw, ph), shared: f & 1 != 0))
        }
        return out
    }
}

/// The windowInfo payload (after the stream ID): u16 pointW, u16 pointH, u16 pixelW, u16 pixelH, utf8 title,
/// then 0xFF + u32 requestID, the latest resizeWindow the host applied. (0xFF never occurs in UTF-8; protocol 1
/// used the same layout without the stream ID, which is how old viewers are told to update.)
public struct WindowInfo: Equatable {
    public var points: CGSize
    public var pixels: CGSize
    public var title: String
    /// The newest resizeWindow request the host has applied and settled (0 = none yet).
    public var requestID: UInt32?

    public init(points: CGSize, pixels: CGSize, title: String, requestID: UInt32?) {
        self.points = points; self.pixels = pixels; self.title = title; self.requestID = requestID
    }

    private func write(_ w: inout Writer) {
        w.u16(UInt16(clamping: Int(points.width))); w.u16(UInt16(clamping: Int(points.height)))
        w.u16(UInt16(clamping: Int(pixels.width))); w.u16(UInt16(clamping: Int(pixels.height)))
        w.bytes(Data(title.utf8))
        if let requestID { w.u8(0xFF); w.u32(requestID) }
    }

    public func encode(stream: UInt16) -> Data { message(.windowInfo, stream: stream) { write(&$0) } }
    /// Protocol 1's windowInfo (no stream ID), only for telling an old viewer to update.
    public func encodeV1() -> Data { message(.windowInfo) { write(&$0) } }

    /// Decodes the payload after the stream ID.
    public static func decode(_ d: Data) -> WindowInfo? {
        var r = Reader(d)
        guard let pw = r.u16(), let ph = r.u16(), let xw = r.u16(), let xh = r.u16() else { return nil }
        var rest = r.rest()
        var id: UInt32?
        if rest.count >= 5, rest[rest.endIndex - 5] == 0xFF {
            var t = Reader(Data(rest.suffix(4)))
            id = t.u32()
            rest = Data(rest.dropLast(5))
        }
        return WindowInfo(points: CGSize(width: Int(pw), height: Int(ph)), pixels: CGSize(width: Int(xw), height: Int(xh)),
                          title: String(decoding: rest, as: UTF8.self), requestID: id)
    }
}

/// True if request `a` is newer than `b` (IDs wrap around).
public func isNewer(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

/// A streamed window's own chrome, so the viewer can make it act as its window's chrome
/// (payload after the stream ID): [u16 titleBarHeight] then close, minimize, zoom as [u16 x][u16 y][u16 w][u16 h].
/// Points, relative to the window's top-left; a missing button is all zeros.
/// titleBarHeight 0 means the host couldn't read the window (the viewer falls back to a plain strip).
public struct WindowChrome: Equatable {
    public var titleBarHeight: UInt16
    public var close: CGRect, minimize: CGRect, zoom: CGRect

    public init(titleBarHeight: UInt16, close: CGRect = .zero, minimize: CGRect = .zero, zoom: CGRect = .zero) {
        self.titleBarHeight = titleBarHeight; self.close = close; self.minimize = minimize; self.zoom = zoom
    }

    public static let unknown = WindowChrome(titleBarHeight: 0)
    public var isKnown: Bool { titleBarHeight > 0 }

    public func encode(stream: UInt16) -> Data {
        message(.windowChrome, stream: stream) { w in
            w.u16(titleBarHeight)
            func pt(_ v: CGFloat) -> UInt16 { UInt16(clamping: Int(v.rounded())) }
            for r in [close, minimize, zoom] { w.u16(pt(r.minX)); w.u16(pt(r.minY)); w.u16(pt(r.width)); w.u16(pt(r.height)) }
        }
    }

    public static func decode(_ d: Data) -> WindowChrome? {
        var r = Reader(d)
        guard let h = r.u16() else { return nil }
        var rects: [CGRect] = []
        for _ in 0 ..< 3 {
            guard let x = r.u16(), let y = r.u16(), let w = r.u16(), let hh = r.u16() else { return nil }
            rects.append(CGRect(x: Int(x), y: Int(y), width: Int(w), height: Int(hh)))
        }
        return WindowChrome(titleBarHeight: h, close: rects[0], minimize: rects[1], zoom: rects[2])
    }
}

public func ms(_ v: UInt16) -> String { v == 0xFFFF ? "–" : "\(v)" }

/// Builds one length-prefixed control message.
public func message(_ type: MsgType, _ build: (inout Writer) -> Void = { _ in }) -> Data {
    var body = Writer()
    body.u8(type.rawValue)
    build(&body)
    var out = Writer()
    out.u16(UInt16(body.data.count))
    out.bytes(body.data)
    return out.data
}

/// Builds a control message about one stream: its ID, then the rest of the payload.
public func message(_ type: MsgType, stream: UInt16, _ build: (inout Writer) -> Void = { _ in }) -> Data {
    message(type) { w in w.u16(stream); build(&w) }
}

/// Splits a TCP byte stream back into control messages.
public final class MessageParser {
    private var buf = Data()
    public init() {}

    public func feed(_ d: Data) -> [(MsgType, Data)] {
        buf.append(d)
        var out: [(MsgType, Data)] = []
        while buf.count >= 2 {
            let s = buf.startIndex
            let len = Int(buf[s]) << 8 | Int(buf[s + 1])
            guard buf.count >= 2 + len else { break }
            let body = Data(buf[(s + 2) ..< (s + 2 + len)])
            buf = Data(buf[(s + 2 + len)...])
            if let t = body.first, let type = MsgType(rawValue: t) {
                out.append((type, Data(body.dropFirst())))
            }
        }
        return out
    }
}

/// Cheap thread-safe byte/event counters for the stats line.
public final class Counter {
    private let lock = NSLock()
    private var value = 0
    private var sum = 0
    public init() {}
    public func add(_ n: Int) { lock.lock(); value += n; sum += n; lock.unlock() }
    /// Everything ever added (take() doesn't reset it), for rates measured by whoever reads it.
    public var total: Int { lock.lock(); defer { lock.unlock() }; return sum }
    /// Returns the count since the last call and resets it.
    public func take() -> Int { lock.lock(); defer { value = 0; lock.unlock() }; return value }
}

public func kbps(_ bytes: Int, over seconds: Double) -> String {
    let k = Double(bytes) * 8 / 1000 / seconds
    return k >= 1000 ? String(format: "%.2f Mbps", k / 1000) : String(format: "%.1f kbps", k)
}
