// SPDX-License-Identifier: GPL-3.0-or-later
// How many concurrent low-latency hardware HEVC sessions can this Mac run at once?
// Usage: swift scripts/hevc-sessions.swift [width height] [fps]
//
// For N = 1, 2, 4, … sessions it creates N sessions configured like Wisp's Encoder
// (hardware only, low-latency rate control, no reordering), feeds each one 90 frames at the
// target frame rate in parallel, and reports per-frame encode latency (submit -> output) and
// whether the sessions kept up. Content is a fixed noise texture that moves across grey each
// frame (like fast scrolling: every frame changes, but motion search can find it).
import CoreMedia
import Foundation
import VideoToolbox

let args = CommandLine.arguments.dropFirst().compactMap { Int($0) }
let width = args.count >= 2 ? args[0] : 1920
let height = args.count >= 2 ? args[1] : 1080
let fps = args.count >= 3 ? args[2] : 60
let framesPerSession = 90
setbuf(stdout, nil)

func makeSession() -> VTCompressionSession? {
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var s: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                     codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                     imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                     refcon: nil, compressionSessionOut: &s) == noErr, let s else { return nil }
    let props: [CFString: Any] = [
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_AverageBitRate: 10_000_000,
        kVTCompressionPropertyKey_ExpectedFrameRate: fps,
        kVTCompressionPropertyKey_MaxKeyFrameInterval: 100_000,
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
    ]
    for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
    VTCompressionSessionPrepareToEncodeFrames(s)
    return s
}

let texture = (0 ..< 400 * 400).map { _ in UInt8.random(in: 0 ... 255) }

func makeFrames(_ n: Int) -> [CVPixelBuffer] {
    (0 ..< n).map { i in
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let p = pb!
        CVPixelBufferLockBaseAddress(p, [])
        for plane in 0 ..< 2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(p, plane)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(p, plane), h = CVPixelBufferGetHeightOfPlane(p, plane)
            memset(base, 128, bpr * h)
            let bx = 200 + i * 16, by = (200 + i * 8) / (plane + 1)
            for y in 0 ..< 400 / (plane + 1) {
                for x in 0 ..< 400 { base[(by + y) * bpr + bx + x] = texture[y * 400 + x] }
            }
        }
        CVPixelBufferUnlockBaseAddress(p, [])
        return p
    }
}

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

print("HEVC hardware encode, \(width)x\(height) @ \(fps) fps target, \(framesPerSession) frames per session")
print("(latency percentiles skip each session's first 10 frames)")
print("sessions  created  p50 ms  p95 ms  max ms  frames out  dropped  wall s  verdict")
let frames = makeFrames(16)
let counts = ProcessInfo.processInfo.environment["SESSIONS"].map { $0.split(separator: ",").compactMap { Int($0) } }
    ?? [1, 2, 3, 4, 6, 8, 12, 16]
for n in counts {
    let sessions = (0 ..< n).compactMap { _ in makeSession() }
    let lock = NSLock()
    var latencies: [Double] = []
    var dropped = 0, outCount = 0
    let group = DispatchGroup()
    let start = now()
    for (si, s) in sessions.enumerated() {
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            for f in 0 ..< framesPerSession {
                let due = start + Double(f) / Double(fps)
                let wait = due - now()
                if wait > 0 { usleep(useconds_t(wait * 1e6)) }
                let t0 = now()
                let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
                VTCompressionSessionEncodeFrame(s, imageBuffer: frames[(f + si) % frames.count], presentationTimeStamp: pts,
                                                duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { st, _, sb in
                    guard st == noErr, sb != nil else { lock.lock(); dropped += 1; lock.unlock(); return }
                    let dt = (now() - t0) * 1000
                    lock.lock(); if f >= 10 { latencies.append(dt) }; outCount += 1; lock.unlock() // first 10: warm-up
                }
            }
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            group.leave()
        }
    }
    if group.wait(timeout: .now() + 20) == .timedOut {
        print(String(format: "%8d  %7d  encoder stopped producing frames (%d of %d out after 20 s): hung", n, sessions.count,
                     outCount, sessions.count * framesPerSession))
        exit(1)
    }
    let wall = now() - start
    sessions.forEach { VTCompressionSessionInvalidate($0) }
    let sorted = latencies.sorted()
    func pct(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
    let expected = sessions.count * framesPerSession
    let keptUp = sessions.count == n && outCount == expected && pct(0.95) < 1000.0 / Double(fps)
    print(String(format: "%8d  %7d  %6.1f  %6.1f  %6.1f  %10d  %7d  %6.2f  %@",
                 n, sessions.count, pct(0.5), pct(0.95), sorted.last ?? .nan, outCount, dropped, wall,
                 sessions.count < n ? "could not create all sessions" : keptUp ? "ok" : "falls behind"))
}
