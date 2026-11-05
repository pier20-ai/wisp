// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import WispCommon

/// Captures exactly one window. ScreenCaptureKit only delivers a frame when the
/// window's pixels change, so an idle window costs nothing.
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Pixels plus when the window server composited them (µs, same clock as nowMicros()).
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private let config = SCStreamConfiguration()

    /// `filter` captures the app's windows on one display (so its context menus, popovers and
    /// sheets are included); `region` crops that to the shared window, in display-local points.
    func start(filter: SCContentFilter, region: CGRect, pixelSize: CGSize, fps: Int, queue: DispatchQueue) async throws {
        config.sourceRect = region
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = false // the viewer shows its own local cursor, no lag
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.queueDepth = 5
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        let t0 = Date()
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch {
            Log.error(.capture, "starting capture of \(Int(region.width))x\(Int(region.height)) pt at \(Int(region.minX)),\(Int(region.minY)) failed: \(Log.describe(error))"
                      + "; Screen Recording \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
            throw error
        }
        Log.info(.capture, "capture started in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(Int(region.width))x\(Int(region.height)) pt at "
                 + "\(Int(region.minX)),\(Int(region.minY)) → \(Int(pixelSize.width))x\(Int(pixelSize.height)) px, \(fps) fps")
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        do { try await s.stopCapture(); Log.info(.capture, "capture stopped") } catch {
            // Already stopped (e.g. the window closed) is the usual reason: not worth more than a line.
            Log.info(.capture, "capture stop: \(Log.describe(error))")
        }
    }

    /// Changes which windows are composited (e.g. other streamed windows of the same app are left out).
    func update(filter: SCContentFilter) {
        stream?.updateContentFilter(filter) { err in
            if let err { Log.warning(.capture, "filter update failed: \(Log.describe(err))") } else { Log.debug(.capture, "filter updated") }
        }
    }

    func update(region: CGRect, pixelSize: CGSize) {
        config.sourceRect = region
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        stream?.updateConfiguration(config) { err in
            if let err { Log.warning(.capture, "update to \(Int(pixelSize.width))x\(Int(pixelSize.height)) px failed: \(Log.describe(err))") }
            else { Log.debug(.capture, "region now \(Int(region.width))x\(Int(region.height)) pt → \(Int(pixelSize.width))x\(Int(pixelSize.height)) px") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer
        else { return }
        let shown = (atts.first?[.displayTime] as? UInt64).map(machToMicros) ?? nowMicros()
        onFrame?(pb, shown)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warning(.capture, "capture stopped by the system: \(Log.describe(error))")
        onStop?(error)
    }
}

/// Test source for when there's no window to capture (or no Screen Recording permission):
/// a mostly static "document" under a fake title bar with traffic lights, a ticking clock and a moving box.
final class SyntheticSource {
    /// The fake title bar, in points (the synthetic window is drawn at 2 px per point).
    static let chrome = WindowChrome(titleBarHeight: 28,
                                     close: CGRect(x: 8, y: 7, width: 14, height: 14),
                                     minimize: CGRect(x: 28, y: 7, width: 14, height: 14),
                                     zoom: CGRect(x: 48, y: 7, width: 14, height: 14))
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    private var size: CGSize // only touched on queue once started
    private let label: String
    private let chrome: WindowChrome
    private var timer: DispatchSourceTimer?
    private var queue: DispatchQueue?
    private var n = 0
    /// Which background and animation (0, 1, 2), so several test windows look different.
    private let style: Int

    init(size: CGSize, label: String, chrome: WindowChrome, style: Int = 0) {
        self.size = size; self.label = label; self.chrome = chrome; self.style = style
    }

    /// Draws at a new size (pixels) from the next frame on, like a real window being resized.
    func resize(to px: CGSize) {
        guard let queue else { size = px; return }
        queue.async { self.size = px }
    }

    func start(fps: Int, queue: DispatchQueue) {
        self.queue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Draws `panel` over the window from the next frame on (nil: none), as an out-of-process panel
    /// would be composited into the capture.
    func setPanel(_ panel: SyntheticPanel?) {
        guard let queue else { self.panel = panel; return }
        queue.async { self.panel = panel }
    }
    private var panel: SyntheticPanel? // on queue once started

    private func drawPanel(_ ctx: CGContext, _ p: SyntheticPanel) {
        // Window points (top-left origin) to pixels (bottom-left origin), 2 px per point.
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * 2, y: size.height - r.maxY * 2, width: r.width * 2, height: r.height * 2) }
        let f = p.frame
        let body = px(f)
        // An outline rather than a blurred shadow: a 40 px blur every frame cost the test host ~10 fps.
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: -3, dy: -3), cornerWidth: 27, cornerHeight: 27, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.clip()
        // Sidebar and toolbar.
        ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        ctx.fill(px(CGRect(x: f.minX, y: f.minY, width: 150, height: f.height)))
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        ctx.fill(px(CGRect(x: f.minX + 150, y: f.minY, width: f.width - 150, height: 44)))
        func text(_ t: String, _ x: CGFloat, _ y: CGFloat, _ pt: CGFloat, _ c: NSColor, bold: Bool = false) {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pt * 2, weight: bold ? .semibold : .regular), .foregroundColor: c]
            let h = (t as NSString).size(withAttributes: a).height
            (t as NSString).draw(at: CGPoint(x: (f.minX + x) * 2, y: size.height - (f.minY + y) * 2 - h), withAttributes: a)
        }
        text(p.title, 170, 12, 15, .black, bold: true)
        text("Favorites", 14, 16, 11, .gray, bold: true)
        for (i, name) in ["Desktop", "Documents", "Downloads", "Projects"].enumerated() { text(name, 22, 38 + CGFloat(i) * 24, 13, .darkGray) }
        for (i, name) in ["notes.txt", "plan.md", "Projects", "screenshots", "wisp"].enumerated() {
            if i == 2 {
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
                ctx.fill(px(CGRect(x: f.minX + 158, y: f.minY + 56 + CGFloat(i) * 26, width: f.width - 170, height: 24)))
            }
            text(name, 170, 60 + CGFloat(i) * 26, 13, .black)
        }
        text(p.owner + " — out of process", 14, f.height - 30, 10, .gray)
        for (name, r) in [("Cancel", p.cancel), ("Open", p.open)] {
            let rr = px(r.offsetBy(dx: f.minX, dy: f.minY))
            ctx.setFillColor((name == "Open" ? NSColor.systemBlue : NSColor.white).cgColor)
            ctx.addPath(CGPath(roundedRect: rr, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: name == "Open" ? NSColor.white : NSColor.black]
            let ts = (name as NSString).size(withAttributes: a)
            (name as NSString).draw(at: CGPoint(x: rr.midX - ts.width / 2, y: rr.midY - ts.height / 2), withAttributes: a)
        }
        ctx.restoreGState()
    }

    private func drawTitleBar(_ ctx: CGContext, height: CGFloat) {
        ctx.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - height, width: size.width, height: height))
        ctx.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: size.height - height - 2, width: size.width, height: 2))
        let colors = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                      NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (r, c) in zip([chrome.close, chrome.minimize, chrome.zoom], colors) where r != .zero {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: r.minX * 2, y: size.height - r.maxY * 2, width: r.width * 2, height: r.height * 2).insetBy(dx: 1, dy: 1))
        }
        // macOS 27 draws a purple "screen sharing" badge over a captured window's traffic lights; mimic
        // it so the loopback test shows what the viewer's own buttons have to cover.
        let lights = [chrome.close, chrome.minimize, chrome.zoom].filter { $0 != .zero }
        if let first = lights.first, let last = lights.last {
            let badge = CGRect(x: (first.minX - 4) * 2, y: size.height - (last.maxY + 3) * 2,
                               width: (last.maxX - first.minX + 8) * 2, height: (last.height + 6) * 2)
            ctx.setFillColor(NSColor(srgbRed: 0.55, green: 0.3, blue: 0.95, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: badge.height / 2, cornerHeight: badge.height / 2, transform: nil))
            ctx.fillPath()
        }
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.darkGray]
        let w = (label as NSString).size(withAttributes: font)
        (label as NSString).draw(at: CGPoint(x: (size.width - w.width) / 2, y: size.height - (height + w.height) / 2), withAttributes: font)
    }

    private func tick() {
        n += 1
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let backgrounds = [NSColor.white, NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.88, green: 0.97, blue: 0.9, alpha: 1)]
        ctx.setFillColor(backgrounds[style % backgrounds.count].cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrsText: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]
        let bar = CGFloat(chrome.titleBarHeight) * 2
        drawTitleBar(ctx, height: bar)
        for line in 1 ..< 20 {
            ("Line \(line): the quick brown fox jumps over the lazy dog — \(label)" as NSString)
                .draw(at: CGPoint(x: 40, y: size.height - bar - 20 - CGFloat(line) * 44), withAttributes: attrsText)
        }
        ("frame \(n)" as NSString).draw(at: CGPoint(x: size.width - 260, y: 30), withAttributes: attrsText)
        // Each test window animates differently, so a mix-up between streams shows at a glance.
        let travelX = max(1, Int(size.width) - 120), travelY = max(1, Int(size.height - bar) - 120)
        switch style % 3 {
        case 0: // a blue box sliding left to right
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: CGFloat(n * 8 % travelX), y: 100, width: 120, height: 120))
        case 1: // an orange disc bouncing diagonally
            func bounce(_ v: Int, _ range: Int) -> CGFloat { let p = v % (2 * range); return CGFloat(p < range ? p : 2 * range - p) }
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            ctx.fillEllipse(in: CGRect(x: bounce(n * 7, travelX), y: bounce(n * 5, travelY), width: 120, height: 120))
        default: // a purple bar sweeping top to bottom, changing width
            ctx.setFillColor(NSColor.systemPurple.cgColor)
            let w = 120 + CGFloat(n % 60) * 4
            ctx.fill(CGRect(x: 40, y: size.height - bar - CGFloat(n * 6 % travelY) - 60, width: min(w, size.width - 80), height: 60))
        }
        if let panel { drawPanel(ctx, panel) }
        // The frame number as squares, which `wisp e2e` reads back to tell a live picture from a frozen one.
        FrameCode.draw(n, in: ctx, heightPx: size.height, scale: 2)
        NSGraphicsContext.current = nil
        CVPixelBufferUnlockBaseAddress(pb, [])
        onFrame?(pb, nowMicros())
    }
}

/// The synthetic host's out-of-process panel: where it is over its window (window points, top-left
/// origin) and its buttons (panel points).
struct SyntheticPanel {
    let id: UInt32
    let frame: CGRect
    let title: String
    /// The made-up service that "draws" it, named like the real one: "Synth Panel Service (Synth Alpha)".
    let owner: String
    let since = Date()
    var open: CGRect { CGRect(x: frame.width - 16 - 84, y: frame.height - 14 - 28, width: 84, height: 28) }
    var cancel: CGRect { open.offsetBy(dx: -96, dy: 0) }
    /// "Open" or "Cancel" if window point `pt` is on that button.
    func button(at pt: CGPoint) -> String? {
        let local = CGPoint(x: pt.x - frame.minX, y: pt.y - frame.minY)
        return open.insetBy(dx: -2, dy: -2).contains(local) ? "Open" : cancel.insetBy(dx: -2, dy: -2).contains(local) ? "Cancel" : nil
    }
}

/// mach_absolute_time ticks → µs (the clock CLOCK_UPTIME_RAW and nowMicros() use).
func machToMicros(_ t: UInt64) -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return t * UInt64(tb.numer) / UInt64(tb.denom) / 1000
}
