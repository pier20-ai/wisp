// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import WispCommon

/// One streamed window that input is injected into: where it is, and how to reach it through Accessibility.
/// Main queue only.
final class WindowTarget {
    /// Window bounds in global display coordinates (points, top-left origin).
    var frame: CGRect = .zero
    var pid: pid_t = 0 { didSet { axWindow = nil } }
    var windowID: CGWindowID = 0 { didSet { axWindow = nil } }
    /// The last pointer position injected for this window (scrolls from older viewers happen there).
    var last: CGPoint?
    /// Where this window's scroll gesture is (Injector): apps must see each one begin and end.
    var gesture = ScrollGesture.none
    /// The last plain wheel tick: a burst of them is checked for a covered window once, not per tick.
    var lastWheel = Date.distantPast
    /// Panels shown with this window (Panels.swift): window ID → owning process (the app itself, or
    /// a panel service working for it). Input treats them as part of the window: they're never
    /// covered by raising the window, and keys may go to them.
    var panels: [CGWindowID: pid_t] = [:]
    private var axWindow: AXUIElement?

    /// The window as an Accessibility element: the app's window whose frame matches.
    /// nil without Accessibility or before the target is set.
    func ax() -> AXUIElement? {
        guard pid != 0 else { return nil }
        if let axWindow {
            if windowID != 0, let id = cgWindowID(of: axWindow) {
                if id == windowID { return axWindow }
            } else if axFrame(of: axWindow).map({ $0.equalTo(frame) || frame == .zero }) == true {
                return axWindow
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let all = value as? [AXUIElement] else { return nil }
        let windows = all.filter { axString($0, kAXRoleAttribute) == kAXWindowRole }
        // By window ID when we can: matching by frame picked a hidden helper window of Claude with the
        // same frame now and then, so its (different) traffic lights were reported as the shared window's.
        if windowID != 0, let exact = windows.first(where: { cgWindowID(of: $0) == windowID }) {
            axWindow = exact
        } else {
            axWindow = windows.min { a, b in distance(axFrame(of: a)) < distance(axFrame(of: b)) }
        }
        return axWindow
    }

    private func distance(_ r: CGRect?) -> CGFloat {
        guard let r else { return .infinity }
        return abs(r.minX - frame.minX) + abs(r.minY - frame.minY) + abs(r.width - frame.width) + abs(r.height - frame.height)
    }

    /// Where the window's traffic lights and title bar are, via Accessibility, in points relative to
    /// the window's top-left. `.unknown` without Accessibility or a matching AX window.
    func readChrome() -> WindowChrome {
        guard let w = ax(), let wf = axFrame(of: w) else { return .unknown }
        func button(_ attr: String) -> CGRect {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, attr as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXUIElementGetTypeID(), let f = axFrame(of: v as! AXUIElement), f.width > 0 else { return .zero }
            return f.offsetBy(dx: -wf.minX, dy: -wf.minY)
        }
        let close = button(kAXCloseButtonAttribute), minimize = button(kAXMinimizeButtonAttribute), zoom = button(kAXZoomButtonAttribute)
        // The title bar (or unified toolbar) is about as tall as the buttons are centred in it.
        let buttons = [close, minimize, zoom].filter { $0 != .zero }
        var height: CGFloat = 28
        if let top = buttons.map(\.minY).min(), let bottom = buttons.map(\.maxY).max() {
            height = max(28, bottom + max(0, top))
        }
        return WindowChrome(titleBarHeight: UInt16(clamping: Int(height.rounded())), close: close, minimize: minimize, zoom: zoom)
    }

    /// The viewer's red button: press the window's own close button through Accessibility.
    func pressClose() {
        guard pid != 0, let w = ax() else { log("close: window \(windowID) isn't reachable through Accessibility"); return }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &button) == .success, let button else {
            log("close: window \(windowID) has no close button"); return
        }
        let err = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        log("close: pressed window \(windowID)'s close button (\(err == .success ? "ok" : "error \(err.rawValue)"))")
    }

    var describe: String { "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))" }
}

/// A trackpad or Magic Mouse gesture in progress on one window: fingers down (`touch`), or the
/// momentum after them.
enum ScrollGesture { case none, touch, momentum }

func axString(_ e: AXUIElement, _ attr: String) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attr as CFString, &v)
    return v as? String ?? "?"
}

/// Replays the viewer's mouse and keyboard on this Mac, each event mapped into its stream's window.
/// Needs Accessibility permission for the process running `wisp send` (e.g. Terminal). Main queue only.
final class Injector {
    /// The synthetic host: nothing is posted. With a `sink`, every event is still built as it would be
    /// posted and handed to the sink instead (the synthetic host records what an app would receive).
    var dryRun = false
    var sink: ((CGEvent, WindowTarget) -> Void)?
    /// Dry run: a window was brought forward (or would have been), and why.
    var onRaise: ((WindowTarget, String) -> Void)?
    let events = Counter()
    /// Dry run with WISP_FAULT=focus-hold: play a host where input for a window that isn't in front
    /// raises it and holds input meanwhile, as on a real host (the window last raised counts as in
    /// front). focus-stuck: raising never takes (an app that can't be made frontmost).
    private static let simulatedFocus = Fault.has("focus-hold") || Fault.has("focus-stuck")
    private static let focusStuck = Fault.has("focus-stuck")
    private weak var simulatedFront: WindowTarget?
    /// Events are built (to post, or for the sink).
    private var building: Bool { !dryRun || sink != nil }

    private let src = CGEventSource(stateID: .hidSystemState)

    // While a window is being brought forward, input is held briefly so it lands there.
    private var held: [(CGEvent, WindowTarget)] = []
    private var holding = false
    private var holdSerial = 0
    private var keyTargetCheckedAt = Date.distantPast
    private weak var lastKeyTarget: WindowTarget?
    /// Run once held input has been replayed (a menu item waiting for its window to come forward).
    private var afterRelease: [() -> Void] = []

    /// Without Accessibility, posted events are dropped without an error: said once per change.
    private var axTrusted: Bool?
    /// The viewer's modifier keys, from its last key message. Mouse and scroll events carry them, not
    /// this Mac's own keyboard state (which an event made from the HID state source would): a Shift
    /// held here would turn the viewer's wheel scroll sideways, a ⌘ held there must reach a ⌘-click.
    private var viewerFlags = CGEventFlags()

    func handle(_ type: MsgType, _ payload: Data, target t: WindowTarget) {
        var r = Reader(payload)
        events.add(1)
        if !dryRun, type != .mouseMove, type != .mouseDrag {
            let trusted = AXIsProcessTrusted()
            if trusted != axTrusted {
                if !trusted { Log.warning(.input, "input arrives but Accessibility isn't allowed: macOS drops the clicks and keys") }
                else if axTrusted != nil { Log.info(.input, "Accessibility is allowed now: input goes through") }
                axTrusted = trusted
            }
        }
        switch type {
        case .mouseMove:
            guard let x = r.u16(), let y = r.u16() else { return }
            mouse(.mouseMoved, at: point(x, y, in: t), button: .left, target: t)
        case .mouseDrag:
            guard let b = r.u8(), let x = r.u16(), let y = r.u16() else { return }
            let ty: CGEventType = b == 0 ? .leftMouseDragged : b == 1 ? .rightMouseDragged : .otherMouseDragged
            mouse(ty, at: point(x, y, in: t), button: button(b), target: t)
        case .mouseDown, .mouseUp:
            guard let b = r.u8(), let clicks = r.u8(), let x = r.u16(), let y = r.u16() else { return }
            let down = type == .mouseDown
            Log.debug(.input, "mouse \(down ? "down" : "up") button \(b) ×\(clicks) in window \(t.windowID)")
            if down { ensureTarget(t, at: point(x, y, in: t)) }
            let ty: CGEventType = switch b {
            case 0: down ? .leftMouseDown : .leftMouseUp
            case 1: down ? .rightMouseDown : .rightMouseUp
            default: down ? .otherMouseDown : .otherMouseUp
            }
            mouse(ty, at: point(x, y, in: t), button: button(b), clicks: Int64(clicks), target: t)
        case .scroll:
            guard let dx = r.i16(), let dy = r.i16() else { return }
            let phase = r.u8() ?? 0, momentum = r.u8() ?? 0
            // Since the e2e test: flags (bit 0: deltas in 1/16 lines, from a wheel) and where the pointer is.
            let lines = (r.u8() ?? 0) & 1 != 0
            var at = t.last ?? CGPoint(x: t.frame.midX, y: t.frame.midY) // older viewers: where the pointer last was
            if let x = r.u16(), let y = r.u16() {
                at = point(x, y, in: t)
                // The window server scrolls whatever is under the pointer: put it where the user's is
                // (a viewer window that isn't key sends no moves, so it may be elsewhere).
                if t.last.map({ hypot($0.x - at.x, $0.y - at.y) > 0.5 }) ?? true { mouse(.mouseMoved, at: at, button: .left, target: t) }
            }
            scroll(t, dx: dx, dy: dy, phase: phase, momentum: momentum, lines: lines, at: at)
        case .key:
            guard let code = r.u16(), let down = r.u8(), let flags = r.u32() else { return }
            guard building, let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down != 0) else { return }
            e.flags = CGEventFlags(rawValue: UInt64(flags))
            viewerFlags = CGEventFlags(rawValue: UInt64(flags)).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift])
            if down != 0 { ensureKeyTarget(t) }
            post(e, t)
        default:
            break
        }
    }

    // MARK: Scrolling

    /// One scroll message, as the event an app would get from the same device here: a wheel's ticks
    /// as line deltas (apps scroll their own line height, and accelerate them as they do a local
    /// wheel), precise deltas in points, a gesture's phases and momentum as they came, so apps
    /// rubber-band, snap and end scrolls natively.
    private func scroll(_ t: WindowTarget, dx: Int16, dy: Int16, phase: UInt8, momentum: UInt8, lines: Bool, at: CGPoint) {
        let wheelTick = phase == 0 && momentum == 0
        // Scrolls go to the window under the pointer whether its app is in front or not (on any
        // Mac): no raise and no hold for them, unless another window covers the spot. Checked when a
        // gesture or a burst of wheel ticks starts, not on every tick.
        let starts = phase == 1 || phase == 32 || (wheelTick && Date().timeIntervalSince(t.lastWheel) > 0.3)
        if wheelTick { t.lastWheel = Date() }
        if starts { ensureUncovered(t, at: at) }
        if !wheelTick {
            // Apps must see a gesture begin before it changes: one whose start never came here (the
            // stream opened mid-gesture) gets one.
            if phase == 4 || phase == 2, t.gesture != .touch { postScroll(t, 0, 0, lines: false, phase: 1, momentum: 0, at: at) }
            if momentum == 4 || momentum == 2, t.gesture != .momentum { postScroll(t, 0, 0, lines: false, phase: 0, momentum: 1, at: at) }
            switch (phase, momentum) {
            case (1, _), (32, _): t.gesture = .touch
            case (8, _), (16, _): t.gesture = .none
            case (_, 1): t.gesture = .momentum
            case (_, 8), (_, 16): t.gesture = .none
            default: break
            }
        }
        postScroll(t, dx, dy, lines: lines, phase: phase, momentum: momentum, at: at)
    }

    private func postScroll(_ t: WindowTarget, _ dx: Int16, _ dy: Int16, lines: Bool, phase: UInt8, momentum: UInt8, at: CGPoint) {
        guard building else { return }
        let e: CGEvent?
        if lines {
            // 1/16 lines on the wire; macOS keeps a line delta's fraction in its fixed-point field.
            let ly = Double(dy) / 16, lx = Double(dx) / 16
            func whole(_ v: Double) -> Int32 { v == 0 ? 0 : v > 0 ? Int32(max(1, v.rounded())) : Int32(min(-1, v.rounded())) }
            e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: whole(ly), wheel2: whole(lx), wheel3: 0)
            let perLine = src?.pixelsPerLine ?? 10
            e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: ly)
            e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: lx)
            e?.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((ly * perLine).rounded()))
            e?.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64((lx * perLine).rounded()))
            e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        } else {
            e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        guard let e else { return }
        e.flags = viewerFlags
        e.location = at
        if phase != 0 || momentum != 0 {
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhase(phase))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(momentum))
        }
        post(e, t)
    }

    /// The viewer stopped sending to `t` (its stream closed, the viewer left) in the middle of a
    /// gesture: end it, so the app isn't left scrolling, rubber-banded or waiting for momentum.
    func endGestures(_ t: WindowTarget) {
        let at = t.last ?? CGPoint(x: t.frame.midX, y: t.frame.midY)
        switch t.gesture {
        case .touch: postScroll(t, 0, 0, lines: false, phase: 8, momentum: 0, at: at)
        case .momentum: postScroll(t, 0, 0, lines: false, phase: 0, momentum: 8, at: at)
        case .none: return
        }
        Log.debug(.input, "window \(t.windowID): ended a scroll gesture the viewer left open")
        t.gesture = .none
    }

    /// NSEvent.Phase raw value → CGScrollPhase (began 1, changed 2, ended 4, cancelled 8, mayBegin 128).
    private static func scrollPhase(_ p: UInt8) -> Int64 {
        switch p {
        case 1: 1
        case 2, 4: 2
        case 8: 4
        case 16: 8
        case 32: 128
        default: 0
        }
    }

    /// NSEvent.Phase raw value → CGMomentumScrollPhase (begin 1, continue 2, end 3).
    private static func momentumPhase(_ p: UInt8) -> Int64 {
        switch p {
        case 1: 1
        case 2, 4: 2
        case 8, 16: 3
        default: 0
        }
    }

    private func point(_ x: UInt16, _ y: UInt16, in t: WindowTarget) -> CGPoint {
        CGPoint(x: t.frame.minX + Double(x) / 65535 * t.frame.width,
                y: t.frame.minY + Double(y) / 65535 * t.frame.height)
    }

    private func button(_ b: UInt8) -> CGMouseButton { b == 0 ? .left : b == 1 ? .right : .center }

    private func mouse(_ ty: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int64 = 0, target t: WindowTarget) {
        t.last = p
        guard building, let e = CGEvent(mouseEventSource: src, mouseType: ty, mouseCursorPosition: p, mouseButton: button) else { return }
        if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.flags = viewerFlags
        post(e, t)
    }

    private func post(_ e: CGEvent, _ t: WindowTarget) {
        if holding { held.append((e, t)) } else { deliver(e, t) }
    }

    private func deliver(_ e: CGEvent, _ t: WindowTarget) {
        if dryRun { sink?(e, t) } else { e.post(tap: .cghidEventTap) }
    }

    // MARK: Keeping the target window in front
    //
    // Injected events go wherever the window server sends real ones: clicks to the topmost window
    // under the pointer, keys to the frontmost app's key window. So before a click, a scroll or a
    // key press for a stream, make sure that is the stream's window: "the window", not just "its app".
    // Mouse moves (hover) don't raise anything: each streamed window has a virtual display of its own,
    // so nothing covers it (with --no-virtual-display they share a display and may overlap; hover then
    // goes to whatever is on top). NSRunningApplication.activate()
    // is ignored when called from a background app (macOS 14+), so this goes through Accessibility.

    /// Before a scroll at `p`: only another window covering the spot is in the way (with a virtual
    /// display per streamed window, none is).
    private func ensureUncovered(_ t: WindowTarget, at p: CGPoint) {
        guard dryRun ? Self.simulatedFocus : t.pid != 0 else { return }
        if holding || topmostIsTarget(t, at: p) { return } // while holding, it's queued behind the raise already
        bringForward(t, reason: "scroll at a spot covered by another window")
    }

    /// Before a click at `p`.
    private func ensureTarget(_ t: WindowTarget, at p: CGPoint) {
        guard dryRun ? Self.simulatedFocus : t.pid != 0 else { return }
        if isFrontmost(t) && topmostIsTarget(t, at: p) { return }
        bringForward(t, reason: "input at a spot covered by another window")
    }

    /// Before a key press. Checked at most every 0.5 s while typing into the same window, since it costs
    /// an AX round trip; at once when the keys start going to another stream.
    private func ensureKeyTarget(_ t: WindowTarget) {
        guard dryRun ? Self.simulatedFocus : t.pid != 0 else { return }
        if lastKeyTarget !== t { lastKeyTarget = t; keyTargetCheckedAt = .distantPast }
        if !isFrontmost(t) { bringForward(t, reason: "key press while another app was in front"); return }
        guard !dryRun else { return }
        guard Date().timeIntervalSince(keyTargetCheckedAt) > 0.5 else { return }
        keyTargetCheckedAt = Date()
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(t.pid)
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let target = t.ax(), !CFEqual(focused, target) {
            // The window's panel (an Open panel, a dialog) has focus: that's where its keys belong.
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), let id = cgWindowID(of: focused as! AXUIElement),
               t.panels[id] != nil { return }
            bringForward(t, reason: "key press while another of its windows had focus")
        }
    }

    /// Before choosing a menu item for stream window `t`: brings it forward as a key press would
    /// (always checking, not throttled), then calls `then` (on main) once it's there.
    func bringToFront(_ t: WindowTarget, then: @escaping () -> Void) {
        guard !dryRun, t.pid != 0 else { then(); return }
        lastKeyTarget = nil
        ensureKeyTarget(t)
        if holding { afterRelease.append(then) } else { then() }
    }

    /// Before choosing a menu item with no window in particular: makes app `pid` frontmost.
    func activate(pid: pid_t, then: @escaping () -> Void) {
        guard !dryRun, focusedPID() != pid else { then(); return }
        let err = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        log("focus: menu item chosen while \(appName(focusedPID())) was focused; AX frontmost \(err.rawValue) on \(appName(pid))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: then)
    }

    /// The window's app has focus, or a process showing one of its panels does.
    private func isFrontmost(_ t: WindowTarget) -> Bool {
        if dryRun { return simulatedFront === t }
        let f = focusedPID()
        return f == t.pid || (f.map { t.panels.values.contains($0) } ?? false)
    }

    /// The app with keyboard focus, per Accessibility. NSWorkspace.frontmostApplication can go stale
    /// in `wisp send`, which runs without an NSApplication event loop.
    private func focusedPID() -> pid_t? {
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var p: pid_t = 0
        AXUIElementGetPid(app as! AXUIElement, &p)
        return p
    }

    private func appName(_ p: pid_t?) -> String {
        p.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
    }

    /// Whether the frontmost window under `p` is the target window. Its app's menus and popovers count,
    /// and so does a sheet or panel of its app that lies within it; another ordinary window doesn't,
    /// even one of the same app (another streamed window, say).
    private func topmostIsTarget(_ t: WindowTarget, at p: CGPoint) -> Bool {
        if dryRun { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]] else { return true }
        for w in list { // front to back
            guard let b = w[kCGWindowBounds] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  (w[kCGWindowAlpha] as? Double ?? 1) > 0 else { continue }
            if let id = w[kCGWindowNumber] as? CGWindowID, id == t.windowID || t.panels[id] != nil { return true }
            let layer = w[kCGWindowLayer] as? Int ?? 0
            if (w[kCGWindowOwnerPID] as? pid_t) == t.pid {
                if layer != 0 { return true }
                return t.frame.insetBy(dx: -2, dy: -2).contains(r)
            }
            if layer == 0 { return false } // another app's ordinary window is on top
        }
        return true
    }

    private func bringForward(_ t: WindowTarget, reason: String) {
        if dryRun {
            onRaise?(t, reason)
            Log.debug(.input, "FAULT focus: window \(t.windowID) brought forward (\(reason))\(holding ? " (already holding)" : "")")
            guard !holding else { return }
            holding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                if !Self.focusStuck { simulatedFront = t }
                release()
            }
            return
        }
        let before = focusedPID()
        let app = AXUIElementCreateApplication(t.pid)
        let front = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var raised = AXError.failure
        var what = "no AX window"
        // With a panel open, raise the panel: raising the window (and making it main) could put it
        // over its own modal panel, and the panel is where clicks and keys belong now.
        if let (id, owner) = t.panels.first, let p = PanelTracker.axWindow(id: id, pid: owner) {
            raised = AXUIElementPerformAction(p, kAXRaiseAction as CFString)
            what = "its panel \(id) (\(axString(p, kAXTitleAttribute)))"
        } else if let w = t.ax() {
            raised = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            what = "\(axString(w, kAXRoleAttribute)) \"\(axString(w, kAXTitleAttribute))\" \(axFrame(of: w).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "")"
        }
        log("focus: \(reason); \(appName(before)) was focused. AX frontmost \(front.rawValue), raise \(raised.rawValue) on \(what) (window \(t.windowID) at \(t.describe))")

        // Hold input until the window server has caught up, then replay it in order.
        guard !holding else { return }
        holding = true
        holdSerial &+= 1
        let serial = holdSerial
        // Never for long: an activation that doesn't finish (LaunchServices not answering) would
        // otherwise hold every click, key and scroll from then on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            DisplayGate.whenIdle { [weak self] in
                guard let self, self.holding, self.holdSerial == serial else { return }
                var stall = StallEpisode("input to window \(t.windowID)", .input)
                stall.begin("held 1.0 s for the window to come forward (\(self.held.count) events queued) and it hasn't finished")
                stall.act("replayed the held input without waiting any longer")
                self.release()
                stall.end("input flows again")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            // Not in the middle of adding or removing a virtual display (an AX call then could deadlock).
            DisplayGate.whenIdle { self?.finishBringingForward(t) }
        }
    }

    private func finishBringingForward(_ t: WindowTarget) {
        if isFrontmost(t) {
            release()
            return
        }
        // Accessibility didn't take: ask LaunchServices, as `open -a` does.
        log("focus: still \(appName(focusedPID())) after AX; activating through LaunchServices")
        guard let url = NSRunningApplication(processIdentifier: t.pid)?.bundleURL else { release(); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                DisplayGate.whenIdle {
                    log("focus: now \(self.appName(self.focusedPID()))")
                    self.release()
                }
            }
        }
    }

    private func release() {
        holding = false
        let events = held
        held = []
        events.forEach { deliver($0.0, $0.1) }
        let then = afterRelease
        afterRelease = []
        then.forEach { $0() }
    }
}

// The CGWindowID behind an Accessibility window element. `_AXUIElementGetWindow` is private but has
// been stable for over a decade and is what window managers (Rectangle, AltTab, yabai) use; looked up
// at run time so a missing symbol just means falling back to matching by frame.
private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let axGetWindow: AXGetWindow? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(sym, to: AXGetWindow.self)
}()

func cgWindowID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    guard let f = axGetWindow, f(element, &id) == .success, id != 0 else { return nil }
    return id
}
