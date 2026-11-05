// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WispCommon

/// Latency measurements on the viewer. Thread-safe: touched from the network queue and the main thread.
final class Latency {
    private let lock = NSLock()

    // Round trip + clock offset (sender clock − viewer clock), from pings.
    private var pingSent: [UInt32: UInt64] = [:]
    private var pingSeq: UInt32 = 0
    private var samples: [(rtt: Int64, offset: Int64)] = []

    /// Lowest recent round trip (µs), nil before the first pong.
    var rttMin: Int64? { lock.lock(); defer { lock.unlock() }; return samples.map(\.rtt).min() }
    private var offset: Int64?

    // Input → screen: input messages sent, and the clicks/key presses still waiting for a frame.
    // Counted per stream: the host stamps each stream's frames with the inputs it injected into that window.
    private var inputsSent: [UInt16: UInt32] = [:]
    private var waiting: [UInt16: [(index: UInt32, sentAt: UInt64)]] = [:]

    // Current reporting window.
    private var rtts: [Int64] = []
    private var video: [Int64] = []
    private var input: [Int64] = []
    private var frames = 0
    private var streamFrames: [UInt16: Int] = [:]
    private var streamVideo: [UInt16: [Int64]] = [:]

    private(set) var summary = ""

    func nextPing() -> Data {
        lock.lock(); defer { lock.unlock() }
        pingSeq &+= 1
        pingSent[pingSeq] = nowMicros()
        pingSent = pingSent.filter { $0.key &+ 30 > pingSeq }
        return message(.ping) { [seq = pingSeq] in $0.u32(seq) }
    }

    func pong(_ payload: Data) {
        var r = Reader(payload)
        guard let seq = r.u32(), let senderNow = r.u64() else { return }
        let now = nowMicros()
        lock.lock(); defer { lock.unlock() }
        guard let sent = pingSent.removeValue(forKey: seq) else { return }
        let rtt = Int64(now - sent)
        // The sender read its clock roughly halfway through the round trip.
        samples.append((rtt, Int64(senderNow) - Int64(sent + now) / 2))
        if samples.count > 30 { samples.removeFirst() }
        offset = samples.min { $0.rtt < $1.rtt }?.offset // least-delayed ping gives the best estimate
        rtts.append(rtt)
    }

    /// Call for every input message sent, in order. `discrete` = a click or key press worth timing.
    func inputSent(stream: UInt16, discrete: Bool) {
        lock.lock(); defer { lock.unlock() }
        let n = (inputsSent[stream] ?? 0) &+ 1
        inputsSent[stream] = n
        if discrete { waiting[stream, default: []].append((n, nowMicros())) }
    }

    /// Set by a window that shows frames: clicks and the total are then timed to the screen, not to decode.
    var measuresDisplay = false

    // Per-stage breakdown, in pipeline order.
    // "relay" is the hop from the main Wisp process to a phantom app (§5.4 of docs/multi-window.md).
    private let stages = ["capture", "encode", "network", "relay", "decode", "display", "total", "app"]
    private var stageSamples: [String: [Int64]] = [:]
    // Finer than the stages (µs, for latency.log): complete on the viewer → on screen, and its parts.
    private var onViewer: [Int64] = []
    private var relayHop: [Int64] = []
    private var decodeUs: [Int64] = []
    private var displayUs: [Int64] = []

    private func stage(_ name: String, _ us: Int64) { stageSamples[name, default: []].append(us) }

    /// Sender clock → time it reached the network; nil until a ping has given us the clock offset.
    private func networkTime(_ t: FrameTiming) -> Int64? {
        guard let offset else { return nil }
        return Int64(t.reassembled) + offset - Int64(t.tag.encodedAt) - Int64(t.tag.encodeTime)
    }

    func frameDecoded(_ t: FrameTiming) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        streamFrames[t.tag.stream, default: 0] += 1
        let tag = t.tag
        if !tag.refinement, let offset {
            let v = Int64(t.decoded) + offset - Int64(tag.encodedAt)
            video.append(v)
            streamVideo[tag.stream, default: []].append(v)
            if tag.captureLag > 0 { stage("capture", Int64(tag.captureLag)) }
            stage("encode", Int64(tag.encodeTime))
            if let n = networkTime(t) { stage("network", n) }
            if t.relayed > 0 {
                stage("relay", Int64(t.relayed) - Int64(t.reassembled))
                relayHop.append(Int64(t.relayed) - Int64(t.reassembled))
            }
            stage("decode", Int64(t.decoded - t.decodeStart))
            decodeUs.append(Int64(t.decoded - t.decodeStart))
        }
        if tag.appRender > 0 { stage("app", Int64(tag.appRender)) }
        if !measuresDisplay { matchClicks(tag, at: t.decoded) }
    }

    /// `now`: when it was shown (a phantom app reports its own time; the clock is the same Mac's).
    func frameDisplayed(_ t: FrameTiming, at now: UInt64 = nowMicros()) {
        lock.lock(); defer { lock.unlock() }
        if !t.tag.refinement {
            stage("display", Int64(now - t.decoded))
            onViewer.append(Int64(now) - Int64(t.reassembled))
            displayUs.append(Int64(now) - Int64(t.decoded))
            if let n = networkTime(t) {
                stage("total", Int64(t.tag.captureLag) + Int64(t.tag.encodeTime) + n + Int64(now) - Int64(t.reassembled))
            }
        }
        matchClicks(t.tag, at: now)
    }

    /// The first frame encoded after the sender applied a click is the earliest it can show.
    private func matchClicks(_ tag: FrameTag, at now: UInt64) {
        while let first = waiting[tag.stream]?.first, first.index <= tag.inputsApplied {
            waiting[tag.stream]?.removeFirst()
            let d = Int64(now - first.sentAt)
            if d < 2_000_000 { input.append(d) } // longer means the click changed nothing visible
        }
    }

    /// Summarises and resets the window. Returns the report to send to the sender.
    func report(seconds: Double) -> ViewerStats {
        lock.lock(); defer { lock.unlock() }
        func p(_ xs: [Int64], _ q: Double) -> UInt16 {
            guard !xs.isEmpty else { return 0xFFFF }
            let s = xs.sorted()
            return UInt16(clamping: max(0, s[min(s.count - 1, Int(Double(s.count) * q))]) / 1000)
        }
        var s = ViewerStats()
        if !rtts.isEmpty {
            s.rttMin = UInt16(clamping: rtts.min()! / 1000)
            s.rttAvg = UInt16(clamping: rtts.reduce(0, +) / Int64(rtts.count) / 1000)
        }
        s.videoP50 = p(video, 0.5); s.videoP95 = p(video, 0.95)
        s.inputP50 = p(input, 0.5); s.inputP95 = p(input, 0.95)
        s.inputSamples = UInt16(clamping: input.count)
        s.fps = UInt16(clamping: Int((Double(frames) / seconds).rounded()))
        s.stages = stages.compactMap { name in
            guard let xs = stageSamples[name], !xs.isEmpty else { return nil }
            return (name, p(xs, 0.5), p(xs, 0.95))
        }
        stageSamples = [:]
        // Keep the click figure on screen until there's a newer one.
        let click = s.inputSamples > 0 ? "  ·  click→screen \(ms(s.inputP50)) ms" : (summary.contains("click") ? "  ·  " + summary.components(separatedBy: "  ·  ").last! : "")
        summary = "rtt \(ms(s.rttMin)) ms  ·  video \(ms(s.videoP50)) ms\(click)"
        s.streams = streamFrames.keys.sorted().map { id in
            (id, UInt16(clamping: Int((Double(streamFrames[id] ?? 0) / seconds).rounded())), p(streamVideo[id] ?? [], 0.5))
        }
        rtts = []; video = []; input = []; frames = 0; streamFrames = [:]; streamVideo = [:]
        func us(_ xs: [Int64]) -> String {
            guard !xs.isEmpty else { return "–" }
            let v = xs.sorted()
            return "\(v[v.count / 2])/\(v[min(v.count - 1, v.count * 95 / 100)]) µs"
        }
        if s.fps > 0 || !s.stages.isEmpty {
            LogFile.append("latency.log", "\(Log.timestamp()) [\(getpid())] rtt \(ms(s.rttMin))/\(ms(s.rttAvg)) | click→screen \(ms(s.inputP50))/\(ms(s.inputP95)) (\(s.inputSamples)) | \(s.fps) fps | \(s.breakdown)"
                + " | complete→on screen \(us(onViewer)): " + (relayHop.isEmpty ? "" : "relay \(us(relayHop)), ")
                + "decode \(us(decodeUs)), decoded→on screen \(us(displayUs))")
        }
        onViewer = []; relayHop = []; decodeUs = []; displayUs = []
        return s
    }
}

/// One decoded frame's timing on the viewer (viewer clock, µs; CLOCK_UPTIME_RAW, the same in every
/// process on this Mac).
struct FrameTiming {
    var tag: FrameTag
    var decodeStart: UInt64
    var decoded: UInt64 = 0
    /// When the frame was complete on the viewer (in-process, decoding starts right then).
    var reassembled: UInt64
    /// In a phantom app: when the frame arrived from the main Wisp process (0 = decoded in-process).
    var relayed: UInt64 = 0

    init(tag: FrameTag, decodeStart: UInt64, reassembled: UInt64? = nil, relayed: UInt64 = 0) {
        self.tag = tag
        self.decodeStart = decodeStart
        self.reassembled = reassembled ?? decodeStart
        self.relayed = relayed
    }
}
