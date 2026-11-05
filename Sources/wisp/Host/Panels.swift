// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

// Panels of a streamed app that the stream has to show (docs/multi-window.md §13).
//
// What macOS 27.2 actually does (probed with a test app): an Open or Save panel's window is in the
// *app's* window list (owner = the app, layer 0, AXStandardWindow with AXIdentifier "open-panel" /
// "save-panel" and no close button), but its contents are drawn by an XPC service launched for that
// app: com.apple.appkit.xpc.openAndSavePanelService, named "Open and Save Panel Service (<App>)",
// with a QuickLookUIService ("QuickLookUIService (Open and Save Panel Service (<App>))") for its
// previews. Both are "responsible" to the app (`responsibility_get_pid_responsible_for_pid`), as any
// XPC service launched on an app's behalf is; system-wide UI (AutoFillPanelService, ViewBridge's
// auxiliary, UserNotificationCenter with the permission prompts) is responsible for itself. As a
// sheet, the panel is an AXSheet of the window (identifier "open-panel") and moves with it; on its
// own (Electron's dialog.showOpenDialog without a window, NSOpenPanel.begin) it is centred on the
// main display, outside the stream's crop. The colour and font panels are in-process
// AXFloatingWindows (layer 3) at their own remembered places; alerts and the print panel are
// in-process sheets.
//
// So, every 0.25 s while a real window is streamed, the tracker lists the on-screen windows and
// takes as a stream's panel any window that is not streamed itself and is either
// - owned by a process responsible to the stream's app (an out-of-process panel or preview), or
// - owned by the app and, per Accessibility, an Open/Save panel, a dialog (AXDialog, AXSystemDialog),
//   a modal window, or a floating panel (AXFloatingWindow) that opened while the app was streamed.
// It is associated with one stream of that app (the one it lies over, else the one that got input
// last, else the app's first), never with another app's stream; moved over the stream's window if
// it isn't inside it already; its owner's windows are added to the stream's capture filter; and
// the injector treats it as part of the stream's window (WindowTarget.panels). It uses no stream.

/// Bundle IDs of per-app UI services, by what they show (for the log; the association itself is by
/// responsibility, so an unknown service of the app is still found).
enum PanelServices {
    static let openSave = "com.apple.appkit.xpc.openAndSavePanelService"
    static let known: [String: String] = [
        openSave: "Open/Save panel service",
        "com.apple.quicklook.QuickLookUIService": "Quick Look preview service",
    ]
    /// AXIdentifier of AppKit's Open and Save panels (window or sheet).
    static let panelIdentifiers: Set<String> = ["open-panel", "save-panel"]
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
// Private but long-standing (it's how TCC attributes an XPC service's requests to its app); looked
// up at run time so a missing symbol only means falling back to the "(<App>)" in the service's name.
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

/// The process responsible for `pid` (the app an XPC service was launched for; itself for an app or
/// a daemon). nil if unknown.
func responsiblePID(of pid: pid_t) -> pid_t? {
    guard let f = responsibleFn else { return nil }
    let r = f(pid)
    return r > 0 ? r : nil
}

/// Where a panel of `size` goes over window `w` (global points): centred horizontally, just below
/// the title bar, like a sheet. On an axis where it doesn't fit it overflows: to the left (its
/// right edge on the window's, so the Open/Cancel buttons stay in view) and upwards (its bottom on
/// the window's bottom). The window is never resized for it: that would resize the viewer's window
/// too and have to be undone, and it may already be as large as its display.
enum PanelPlacement {
    static func frame(size: CGSize, in w: CGRect, titleBar: CGFloat) -> CGRect {
        let x = size.width <= w.width ? w.minX + ((w.width - size.width) / 2).rounded() : w.maxX - size.width
        let y = size.height <= w.height - titleBar ? w.minY + titleBar : w.maxY - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The size to ask a panel that is larger than the window for (it may refuse below its minimum).
    static func fitted(_ size: CGSize, in w: CGRect, titleBar: CGFloat) -> CGSize {
        CGSize(width: min(size.width, w.width), height: min(size.height, max(w.height - titleBar, w.height * 0.6)))
    }

    /// Already within the window (a sheet, a dialog the app put there, or one we moved).
    static func inside(_ panel: CGRect, _ w: CGRect) -> Bool { w.insetBy(dx: -1, dy: -1).contains(panel) }
}

/// A panel shown with a stream. Main queue.
final class StreamPanel {
    let id: CGWindowID
    let ownerPID: pid_t
    /// "Open and Save Panel Service (Claude)", or the app's name for its own panel.
    let owner: String
    /// What it is: "open/save panel", "dialog", "Quick Look preview service window", …
    let kind: String
    var frame: CGRect
    let since = Date()
    /// Where we last put it (a panel larger than the window stays outside it; don't move it again).
    var placed: CGRect?
    var moves = 0
    init(id: CGWindowID, ownerPID: pid_t, owner: String, kind: String, frame: CGRect) {
        self.id = id; self.ownerPID = ownerPID; self.owner = owner; self.kind = kind; self.frame = frame
    }
    var describe: String { "\(kind) \(id) of \(owner)" }
}

/// Finds the panels of streamed apps, associates each with a stream, moves it over that stream's
/// window and keeps WindowTarget.panels up to date. Main queue; its WindowServer and Accessibility
/// calls only while no virtual display is being added or removed.
final class PanelTracker {
    private enum Verdict { case panel(String), notPanel }
    /// By window ID (never reused while the system runs).
    private var verdicts: [CGWindowID: Verdict] = [:]
    /// Windows Accessibility doesn't list (yet): how many times we looked.
    private var unlisted: [CGWindowID: Int] = [:]
    /// The windows each streamed app already had when we first looked: a floating panel among them
    /// (an inspector, a palette) is left where it is; only one opened while streaming comes along.
    private var baseline: [pid_t: Set<CGWindowID>] = [:]
    private var responsible: [pid_t: pid_t?] = [:]
    /// Gave up moving (Accessibility refused, or the app keeps moving it back): logged once.
    private var gaveUp: Set<CGWindowID> = []

    /// One pass over `streams` (the real ones; the synthetic host has its own panel). `lastInput`
    /// names the stream of an app that got input last, and when. Returns the apps whose capture
    /// filters need refreshing (a panel of another process of theirs appeared).
    func tick(streams all: [HostStream], lastInput: (String) -> (stream: UInt16, at: Date)?) -> Set<pid_t> {
        let live = all.filter { !$0.closed && !$0.gone && $0.capture != nil && $0.synthetic == nil && $0.pid != 0 }
        guard !live.isEmpty else {
            baseline = [:]
            all.forEach { s in if !s.panels.isEmpty { s.panels = [:]; s.target.panels = [:] } }
            return []
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        let streamed = Set(all.filter { !$0.closed }.map(\.windowID))
        let pids = Set(live.map(\.pid))
        let names = Dictionary(live.map { ($0.appName, $0.pid) }, uniquingKeysWith: { a, _ in a })
        let me = getpid()
        for p in pids where baseline[p] == nil {
            baseline[p] = Set(list.compactMap { ($0[kCGWindowOwnerPID] as? pid_t) == p ? $0[kCGWindowNumber] as? CGWindowID : nil })
        }
        for p in baseline.keys where !pids.contains(p) { baseline[p] = nil }

        var refresh = Set<pid_t>()
        var present = Set<CGWindowID>()
        for w in list {
            guard let id = w[kCGWindowNumber] as? CGWindowID, !streamed.contains(id),
                  let owner = w[kCGWindowOwnerPID] as? pid_t, owner != me,
                  let b = w[kCGWindowBounds] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: b),
                  frame.width >= 60, frame.height >= 40, (w[kCGWindowAlpha] as? Double ?? 1) > 0 else { continue }
            // Ordinary, floating and modal-panel levels; not menus (101), pop-ups, tooltips or overlays.
            let layer = w[kCGWindowLayer] as? Int ?? 0
            guard layer >= 0, layer < 20 else { continue }
            let ownerName = w[kCGWindowOwnerName] as? String ?? "?"
            let app: pid_t
            if pids.contains(owner) {
                app = owner
            } else if let r = responsibleApp(of: owner, name: ownerName, names: names), pids.contains(r) {
                app = r
            } else { continue }

            if let (s, p) = tracked(id, in: live) {
                present.insert(id)
                p.frame = frame
                place(p, for: s)
                continue
            }
            guard case .panel(let kind)? = verdict(id, owner: owner, app: app, layer: layer) else { continue }
            present.insert(id)
            let candidates = live.filter { $0.pid == app }
            let appKey = candidates.first?.appKey ?? ""
            let (s, why) = Self.associate(frame, among: candidates, lastInput: lastInput(appKey))
            let p = StreamPanel(id: id, ownerPID: owner, owner: owner == app ? s.appName : ownerName, kind: kind, frame: frame)
            s.panels[id] = p
            s.target.panels[id] = owner
            Log.info(.capture, "panel: \(p.describe) appeared at \(Self.rect(frame)) (layer \(layer)\(owner == app ? "" : ", pid \(owner), responsible to \(s.appName)"))"
                     + "; with stream #\(s.id) (\(why)); \(focusDescription())")
            if owner != app, !s.filterHelpers.contains(owner) { refresh.insert(app) }
            place(p, for: s)
        }
        for s in live {
            for (id, p) in s.panels where !present.contains(id) {
                s.panels[id] = nil
                s.target.panels[id] = nil
                Log.info(.capture, "panel: \(p.describe) closed after \(String(format: "%.1f", Date().timeIntervalSince(p.since))) s (stream #\(s.id))")
            }
        }
        return refresh
    }

    /// Whether window `id` is a panel of a streamed app's (by its stream, any stream).
    func isPanel(_ id: CGWindowID) -> Bool { if case .panel? = verdicts[id] { return true }; return false }

    private func tracked(_ id: CGWindowID, in streams: [HostStream]) -> (HostStream, StreamPanel)? {
        for s in streams { if let p = s.panels[id] { return (s, p) } }
        return nil
    }

    /// The streamed app that process `pid` works for: its responsible process, or (without the
    /// responsibility call) the app whose name its own ends with in parentheses, as "Open and Save
    /// Panel Service (Claude)" does.
    private func responsibleApp(of pid: pid_t, name: String, names: [String: pid_t]) -> pid_t? {
        if responsibleFn != nil {
            if let r = responsible[pid] { return r }
            let r = responsiblePID(of: pid).flatMap { $0 == pid ? nil : $0 }
            responsible[pid] = r
            return r
        }
        for (app, p) in names where name.hasSuffix("(\(app))") { return p }
        return nil
    }

    /// Whether window `id` is a panel, and what kind: decided once per window (asked again a few times
    /// while Accessibility doesn't list it yet).
    private func verdict(_ id: CGWindowID, owner: pid_t, app: pid_t, layer: Int) -> Verdict? {
        if let v = verdicts[id] { return v }
        if owner != app {
            let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? ""
            let v = Verdict.panel((PanelServices.known[bundle] ?? "out-of-process") + " window")
            verdicts[id] = v
            return v
        }
        guard AXIsProcessTrusted() else { verdicts[id] = .notPanel; return .notPanel }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let w = windows.first(where: { cgWindowID(of: $0) == id }) else {
            // A popover or a sheet isn't an AX window; a new window may not be listed yet.
            let n = (unlisted[id] ?? 0) + 1
            unlisted[id] = n
            if n >= 4 { verdicts[id] = .notPanel; unlisted[id] = nil; return .notPanel }
            return nil
        }
        unlisted[id] = nil
        let subrole = axString(w, kAXSubroleAttribute), ident = axString(w, kAXIdentifierAttribute)
        var modal: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXModalAttribute as CFString, &modal)
        let v: Verdict
        if PanelServices.panelIdentifiers.contains(ident) {
            v = .panel(ident == "save-panel" ? "Save panel" : "Open panel")
        } else if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
            v = .panel("dialog")
        } else if (modal as? Bool) == true {
            v = .panel("modal window")
        } else if subrole == kAXFloatingWindowSubrole, baseline[app]?.contains(id) != true {
            v = .panel("floating panel")
        } else {
            v = .notPanel
        }
        verdicts[id] = v
        if case .panel(let k) = v { Log.debug(.capture, "panel: window \(id) of pid \(app) is a \(k) (subrole \(subrole), identifier \(ident), layer \(layer))") }
        return v
    }

    /// Which of the app's streams a new panel at `frame` goes with, and why.
    static func associate(_ frame: CGRect, among streams: [HostStream], lastInput: (stream: UInt16, at: Date)?) -> (HostStream, String) {
        let sorted = streams.sorted { $0.id < $1.id }
        if sorted.count == 1 { return (sorted[0], "the app's only stream") }
        func overlap(_ s: HostStream) -> CGFloat { let i = s.current.intersection(frame); return i.isNull ? 0 : i.width * i.height }
        let over = sorted.filter { overlap($0) > 0 }
        if over.count == 1 { return (over[0], "it lies over its window") }
        if let li = lastInput, let s = sorted.first(where: { $0.id == li.stream }), Date().timeIntervalSince(li.at) < 15 {
            return (s, "it got input \(Int(Date().timeIntervalSince(li.at) * 1000)) ms before")
        }
        if let s = over.max(by: { overlap($0) < overlap($1) }) { return (s, "it lies mostly over its window") }
        return (sorted[0], "the app's first stream")
    }

    /// Moves panel `p` over stream `s`'s window if it isn't within it (and we haven't put it where it is).
    private func place(_ p: StreamPanel, for s: HostStream) {
        let win = s.current
        guard win.width > 0, !PanelPlacement.inside(p.frame, win) else { return }
        if let placed = p.placed, abs(placed.minX - p.frame.minX) < 1, abs(placed.minY - p.frame.minY) < 1 { return }
        guard p.moves < 4 else {
            if gaveUp.insert(p.id).inserted { Log.info(.capture, "panel: \(p.describe) keeps ending up outside stream #\(s.id)'s window; leaving it at \(Self.rect(p.frame))") }
            return
        }
        p.moves += 1
        guard let ax = Self.axWindow(id: p.id, pid: p.ownerPID) else {
            p.moves = 4
            Log.info(.capture, "panel: \(p.describe) is outside stream #\(s.id)'s window but not reachable through Accessibility, so the viewer can't see it")
            return
        }
        let bar = CGFloat(s.chrome.isKnown ? max(28, Int(s.chrome.titleBarHeight)) : 28)
        var size = p.frame.size
        let fit = PanelPlacement.fitted(size, in: win, titleBar: bar)
        if !sameSize(fit, size) {
            var v = fit
            if let value = AXValueCreate(.cgSize, &v) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, value) }
            size = axFrame(of: ax)?.size ?? size
        }
        let want = PanelPlacement.frame(size: size, in: win, titleBar: bar)
        let ok = axSetFrame(ax, origin: want.origin, size: nil)
        let got = axFrame(of: ax) ?? want
        p.placed = got
        p.frame = got
        Log.info(.capture, "panel: moved \(p.describe) from outside stream #\(s.id)'s window (\(Self.rect(win))) to \(Self.rect(got))"
                 + (sameSize(size, p.frame.size) && PanelPlacement.inside(got, win) ? "" : ", larger than the window: it overflows")
                 + (ok ? "" : " (Accessibility refused part of it)"))
    }

    /// Process `pid`'s Accessibility window with window number `id`.
    static func axWindow(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let all = value as? [AXUIElement] else { return nil }
        return all.first { cgWindowID(of: $0) == id }
    }

    /// Which app has keyboard focus now (for the log: a panel appears with its app in front).
    private func focusDescription() -> String {
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return "focused app unknown" }
        var p: pid_t = 0
        AXUIElementGetPid(app as! AXUIElement, &p)
        return "focused: \(NSRunningApplication(processIdentifier: p)?.localizedName ?? "pid \(p)")"
    }

    static func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }
}
