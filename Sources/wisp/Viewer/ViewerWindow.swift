// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// Shows the shared window and sends this Mac's mouse and keyboard back to the host.
///
/// The local window shows no title bar of its own: the remote window's title bar acts as this
/// window's. From the chrome geometry the host sends, drags on the remote title bar move this window.
/// This window's own traffic lights are AppKit's, at AppKit's own place and size (an empty unified
/// toolbar gives them the toolbar-window size when the remote has a toolbar-style title bar). The
/// remote traffic lights, and macOS 27's screen-sharing badge around them, are hidden under a patch
/// of the remote title bar's own colour, and clicks there never reach the remote. Red closes the
/// remote window (through Accessibility on the host, which then says it's gone).
///
/// With a host that supports resizing, 1 remote point is drawn as `scale` (normally 1) local points,
/// anchored at the top-left: while the window is being resized and the remote hasn't caught up yet,
/// the last frame is cropped or bordered by background, never stretched. Older hosts can't follow a
/// resize, so their video is stretched to fill the window, which keeps the remote aspect ratio.
final class RemoteView: NSView {
    let link: StreamLink
    /// The stream this view shows; nil until the host has opened it.
    var stream: ViewerStream? {
        didSet { let l = stream.map { "stream #\($0.id)" } ?? "a window"; frameLock.lock(); label = l; frameLock.unlock() }
    }
    var remoteSize = CGSize(width: 16, height: 10) { didSet { needsLayout = true } }
    /// Local points per remote point (below 1 only when the remote window is bigger than this screen).
    var scale: CGFloat = 1 { didSet { needsLayout = true } }
    /// Remote pixels per remote point (2 for a HiDPI host).
    var pixelsPerPoint: CGFloat = 2 { didSet { needsLayout = true } }
    /// Stretch the video over the whole window (hosts that can't be resized from here).
    var stretch = true { didSet { needsLayout = true } }
    /// The remote window's chrome, or nil when the host didn't send it (older host, no Accessibility).
    /// Then the top 28 pt drag the window and the local traffic lights appear on hover.
    var chrome: WindowChrome? { didSet { needsLayout = true; updateStandardButtons(); badgeColorSampledAt = .distantPast } }
    var isFullScreen = false { didSet { updateLayerStyle(); needsLayout = true; updateStandardButtons() } }
    var cornerRadius: CGFloat = 10 { didSet { updateLayerStyle() } }
    var onFrameShown: (() -> Void)?
    /// Every frame as it is put on screen (`wisp e2e` reads the frame counter from it). Main queue.
    var frameTap: ((CVPixelBuffer) -> Void)?
    private var current: CVPixelBuffer? // keep the shown buffer alive so the decoder can't reuse it mid-display
    private let video = CALayer()
    /// Hides the remote traffic lights and macOS's screen-sharing badge (a pill a little wider than
    /// them): a rounded rect in the remote title bar's own colour. This window's own buttons, wherever
    /// AppKit puts them, are drawn above it (they live in the title bar container, above this view).
    private let badgeCover = CALayer()
    private var badgeColorSampledAt = Date.distantPast
    private var framePixels: CGSize? // size of the frame on screen
    private let pill = StatusPill()
    private var pillTop: NSLayoutConstraint!

    // Pointer motion and scrolling are coalesced to at most 60 messages/s.
    private var pendingMove: (UInt16, UInt16)?
    private var pendingDragButton: UInt8?
    private var scrollAcc = CGPoint.zero
    private var scrollPhase: UInt8 = 0, scrollMomentum: UInt8 = 0
    /// What the pending scroll is: line deltas (a wheel, ×16 on the wire) or points, and where.
    private var scrollLines = false
    private var scrollAt: (UInt16, UInt16) = (0, 0)
    private var heldKeys = Set<UInt16>()
    private var flushTimer: Timer?

    init(link: StreamLink) {
        self.link = link
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        wantsLayer = true
        layer!.masksToBounds = true
        layer!.cornerCurve = .continuous
        video.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        video.contentsGravity = .resize
        layer!.addSublayer(video)
        badgeCover.isHidden = true
        layer!.addSublayer(badgeCover)
        outline.zPosition = 10
        layer!.addSublayer(outline)
        updateLayerStyle()
        // In every run loop mode: coalesced moves and scrolls must not wait out a tracking loop (a live resize, a menu).
        let flushTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(flushTimer, forMode: .common)
        self.flushTimer = flushTimer

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alphaValue = 0
        addSubview(pill)
        pillTop = pill.topAnchor.constraint(equalTo: topAnchor, constant: 36)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor), pillTop,
            pill.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func stop() { flushTimer?.invalidate(); press.timer?.invalidate() }

    /// Rounded corners like any window, except in full screen (black bars around the letterboxed video).
    /// In a window, area the remote hasn't drawn yet shows the window background.
    /// A thin teal frame (the icon's teal) marking the window as remote, for people who don't watch
    /// the Dock: full strength while key, faded otherwise, none in full screen. Defaults key
    /// `outlineRemoteWindows` (on unless set to false).
    private let outline = CALayer()
    static let outlineColor = NSColor(srgbRed: 0.17, green: 0.78, blue: 0.72, alpha: 1)

    func updateOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let enabled = Brand.defaults.object(forKey: "outlineRemoteWindows") as? Bool ?? true
        outline.isHidden = !enabled || isFullScreen
        outline.frame = bounds
        outline.cornerRadius = isFullScreen ? 0 : cornerRadius
        outline.borderWidth = 1.5
        outline.borderColor = Self.outlineColor.withAlphaComponent(window?.isKeyWindow == false ? 0.45 : 0.95).cgColor
    }

    private func updateLayerStyle() {
        updateOutline()
        layer!.cornerRadius = isFullScreen ? 0 : cornerRadius
        var bg = NSColor.black.cgColor
        if !isFullScreen { effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor } }
        layer!.backgroundColor = bg
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayerStyle() }

    override var mouseDownCanMoveWindow: Bool { false } // only the remote title bar moves it, below

    override func layout() {
        super.layout()
        pillTop.constant = bounds.maxY - titleBarRect().minY + 8
        layoutVideo()
        layoutBadgeCover()
        sizeStandardButtons()
        updateOutline()
    }

    /// The remote traffic lights plus the badge's margin, in remote points (top-left origin); nil
    /// without chrome, without remote buttons, or in full screen (no badge there: the window is the screen).
    private func coveredRect() -> CGRect? {
        guard let c = chrome, !isFullScreen else { return nil }
        let rects = [c.close, c.minimize, c.zoom].filter { $0 != .zero }
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        // The badge reaches ~12 pt past the buttons on the sides and sits a little low: ~6 pt above
        // them, ~10 pt below (measured on macOS 27).
        var pad = union.insetBy(dx: -14, dy: -6)
        pad.size.height += 4
        return pad
    }

    /// Over the remote traffic lights and the badge, under this window's own buttons.
    private func layoutBadgeCover() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let pad = coveredRect() else { badgeCover.isHidden = true; return }
        let r = local(pad)
        badgeCover.frame = r
        badgeCover.cornerRadius = r.height / 2
        badgeCover.isHidden = badgeCover.backgroundColor == nil
    }

    /// The title bar's dominant colour, read from the frame just right of the traffic lights:
    /// the most common of a few samples there, so a stray icon or text pixel doesn't win.
    private func sampleBadgeColor(_ pb: CVPixelBuffer) {
        guard let c = chrome, c.zoom != .zero || c.close != .zero, remoteSize.width > 0,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return }
        let right = (c.zoom != .zero ? c.zoom : c.close)
        let k = CGFloat(CVPixelBufferGetWidth(pb)) / remoteSize.width
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var counts: [UInt32: Int] = [:]
        for dx in stride(from: CGFloat(18), through: 66, by: 6) {
            for dy in [-4, 0, 4] as [CGFloat] {
                let x = Int(((right.maxX + dx) * k).rounded()), y = Int(((right.midY + dy) * k).rounded())
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                // Quantise a little so anti-aliasing noise doesn't split the vote.
                let key = UInt32(p[2] & 0xFC) << 16 | UInt32(p[1] & 0xFC) << 8 | UInt32(p[0] & 0xFC)
                counts[key, default: 0] += 1
            }
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return }
        // In the frame's own colour space, as the video layer draws it; plain sRGB came out visibly off.
        let space = CVImageBufferGetColorSpace(pb)?.takeUnretainedValue()
            ?? CVBufferCopyAttachments(pb, .shouldPropagate).flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let comps: [CGFloat] = [CGFloat(top >> 16 & 0xFF) / 255, CGFloat(top >> 8 & 0xFF) / 255, CGFloat(top & 0xFF) / 255, 1]
        guard let color = CGColor(colorSpace: space, components: comps) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeCover.backgroundColor = color
        CATransaction.commit()
        layoutBadgeCover()
    }

    /// Where the frame on screen is drawn. Its own size (it may lag behind the remote window's while
    /// resizing) at `scale`, from the top-left; stretched for old hosts; letterboxed in full screen.
    private func layoutVideo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let px = framePixels, px.width > 0, px.height > 0 else { video.frame = bounds; return }
        let pts = CGSize(width: px.width / pixelsPerPoint, height: px.height / pixelsPerPoint)
        if isFullScreen {
            video.frame = fit(pts, in: bounds)
        } else if stretch {
            video.frame = bounds
        } else {
            video.frame = CGRect(x: 0, y: bounds.maxY - pts.height * scale, width: pts.width * scale, height: pts.height * scale)
        }
    }

    private func fit(_ size: CGSize, in r: CGRect) -> CGRect {
        let s = min(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: r.minX + (r.width - w) / 2, y: r.minY + (r.height - h) / 2, width: w, height: h)
    }

    /// Shows or hides the status pill (connection state, host warnings, stats while ⌥ is held).
    func setStatus(_ text: String, visible: Bool) {
        pill.text = text
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; pill.animator().alphaValue = visible ? 1 : 0 }
    }

    // Decoded frames arrive on the network queue. Only the newest is shown: if the main thread
    // falls behind, stale frames are dropped instead of queueing up behind it.
    private let frameLock = NSLock()
    private var newest: (CVPixelBuffer, FrameTiming)?
    private var showScheduled = false

    // For DisplayWatch, under frameLock: frames handed over and shown, and since when a frame has
    // been waiting to be shown (µs; 0 = none waiting).
    private var enqueued = 0, shown = 0
    private var waitingSince: UInt64 = 0, lastShownAt: UInt64 = 0

    func enqueue(_ pb: CVPixelBuffer, _ timing: FrameTiming) {
        frameLock.lock()
        newest = (pb, timing)
        enqueued += 1
        let first = enqueued == 1
        if waitingSince == 0 { waitingSince = nowMicros() }
        let schedule = !showScheduled
        showScheduled = true
        frameLock.unlock()
        if first { DisplayWatch.add(self) }
        guard schedule else { return }
        scheduleShow()
    }

    private func scheduleShow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let pb = self.newest
            self.newest = nil
            self.showScheduled = false
            if pb != nil { self.shown += 1; self.lastShownAt = nowMicros() }
            self.waitingSince = 0
            self.frameLock.unlock()
            if let (pb, timing) = pb {
                self.show(pb)
                self.link.frameDisplayed(timing)
            }
        }
    }

    /// For DisplayWatch (any queue): how long the newest frame has waited to be shown (s, 0 = none
    /// waiting), frames handed over and shown, and the last one shown (µs).
    var displayState: (waiting: Double, enqueued: Int, shown: Int, lastShown: UInt64, scheduled: Bool) {
        frameLock.lock(); defer { frameLock.unlock() }
        let now = nowMicros()
        let w = waitingSince > 0 && now > waitingSince ? Double(now - waitingSince) / 1_000_000 : 0
        return (w, enqueued, shown, lastShownAt, showScheduled)
    }

    /// DisplayWatch: frames wait although the main thread answers: schedule the show again.
    func rescheduleShow() {
        frameLock.lock(); showScheduled = true; frameLock.unlock()
        scheduleShow()
    }
    private var label = "a window" // under frameLock
    var streamLabel: String { frameLock.lock(); defer { frameLock.unlock() }; return label }

    private func show(_ pb: CVPixelBuffer) {
        current = pb
        let px = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.contents = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        if px != framePixels { framePixels = px; layoutVideo() }
        CATransaction.commit()
        if Date().timeIntervalSince(badgeColorSampledAt) > 0.5 {
            badgeColorSampledAt = Date()
            sampleBadgeColor(pb)
        }
        onFrameShown?()
        frameTap?(pb)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Where the remote window is, in view coordinates (input and chrome are mapped through this).
    private func videoRect() -> CGRect {
        if isFullScreen { return fit(remoteSize, in: bounds) }
        if stretch { return bounds }
        let w = remoteSize.width * scale, h = remoteSize.height * scale
        return CGRect(x: 0, y: bounds.maxY - h, width: w, height: h)
    }

    /// A rect in remote points (top-left origin) → view coordinates.
    private func local(_ r: CGRect) -> CGRect {
        let v = videoRect(), s = v.width / remoteSize.width
        return CGRect(x: v.minX + r.minX * s, y: v.maxY - r.maxY * s, width: r.width * s, height: r.height * s)
    }

    /// The strip that drags the window: the remote title bar, or the top 28 pt without chrome.
    private func titleBarRect() -> CGRect {
        guard let chrome else { return CGRect(x: 0, y: bounds.maxY - 28, width: bounds.width, height: 28) }
        return local(CGRect(x: 0, y: 0, width: remoteSize.width, height: CGFloat(chrome.titleBarHeight)))
    }

    /// `covered`: over the hidden remote traffic lights (part of the title bar, but never sent on).
    private enum Spot: Equatable { case covered, titleBar, content }

    private func spot(at p: CGPoint) -> Spot {
        if let r = coveredRect(), local(r).contains(p) { return .covered }
        // In full screen the title bar is just part of the picture: there's no window to move.
        return !isFullScreen && titleBarRect().contains(p) ? .titleBar : .content
    }

    /// Without chrome from the host, the local traffic lights come back while the pointer is over the top strip.
    private var hoveringTitleBar = false { didSet { if hoveringTitleBar != oldValue { updateStandardButtons() } } }

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// This window's own traffic lights, where and as big as AppKit makes them: always shown once the
    /// remote chrome is known (the remote ones are covered) and in full screen; without chrome, while
    /// the pointer is over the top strip.
    func updateStandardButtons() {
        let shown = chrome != nil || isFullScreen || hoveringTitleBar
        for t in Self.buttonTypes { window?.standardWindowButton(t)?.isHidden = !shown }
        sizeStandardButtons()
    }

    /// AppKit's traffic lights are 14×14 pt in every window style; the remote app's (what the user
    /// compares against) are often 16×16. Keep the real buttons but draw them at the remote size:
    /// a larger frame over the native-size bounds scales their drawing (crisp, vector) and their
    /// click area, each grown around its own centre so AppKit's spacing is kept. Re-applied on every
    /// layout because AppKit resets the frames when it lays out the title bar.
    private var nativeButtonSize: CGFloat?

    private func sizeStandardButtons() {
        guard let window else { return }
        let buttons = Self.buttonTypes.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3 else { return }
        let native = nativeButtonSize ?? buttons[0].bounds.width
        nativeButtonSize = native
        var target = native
        if let c = chrome, c.close != .zero, !isFullScreen, remoteSize.width > 0 {
            let remote = local(c.close).width // remote points, at this window's scale
            target = min(max(remote.rounded(), native), native * 1.5)
        }
        for b in buttons {
            let side = b.frame.width
            guard abs(side - target) > 0.25 || abs(b.bounds.width - native) > 0.25 else { continue }
            let centre = NSPoint(x: b.frame.midX, y: b.frame.midY)
            b.setFrameSize(NSSize(width: target, height: target))
            b.setFrameOrigin(NSPoint(x: (centre.x - target / 2).rounded(), y: (centre.y - target / 2).rounded()))
            b.setBoundsSize(NSSize(width: native, height: native))
            b.needsDisplay = true
        }
    }

    /// Closes the remote window (for this window's own red button). False without chrome.
    func clickRemoteClose() -> Bool {
        guard let c = chrome, c.close != .zero else { return false }
        // Not a click: macOS draws its screen-sharing badge over the remote buttons, so a click there
        // hits the badge. The host presses the close button through Accessibility instead.
        flush()
        guard let stream else { return false }
        link.closeRemoteWindow(stream.id)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateStandardButtons()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: n, object: window)
            }
        }
        updateOutline()
    }

    @objc private func keyChanged() { updateOutline() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// Event position -> 0...65535 across the remote window.
    private func norm(_ e: NSEvent) -> (UInt16, UInt16) {
        let p = convert(e.locationInWindow, from: nil), v = videoRect()
        let x = (p.x - v.minX) / v.width
        let y = 1 - (p.y - v.minY) / v.height
        func q(_ v: CGFloat) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
        return (q(x), q(y))
    }

    private func button(_ e: NSEvent) -> UInt8 { UInt8(min(e.buttonNumber, 2)) }

    // Moves go to the remote only while this window is key: an inactive window doesn't steer the
    // remote pointer. Not over the covered remote traffic lights (they would light up under the cover,
    // and the badge would react); this window's own buttons show their hover glyphs themselves.
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hoveringTitleBar = titleBarRect().contains(p)
        guard window?.isKeyWindow == true else { return }
        if spot(at: p) == .covered { return }
        pendingMove = norm(e); pendingDragButton = nil
    }
    override func mouseExited(with e: NSEvent) { hoveringTitleBar = false }
    override func rightMouseDragged(with e: NSEvent) { pendingMove = norm(e); pendingDragButton = 1 }
    override func otherMouseDragged(with e: NSEvent) { pendingMove = norm(e); pendingDragButton = 2 }

    // MARK: Left button and the remote chrome
    //
    // A press on the title bar is held back. Moving more than 3 pt drags this window, and the remote
    // never sees the click. Letting go, or holding still for 150 ms, sends it on as a normal click, so
    // toolbar buttons that live in that strip still work. Over the covered remote traffic lights a
    // press drags or double-clicks like the title bar but is never sent on (it would hit the badge).
    // This window's own traffic lights are AppKit's buttons: their clicks never reach this view.

    private enum Press {
        case none
        case held(NSEvent, Timer) // title bar press, not sent yet
        case forwarded            // the remote has the mouse-down; drags and the mouse-up follow it
        case forwardedTitle(NSEvent)          // a title-bar press sent on after 150 ms (it may still become a drag)
        case movingWindow(NSPoint, NSPoint)   // moving this window by hand: mouse and window origin at the start
        case covered(NSEvent)     // on the covered remote traffic lights: may become a drag, never sent
        case swallowed            // a window drag or a title-bar double-click: nothing more to send
        var timer: Timer? { if case .held(_, let t) = self { t } else { nil } }
    }
    private var press = Press.none

    override func mouseDown(with e: NSEvent) {
        press.timer?.invalidate()
        let at = spot(at: convert(e.locationInWindow, from: nil))
        switch at {
        case .titleBar where e.clickCount >= 2, .covered where e.clickCount >= 2:
            press = .swallowed
            titleBarDoubleClick()
        case .titleBar:
            let t = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in self?.sendHeld() }
            RunLoop.main.add(t, forMode: .common)
            press = .held(e, t)
        case .covered:
            press = .covered(e)
        case .content:
            press = .forwarded
            click(e, down: true)
        }
    }

    private func sendHeld() {
        guard case .held(let down, _) = press else { return }
        press = .forwardedTitle(down)
        click(down, down: true)
    }

    override func mouseDragged(with e: NSEvent) {
        switch press {
        case .held(let down, let t):
            let a = down.locationInWindow, b = e.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            t.invalidate()
            press = .swallowed
            window?.performDrag(with: down)
        case .covered(let down):
            let a = down.locationInWindow, b = e.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            press = .swallowed
            window?.performDrag(with: down)
        case .forwardedTitle(let down):
            // Held still, then dragged: still a window move. Let go of the remote press where it started
            // (so the remote window never moves) and move this window by hand.
            let a = down.locationInWindow, b = e.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            click(down, down: false)
            let start = NSEvent.mouseLocation, origin = window?.frame.origin ?? .zero
            press = .movingWindow(NSPoint(x: start.x - (b.x - a.x), y: start.y - (b.y - a.y)), origin)
            mouseDragged(with: e)
        case .movingWindow(let start, let origin):
            let now = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
        case .forwarded, .none:
            pendingMove = norm(e); pendingDragButton = 0
        case .swallowed:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let was = press
        press = .none
        switch was {
        case .held(let down, let t):
            t.invalidate()
            click(down, down: true)
            click(e, down: false)
        case .forwarded, .forwardedTitle:
            click(e, down: false)
        case .movingWindow, .covered:
            break
        case .swallowed, .none:
            break
        }
    }

    /// What double-clicking a title bar does, per System Settings > Desktop & Dock.
    private func titleBarDoubleClick() {
        let d = UserDefaults.standard
        switch d.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.miniaturize(nil)
        case "None", "Do Nothing": break
        case nil where d.bool(forKey: "AppleMiniaturizeOnDoubleClick"): window?.miniaturize(nil)
        default: window?.zoom(nil) // "Maximize", "Fill"
        }
    }

    // MARK: Other buttons, scrolling, keys: straight to the remote

    override func rightMouseDown(with e: NSEvent) { click(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { click(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { click(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { click(e, down: false) }

    private func click(_ e: NSEvent, down: Bool) {
        flush()
        let (x, y) = norm(e)
        sendInput(down ? .mouseDown : .mouseUp, discrete: down) { w in
            w.u8(button(e)); w.u8(UInt8(min(e.clickCount, 255))); w.u16(x); w.u16(y)
        }
    }

    // Scrolling. A wheel's deltas are lines (not precise): sent as 1/16 lines with flag bit 0 so the
    // host posts a line scroll and the app scrolls its own line height, as with a wheel of its own;
    // trackpads and Magic Mice send points. Each message says where the pointer is: the host
    // scrolls there, also for a window that isn't key (which sends no pointer moves).
    override func scrollWheel(with e: NSEvent) {
        let lines = !e.hasPreciseScrollingDeltas
        let k: CGFloat = lines ? 16 : 1
        let phase = UInt8(truncatingIfNeeded: e.phase.rawValue)
        let momentum = UInt8(truncatingIfNeeded: e.momentumPhase.rawValue)
        let changed = UInt8(NSEvent.Phase.changed.rawValue)
        let at = norm(e)
        // Never one message for two kinds of delta or two places.
        if lines != scrollLines || at != scrollAt {
            flushScroll()
            if lines != scrollLines { scrollAcc = .zero } // a fraction of a line isn't a fraction of a point
            scrollLines = lines
            scrollAt = at
        }
        // Trackpad gestures: "changed" events are coalesced like pointer motion, but gesture boundaries
        // (began, ended, momentum start/end…) go out immediately and in order, so the remote app sees
        // a real trackpad scroll.
        let boundary = (phase != 0 && phase != changed) || (momentum != 0 && momentum != changed)
        if boundary { flushScroll() }
        scrollAcc.x += e.scrollingDeltaX * k
        scrollAcc.y += e.scrollingDeltaY * k
        scrollPhase = phase
        scrollMomentum = momentum
        if boundary { flushScroll(force: true) }
    }

    /// Sends what has piled up, all of it: more than an i16 holds (a very fast flick) goes as several
    /// messages, the boundary phase on the first (a start) or the last (an end) and "changed" on the
    /// others, so a gesture still begins and ends exactly once. A fraction of a point or 1/16 line is
    /// kept for the next one.
    private func flushScroll(force: Bool = false) {
        var dx = Int(scrollAcc.x), dy = Int(scrollAcc.y)
        guard force || dx != 0 || dy != 0 else { return }
        scrollAcc.x -= CGFloat(dx); scrollAcc.y -= CGFloat(dy)
        let changed = UInt8(NSEvent.Phase.changed.rawValue)
        let limit = Int(Int16.max)
        var chunks: [(Int16, Int16)] = []
        repeat {
            let cx = max(-limit, min(limit, dx)), cy = max(-limit, min(limit, dy))
            chunks.append((Int16(cx), Int16(cy)))
            dx -= cx; dy -= cy
        } while dx != 0 || dy != 0
        func ongoing(_ p: UInt8) -> UInt8 { p == 0 ? 0 : changed }
        let starts = [1, 32].contains(scrollPhase) || scrollMomentum == 1
        for (i, c) in chunks.enumerated() {
            let boundaryHere = chunks.count == 1 || (starts ? i == 0 : i == chunks.count - 1)
            let p = boundaryHere ? scrollPhase : ongoing(scrollPhase), m = boundaryHere ? scrollMomentum : ongoing(scrollMomentum)
            sendInput(.scroll) { [scrollLines, scrollAt] in
                $0.i16(c.0); $0.i16(c.1); $0.u8(p); $0.u8(m)
                $0.u8(scrollLines ? 1 : 0); $0.u16(scrollAt.0); $0.u16(scrollAt.1)
            }
        }
    }

    private func flush() {
        if let (x, y) = pendingMove {
            if let b = pendingDragButton {
                sendInput(.mouseDrag) { $0.u8(b); $0.u16(x); $0.u16(y) }
            } else {
                sendInput(.mouseMove) { $0.u16(x); $0.u16(y) }
            }
            pendingMove = nil
        }
        flushScroll()
    }

    // Keyboard: every key goes to the remote, including Cmd-shortcuts. Close the window to stop.
    private static let modifierMasks: [UInt16: NSEvent.ModifierFlags] = [
        54: .command, 55: .command, 56: .shift, 60: .shift, 58: .option, 61: .option,
        59: .control, 62: .control, 57: .capsLock, 63: .function,
    ]

    func forwardKey(_ e: NSEvent) {
        let flags = UInt32(truncatingIfNeeded: e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
        let down: Bool
        switch e.type {
        case .keyDown: down = true
        case .keyUp: down = false
        case .flagsChanged:
            guard let mask = Self.modifierMasks[e.keyCode] else { return }
            down = e.modifierFlags.contains(mask)
        default: return
        }
        if down { heldKeys.insert(e.keyCode) } else { heldKeys.remove(e.keyCode) }
        sendKey(e.keyCode, down: down, flags: flags, timed: down && e.type == .keyDown)
    }

    /// If the viewer loses focus mid-shortcut, release everything so nothing sticks on the remote.
    func releaseHeldKeys() {
        for k in heldKeys { sendKey(k, down: false, flags: 0) }
        heldKeys.removeAll()
    }

    private func sendKey(_ code: UInt16, down: Bool, flags: UInt32, timed: Bool = false) {
        sendInput(.key, discrete: timed) { $0.u16(code); $0.u8(down ? 1 : 0); $0.u32(flags) }
    }

    /// Input for this view's stream (dropped until the window is bound to one).
    private func sendInput(_ type: MsgType, discrete: Bool = false, _ build: (inout Writer) -> Void) {
        guard let stream else { return }
        link.sendInput(stream.id, message(type, stream: stream.id, build), discrete: discrete)
    }

    /// Window > Stop Viewing: close this window here only; the remote window stays open.
    var onStopViewing: (() -> Void)?
    @objc func stopViewing(_ sender: Any?) { onStopViewing?() }
}

/// Small translucent capsule over the video for connection state and host warnings.
final class StatusPill: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer!.cornerRadius = 13
        layer!.cornerCurve = .continuous
        layer!.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ p: NSPoint) -> NSView? { nil } // clicks go through to the video
}
