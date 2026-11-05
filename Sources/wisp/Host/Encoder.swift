// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import VideoToolbox
import WispCommon

/// Hardware HEVC/H.264 encoder in low-latency mode: no B-frames, no lookahead,
/// no periodic keyframes (the viewer asks for one when it needs it).
final class Encoder {
    let width: Int
    let height: Int
    let hevc: Bool
    private let session: VTCompressionSession
    /// The frame's tag (with its encode time filled in), the frame after the tag ([flags][param sets][sample]),
    /// and whether it is a keyframe.
    var onFrame: ((FrameTag, Data, Bool) -> Void)?
    /// Time from handing a frame to the encoder until its output, summed for the stats line.
    static let encodeMicros = Counter(), encodedFrames = Counter()

    init?(width: Int, height: Int, preferHEVC: Bool, kbps: Int, fps: Int, label: String = "") {
        func make(_ hevc: Bool) -> VTCompressionSession? {
            let spec: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
            if st != noErr { Log.warning(.encode, "encoder\(label): no hardware \(hevc ? "HEVC" : "H.264") session for \(width)x\(height): OSStatus \(st)") }
            return st == noErr ? s : nil
        }
        let t0 = Date()
        if preferHEVC, let s = make(true) {
            session = s; hevc = true
        } else if let s = make(false) {
            session = s; hevc = false
            if preferHEVC { Log.info(.encode, "encoder\(label): falling back to H.264") }
        } else {
            Log.error(.encode, "encoder\(label): no hardware encoder for \(width)x\(height) (all of the media engine's sessions may be in use)")
            return nil
        }
        self.width = width
        self.height = height

        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: kbps * 1000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 100_000,
            kVTCompressionPropertyKey_ProfileLevel: hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel
                : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
        ]
        for (k, v) in props {
            let st = VTSessionSetProperty(session, key: k, value: v as CFTypeRef)
            if st != noErr { Log.warning(.encode, "encoder\(label): could not set \(k) (OSStatus \(st))") }
        }
        let prep = VTCompressionSessionPrepareToEncodeFrames(session)
        if prep != noErr { Log.warning(.encode, "encoder\(label): prepare failed: OSStatus \(prep)") }
        self.label = label
        Log.info(.encode, "encoder\(label): \(hevc ? "HEVC" : "H.264") \(width)x\(height) @ \(kbps) kbps \(fps) fps, low-latency, made in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    func setBitrate(kbps: Int) {
        let st = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (kbps * 1000) as CFNumber)
        if st != noErr { Log.warning(.encode, "encoder\(label): setting \(kbps) kbps failed: OSStatus \(st)") } else { Log.debug(.encode, "encoder\(label): \(kbps) kbps") }
    }
    private var label = ""

    deinit {
        // A wedged session may never finish its frames: don't wait for them then.
        if !wedged { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        VTCompressionSessionInvalidate(session)
    }

    // In-flight bookkeeping, under `lock`. Each frame handed to the session gets a sequence number;
    // its output (or its error) removes it exactly once, so an error return that also calls the
    // handler can't count twice, and a frame VideoToolbox never answers for shows up by its age.
    private let lock = NSLock()
    private var inFlightFrames: [UInt64: UInt64] = [:] // sequence -> submitted at (µs)
    private var seq: UInt64 = 0
    private var submitted = 0, completed = 0, dropped = 0, failures = 0, consecutiveFailures = 0, lateOutputs = 0
    private var lastOutputAt: UInt64 = 0
    private var lastFailure: OSStatus = noErr
    private var wedged = false
    /// Outputs the fault `encoder-stall` still has to swallow (as if VideoToolbox never called back).
    private var faultLose = 0
    private var faultInvalidUntil: UInt64 = 0

    /// Frames handed to the session whose output hasn't come back yet. With several streams the media
    /// engine can fall behind; the pipeline then skips frames rather than queue them (each queued frame
    /// is latency).
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return inFlightFrames.count }
    /// How long the oldest frame still in flight has been waiting (seconds; 0 if none).
    var oldestInFlightAge: Double {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = inFlightFrames.values.min() else { return 0 }
        let now = nowMicros()
        return now > oldest ? Double(now - oldest) / 1_000_000 : 0
    }
    /// The session looks broken (invalidated, e.g. after sleep or a media-engine reset, or every frame
    /// failing): the pipeline makes a new encoder.
    var broken: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastFailure == kVTInvalidSessionErr || consecutiveFailures >= 10
    }
    /// Counters for the health line and stall reports.
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let now = nowMicros()
        let ages = inFlightFrames.values.sorted().map { String(format: "%.2f s", Double(now > $0 ? now - $0 : 0) / 1_000_000) }
        return "in flight \(inFlightFrames.count)\(ages.isEmpty ? "" : " (waiting \(ages.joined(separator: ", ")))"), submitted \(submitted), "
            + "output \(completed), dropped by VideoToolbox \(dropped), errors \(failures)"
            + (lastFailure != noErr ? " (last OSStatus \(lastFailure))" : "") + ", late outputs ignored \(lateOutputs), last output \(ago(lastOutputAt, now: now))"
    }

    /// Forgets the frames in flight: VideoToolbox lost them (no callback). Their outputs, if they ever
    /// come, are dropped (the pipeline forces a keyframe, which must not be followed by older frames).
    func forgetInFlight() { lock.lock(); inFlightFrames = [:]; lock.unlock() }

    /// This encoder is being replaced because it stopped answering: deinit won't wait for its frames.
    func markWedged() { lock.lock(); wedged = true; lock.unlock() }

    /// Called (on VideoToolbox's queue) when VideoToolbox dropped a frame that was a forced keyframe:
    /// the pipeline forces another.
    var onDroppedKey: (() -> Void)?

    /// Frames the pipelines skipped because their encoder was busy, for the stats line.
    static let skipped = Counter()

    // Fault injection (WISP_FAULT, see Stall.swift), timed from the first frame encoded for a viewer:
    // `encoder-stall[=<s>]` swallows two outputs once, that many seconds (default 4) after it;
    // `encoder-hang[=<s>]` swallows every output of every encoder for 5 s from then (the media engine
    // stops answering); `encoder-invalid[=<s>]` fails every frame with kVTInvalidSessionErr for 1 s.
    private static let faultStallAt = Fault.number("encoder-stall", default: 4)
    private static let faultHangAt = Fault.number("encoder-hang", default: 4)
    private static let faultInvalidAt = Fault.number("encoder-invalid", default: 4)
    private static let faultLock = NSLock()
    nonisolated(unsafe) private static var faultFirstFrame: UInt64 = 0
    nonisolated(unsafe) private static var faultStallDone = false, faultInvalidDone = false, faultHangDone = false
    nonisolated(unsafe) private static var faultHangUntil: UInt64 = 0

    private func armFaults(_ now: UInt64) {
        guard Self.faultStallAt != nil || Self.faultInvalidAt != nil || Self.faultHangAt != nil, label != " (update notice)" else { return }
        Self.faultLock.lock(); defer { Self.faultLock.unlock() }
        if Self.faultFirstFrame == 0 { Self.faultFirstFrame = now }
        let since = Double(now - Self.faultFirstFrame) / 1_000_000
        if let at = Self.faultStallAt, !Self.faultStallDone, since >= at {
            Self.faultStallDone = true
            lock.lock(); faultLose = 2; lock.unlock()
            Log.warning(.encode, "encoder\(label): FAULT encoder-stall: the next 2 outputs will be lost, as if VideoToolbox never called back")
        }
        if let at = Self.faultHangAt, !Self.faultHangDone, since >= at {
            Self.faultHangDone = true
            Self.faultHangUntil = now + 5_000_000
            Log.warning(.encode, "encoder\(label): FAULT encoder-hang: every encoder's outputs are lost for 5 s")
        }
        if let at = Self.faultInvalidAt, !Self.faultInvalidDone, since >= at {
            Self.faultInvalidDone = true
            lock.lock(); faultInvalidUntil = now + 1_000_000; lock.unlock()
            Log.warning(.encode, "encoder\(label): FAULT encoder-invalid: every frame fails with kVTInvalidSessionErr for 1 s")
        }
    }

    private static var hanging: Bool {
        guard faultHangAt != nil else { return false }
        faultLock.lock(); defer { faultLock.unlock() }
        return faultHangUntil > nowMicros()
    }

    func encode(_ pb: CVPixelBuffer, forceKey: Bool, tag: FrameTag) {
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let frameProps = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let now = nowMicros()
        armFaults(now)
        lock.lock()
        seq &+= 1
        let id = seq
        inFlightFrames[id] = now
        submitted += 1
        let injectInvalid = faultInvalidUntil > now
        lock.unlock()
        if injectInvalid { finish(id, status: kVTInvalidSessionErr, what: "VTCompressionSessionEncodeFrame failed (injected)"); return }
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProps, infoFlagsOut: nil
        ) { [weak self] status, flags, sb in
            guard let self else { return }
            lock.lock()
            if faultLose > 0 { faultLose -= 1; lock.unlock(); return } // injected: this callback "never came"
            lock.unlock()
            if Self.hanging { return } // injected too
            guard finish(id, status: status, what: "encoding a frame failed") else { return }
            guard let sb, !flags.contains(.frameDropped) else {
                lock.lock(); dropped += 1; let n = dropped; lock.unlock()
                if n <= 3 || n % 100 == 0 { Log.warning(.encode, "encoder\(label): VideoToolbox dropped a frame\(forceKey ? " (a forced keyframe: forcing another)" : "") (\(n) so far)") }
                if forceKey { onDroppedKey?() }
                return
            }
            emit(sb, tag: tag)
        }
        if st != noErr { finish(id, status: st, what: "VTCompressionSessionEncodeFrame failed") }
    }

    /// Frame `id` is done (output or error): true if it was still in flight and succeeded. A frame
    /// already accounted for (an error return after its callback, or the reverse) or given up on by
    /// forgetInFlight (a late output) is counted and ignored.
    @discardableResult
    private func finish(_ id: UInt64, status: OSStatus, what: String) -> Bool {
        lock.lock()
        guard inFlightFrames.removeValue(forKey: id) != nil else {
            lateOutputs += 1
            let n = lateOutputs
            lock.unlock()
            if n <= 3 || n % 100 == 0 { Log.info(.encode, "encoder\(label): output for a frame already given up on (OSStatus \(status)): ignored (\(n) so far)") }
            return false
        }
        if status == noErr {
            completed += 1
            consecutiveFailures = 0
            lastOutputAt = nowMicros()
            lock.unlock()
            return true
        }
        failures += 1
        consecutiveFailures += 1
        lastFailure = status
        let n = failures
        lock.unlock()
        if n <= 3 || n % 100 == 0 {
            Log.warning(.encode, "encoder\(label): \(what): OSStatus \(status)\(status == kVTInvalidSessionErr ? " (kVTInvalidSessionErr: the session is gone)" : "") (failure \(n))")
        }
        return false
    }

    private func emit(_ sb: CMSampleBuffer, tag: FrameTag) {
        var tag = tag
        let took = nowMicros() - tag.encodedAt
        tag.encodeTime = UInt32(clamping: took)
        Self.encodeMicros.add(Int(took))
        Self.encodedFrames.add(1)
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        var w = Writer()
        w.u8((isKey ? 1 : 0) | (hevc ? 2 : 0))
        if isKey {
            let sets = parameterSets(fd)
            w.u8(UInt8(sets.count))
            for s in sets { w.u16(UInt16(s.count)); w.bytes(s) }
        }
        let len = CMBlockBufferGetDataLength(bb)
        var sample = Data(count: len)
        sample.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        w.bytes(sample)
        onFrame?(tag, w.data, isKey)
    }

    private func parameterSets(_ fd: CMFormatDescription) -> [Data] {
        var count = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        var sets: [Data] = []
        for i in 0 ..< count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets
    }
}

/// The older one-argument log: an info line (a warning if it says it failed) in the category of the
/// file it's called from. New code calls Log.info(.category, …) and friends (WispCommon/Log.swift).
func log(_ s: String, file: String = #fileID) {
    let lower = s.lowercased()
    let level: LogLevel = lower.hasPrefix("error") || lower.contains(" failed") || lower.hasPrefix("failed") || lower.contains("can't")
        ? .warning : .info
    Log.write(level, logCategory(file: file), s)
}

/// The category of a source file, by its name (#fileID is "wisp/Capture.swift": no directory, and
/// #filePath would put the build machine's paths in the binary). Keep in step with the file names.
func logCategory(file: String) -> LogCategory {
    switch file.split(separator: "/").last.map({ String($0.dropLast(6)) }) ?? "" {
    case "Capture": return .capture
    case "Encoder": return .encode
    case "VirtualDisplay": return .vdisplay
    case "Injector": return .input
    case "Menus", "PhantomMenus", "WindowsMenu": return .menu
    case "Access": return .access
    case "Server": return .net
    case "Discovery", "Probe": return .discovery
    case "IPC": return .ipc
    case "TailnetCLI": return .tailnet
    case "CLI", "ViewCLI", "main": return .cli
    case "Host", "HostWindow": return .host
    case "Client", "ViewerController", "ViewerWindow", "Latency", "StreamLink": return .viewer
    case "PhantomApp", "PhantomBundle", "PhantomHub", "RemoteBadge": return .phantom
    default: return .app
    }
}
