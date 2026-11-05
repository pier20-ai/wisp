// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import CGVirtualDisplayPrivate
import WispCommon

/// A HiDPI virtual display, so a headless host (which only has macOS's 1x fallback framebuffer)
/// draws a streamed window at 2x and the viewer's Retina screen gets sharp text. The host makes one
/// per streamed window, side by side, so streamed windows never overlap.
///
/// Uses Apple's private CGVirtualDisplay API, as DeskPad and BetterDisplay do. The display lives
/// until `destroy()` (or the process ends); macOS moves its windows back to another display when
/// it goes away.
///
/// WindowServer safety. Adding or removing a display makes WindowServer reconfigure and wait for
/// every client to acknowledge. An earlier version had the display's callbacks on the main queue
/// while the main thread sat in a CGWindowListCopyWindowInfo that WindowServer wasn't answering: each
/// waited for the other and WindowServer went down, taking every logged-in session with it. So:
/// - the display's callbacks run on `callbackQueue`, never the main queue;
/// - every create and remove runs on `lifecycleQueue`, strictly one at a time, never on the main thread;
/// - while one is in flight the host holds back its main-thread WindowServer and Accessibility
///   calls (`DisplayGate`);
/// - a display that isn't online with its 2x mode within 5 s is removed again (the watchdog), and
///   the host shares the window where it is.
final class VirtualDisplay: @unchecked Sendable { // mutable state only on lifecycleQueue
    /// Size in points; the backing store is always 2x this.
    let points: CGSize
    let displayID: CGDirectDisplayID
    /// Only touched on `lifecycleQueue` (and in deinit).
    private var display: CGVirtualDisplay?

    static var isAvailable: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    /// Distinct serial numbers, so macOS doesn't take two of our displays for one. lifecycleQueue only.
    private static var serial: UInt32 = 0
    /// The display's callbacks must NOT run on the main queue (see above).
    private static let callbackQueue = DispatchQueue(label: "wisp.virtual-display", qos: .userInteractive)
    /// Creating and removing displays: strictly one at a time, and off the main thread.
    /// Each work item drains its own autorelease pool, so a released display really goes at once.
    private static let lifecycleQueue = DispatchQueue(label: "wisp.virtual-display.lifecycle", qos: .userInitiated,
                                                      autoreleaseFrequency: .workItem)
    /// How long a display has to come online with its HiDPI mode before it is given up on.
    static let watchdog: TimeInterval = 5

    private init(points: CGSize, display: CGVirtualDisplay) {
        self.points = points
        self.display = display
        displayID = display.displayID
    }

    /// The size a display made for `requested` points actually gets (clamped to what we support).
    static func normalized(_ requested: CGSize) -> CGSize {
        CGSize(width: min(max(requested.width.rounded(), 640), 4096), height: min(max(requested.height.rounded(), 400), 4096))
    }

    /// Global bounds in points (top-left origin, the coordinates CGWindow and Accessibility use).
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// The active mode's backing size in pixels, and its size in points.
    var activeMode: (pixels: CGSize, points: CGSize)? { Self.activeMode(displayID) }

    var isHiDPI: Bool { Self.isHiDPI(displayID) }

    var modeDescription: String {
        activeMode.map { "\(Int($0.points.width))x\(Int($0.points.height)) pt, \(Int($0.pixels.width))x\(Int($0.pixels.height)) px" } ?? "no mode"
    }

    private static func activeMode(_ id: CGDirectDisplayID) -> (pixels: CGSize, points: CGSize)? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return (CGSize(width: m.pixelWidth, height: m.pixelHeight), CGSize(width: m.width, height: m.height))
    }

    private static func isHiDPI(_ id: CGDirectDisplayID) -> Bool {
        activeMode(id).map { $0.pixels.width == 2 * $0.points.width && $0.points.width > 0 } ?? false
    }

    /// The part of the display windows can use (below its menu bar), in global top-left points.
    /// Main thread (NSScreen).
    var usableBounds: CGRect {
        let b = bounds
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return CGRect(x: b.minX, y: b.minY + 25, width: b.width, height: b.height - 25) }
        let top = screen.frame.maxY - screen.visibleFrame.maxY // menu bar
        let bottom = screen.visibleFrame.minY - screen.frame.minY // Dock, if it lives here
        return CGRect(x: b.minX, y: b.minY + top, width: b.width, height: b.height - top - bottom)
    }

    /// Creates a display with a single HiDPI mode of `points` (2x pixels), makes sure that mode is the
    /// active one, and keeps it out of the way: not mirrored, not the main display (unless it is the
    /// only one, on a headless Mac), and to the right of every other display, so it overlaps none.
    ///
    /// The work runs on `lifecycleQueue`; the caller only awaits it. If it hasn't finished a second
    /// after the watchdog this throws anyway, and the display is removed whenever the stuck call returns.
    static func create(points requested: CGSize) async throws -> VirtualDisplay {
        guard isAvailable else { throw HostError("CGVirtualDisplay is not available on this macOS") }
        let once = Once()
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<VirtualDisplay, Error>) in
            lifecycleQueue.async {
                let result = autoreleasepool { Result { try makeDisplay(points: requested) } }
                guard once.claim() else {
                    // The caller gave up on it already: don't leave it behind.
                    if case let .success(d) = result {
                        log("virtual display \(d.displayID) came online after it was given up on; removing it")
                        d.removeOnLifecycleQueue()
                    }
                    return
                }
                k.resume(with: result)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + watchdog + 1) {
                guard once.claim() else { return }
                k.resume(throwing: HostError("creating the virtual display took longer than \(Int(watchdog)) s"))
            }
        }
    }

    /// On lifecycleQueue: creates the display, arranges it and waits (polling) until it is ready, or
    /// removes it again and throws.
    private static func makeDisplay(points requested: CGSize) throws -> VirtualDisplay {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        let size = normalized(requested)
        let w = UInt32(size.width), h = UInt32(size.height)
        let previousMain = CGMainDisplayID()
        let deadline = Date().addingTimeInterval(watchdog)

        serial &+= 1
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(callbackQueue)
        desc.name = Brand.name
        desc.vendorID = 0x5743 // "WC", the initials of the product's first name; kept so displays keep their identity
        desc.productID = 0x0002
        desc.serialNum = serial
        desc.maxPixelsWide = 2 * w
        desc.maxPixelsHigh = 2 * h
        // ~218 ppi at 2x (Apple's Retina density), so macOS treats the display as Retina.
        let mmPerPixel = 25.4 / 218
        desc.sizeInMillimeters = CGSize(width: Double(2 * w) * mmPerPixel, height: Double(2 * h) * mmPerPixel)
        // sRGB primaries and D65 white.
        desc.redPrimary = CGPoint(x: 0.64, y: 0.33)
        desc.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        desc.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        desc.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        desc.terminationHandler = { _, d in log("virtual display \(d?.displayID ?? 0) was terminated by the system") }

        guard let vd = CGVirtualDisplay(descriptor: desc) else { throw HostError("could not create a virtual display") }
        let display = VirtualDisplay(points: size, display: vd)
        let id = display.displayID
        func giveUp(_ why: String) -> HostError {
            display.removeOnLifecycleQueue()
            return HostError(why)
        }
        // With hiDPI on, a mode is given in pixels and macOS offers it at half size in points.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: 2 * w, height: 2 * h, refreshRate: 60),
                          CGVirtualDisplayMode(width: w, height: h, refreshRate: 60)]
        guard vd.apply(settings) else { throw giveUp("the virtual display rejected its settings") }

        // The display comes online asynchronously; wait for its HiDPI mode to be listed.
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        var hidpi: CGDisplayMode?
        while true {
            let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
            hidpi = modes.first { $0.width == Int(w) && $0.height == Int(h) && $0.pixelWidth == Int(2 * w) }
            if hidpi != nil || Date() >= deadline { break }
            usleep(50000)
        }
        guard let hidpi else {
            log("virtual display \(id) modes: \(modesDescription(id))")
            throw giveUp("virtual display \(id) did not come online with a \(w)x\(h) pt HiDPI mode within \(Int(watchdog)) s")
        }

        // Only reconfigure what needs it: an empty or no-op configuration fails with kCGErrorFailure.
        let setMode = !isHiDPI(id)
        let unmirror = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
        let tookMain = CGMainDisplayID() == id && previousMain != id && CGDisplayIsOnline(previousMain) != 0
        // Side by side: to the right of every other display, top edge level with the main display's
        // (with the old main display back at the origin, if this one took over as main).
        let others = onlineDisplays().filter { $0 != id && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let shift = tookMain ? CGDisplayBounds(previousMain).origin : .zero
        let right = others.map { CGDisplayBounds($0).maxX - shift.x }.max() ?? 0
        let here = CGDisplayBounds(id).origin
        let move = !others.isEmpty && (tookMain || abs(here.x - right) > 0.5 || abs(here.y) > 0.5)
        if setMode || unmirror || move {
            var cfg: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { throw giveUp("could not configure the virtual display") }
            if setMode { CGConfigureDisplayWithDisplayMode(cfg, id, hidpi, nil) }
            if unmirror { CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay) }
            if tookMain { CGConfigureDisplayOrigin(cfg, previousMain, 0, 0) }
            if move { CGConfigureDisplayOrigin(cfg, id, Int32(right), 0) }
            let err = CGCompleteDisplayConfiguration(cfg, .forSession)
            if err != .success { log("virtual display \(id): configuration returned \(err.rawValue)") }
        }

        // The watchdog: online, with its 2x mode active, within 5 s of being created.
        while !isHiDPI(id), Date() < deadline { usleep(50000) }
        guard isHiDPI(id) else {
            let m = activeMode(id)
            throw giveUp("virtual display \(id) was not at 2x within \(Int(watchdog)) s (active mode "
                + (m.map { "\(Int($0.points.width))x\(Int($0.points.height)) pt / \(Int($0.pixels.width))x\(Int($0.pixels.height)) px" } ?? "none") + ")")
        }
        if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { log("virtual display \(id): WARNING, it is mirroring display \(CGDisplayMirrorsDisplay(id))") }
        if CGMainDisplayID() == id {
            log(others.isEmpty
                ? "virtual display \(id): it is the only display (headless), so it is also the main one"
                : "virtual display \(id): WARNING, it became the main display")
        }
        return display
    }

    /// Removes the display, off the main thread; returns once it has gone offline (or after 3 s).
    /// Safe to call more than once.
    func destroy() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            Self.lifecycleQueue.async {
                self.removeOnLifecycleQueue()
                k.resume()
            }
        }
    }

    /// When quitting: removes the display and waits at most `timeout` for that. (The main thread waits
    /// on a semaphore, not in a WindowServer call, so it can't deadlock WindowServer, only time out.)
    func destroyBeforeExit(timeout: TimeInterval = 1) {
        let done = DispatchSemaphore(value: 0)
        Self.lifecycleQueue.async {
            self.removeOnLifecycleQueue()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func removeOnLifecycleQueue() {
        dispatchPrecondition(condition: .onQueue(Self.lifecycleQueue))
        guard display != nil else { return }
        // Releasing the CGVirtualDisplay removes it. In a pool of its own: if anything had autoreleased
        // it, the display would otherwise linger until this work item ends (the first test run waited
        // its full 3 s here for each display, which then went the moment the work item finished).
        autoreleasepool { display = nil }
        let deadline = Date().addingTimeInterval(3)
        while onlineDisplays().contains(displayID), Date() < deadline { usleep(20000) }
        if onlineDisplays().contains(displayID) { log("virtual display \(displayID): still listed 3 s after removing it") }
    }

    deinit {
        // Normally removed already; if not, release it on the lifecycle queue, not wherever this runs.
        if let d = display { Self.lifecycleQueue.async { withExtendedLifetime(d) {} } }
    }
}

/// Settles a race once: the first `claim()` wins. Thread-safe.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &n) == .success else { return [] }
    return Array(ids.prefix(Int(n)))
}

/// Holds back the host's main-thread WindowServer and Accessibility work (the window-following
/// timers, input injection, Accessibility reads and actions, session checks) while a virtual display
/// is being created or removed, plus a short settling time; then runs what was held back, in order.
/// Main queue only.
enum DisplayGate {
    private static var depth = 0
    private static var held: [() -> Void] = []
    private static let settle: UInt64 = 300_000_000

    /// A display is being created or removed: don't call WindowServer or Accessibility on the main thread.
    static var busy: Bool { depth > 0 }

    /// Runs `work` now, or once no display change is in flight.
    static func whenIdle(_ work: @escaping () -> Void) {
        if depth == 0 { work() } else { held.append(work) }
    }

    /// Marks a display change in flight while `work` runs, and for a settling time after it.
    @MainActor
    static func during<T>(_ work: () async throws -> T) async throws -> T {
        depth += 1
        let result: Result<T, Error>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        try? await Task.sleep(nanoseconds: settle)
        depth -= 1
        if depth == 0, !held.isEmpty {
            let work = held
            held = []
            work.forEach { $0() }
        }
        return try result.get()
    }
}

// MARK: - Moving a window with Accessibility

/// The app's Accessibility window whose frame best matches `frame` (global top-left points).
func axWindow(pid: pid_t, frame: CGRect) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
          let all = value as? [AXUIElement] else { return nil }
    func distance(_ w: AXUIElement) -> CGFloat {
        guard let r = axFrame(of: w) else { return .infinity }
        return abs(r.minX - frame.minX) + abs(r.minY - frame.minY) + abs(r.width - frame.width) + abs(r.height - frame.height)
    }
    return all.min { distance($0) < distance($1) }
}

func axFrame(of w: AXUIElement) -> CGRect? {
    var pos: CFTypeRef?, size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
          AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
          let pos, let size else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
    AXValueGetValue(size as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

/// Moves (and if needed shrinks) a window to `frame`. Returns false if Accessibility refused.
@discardableResult
func axSetFrame(_ w: AXUIElement, origin: CGPoint, size: CGSize?) -> Bool {
    var ok = true
    if let size {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { ok = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success && ok }
    }
    var p = origin
    if let v = AXValueCreate(.cgPoint, &p) { ok = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success && ok }
    // Set the size again: a window can refuse a size that doesn't fit where it was.
    if let size {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }
    return ok
}

// MARK: - Debug: wisp vdisplay-test

/// Every mode a display offers, as "pointW x pointH (pixelW x pixelH)".
func modesDescription(_ id: CGDirectDisplayID) -> String {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
    return modes.isEmpty ? "none" : modes.map { "\($0.width)x\($0.height) (\($0.pixelWidth)x\($0.pixelHeight))" }.joined(separator: ", ")
}

func describeDisplays() -> String {
    onlineDisplays().map { id in
        let b = CGDisplayBounds(id)
        let m = CGDisplayCopyDisplayMode(id)
        let mode = m.map { "\($0.pixelWidth)x\($0.pixelHeight) px, \($0.width)x\($0.height) pt @\(String(format: "%.0f", $0.refreshRate)) Hz" } ?? "no mode"
        var flags: [String] = []
        if CGDisplayIsMain(id) != 0 { flags.append("main") }
        if CGDisplayIsBuiltin(id) != 0 { flags.append("builtin") }
        if CGDisplayIsActive(id) == 0 { flags.append("inactive") }
        if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { flags.append("mirrors \(CGDisplayMirrorsDisplay(id))") }
        return "  display \(id): bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) pt | mode \(mode)"
            + (flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")
    }.joined(separator: "\n")
}

/// Creates `--count` virtual displays one at a time (as the host does, one per stream), checks each
/// is 2x, not main (unless headless), not mirrored, and that none overlaps another display; waits;
/// then removes them one by one and checks they are all gone.
func runVirtualDisplayTest(_ arguments: [String]) -> Never {
    let usage = "usage: \(Brand.cli) vdisplay-test <pointW>x<pointH> [seconds] [--count N]"
    var args = arguments
    var count = 1
    if let i = args.firstIndex(of: "--count") {
        guard i + 1 < args.count, let n = Int(args[i + 1]), (1 ... 3).contains(n) else { fail(usage + " (N from 1 to 3)") }
        count = n
        args.removeSubrange(i ... i + 1)
    }
    guard let spec = args.first else { fail(usage) }
    let p = spec.split(separator: "x").compactMap { Double($0) }
    guard p.count == 2 else { fail(usage) }
    let seconds = min(max(args.count > 1 ? Double(args[1]) ?? 3 : 3, 0), 60)
    let before = Set(onlineDisplays())
    print("before:\n\(describeDisplays())")
    Task { @MainActor in
        var made: [VirtualDisplay] = []
        var ok = true
        for i in 1 ... count {
            let t0 = Date()
            do {
                let vd = try await DisplayGate.during { try await VirtualDisplay.create(points: CGSize(width: p[0], height: p[1])) }
                made.append(vd)
                print(String(format: "created #%d: display %u in %.2f s, active mode %@", i, vd.displayID, Date().timeIntervalSince(t0), vd.modeDescription))
            } catch {
                print("could not create display #\(i): \(error.localizedDescription)")
                ok = false
                break
            }
        }
        print("with them:\n\(describeDisplays())")
        print("arrangement (left to right):")
        let all = onlineDisplays()
        // Headless: if no other display is left, one of ours has to be the main one.
        let headless = all.allSatisfy { id in made.contains { $0.displayID == id } }
        for vd in made.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            let b = vd.bounds
            var problems: [String] = []
            if !vd.isHiDPI { problems.append("NOT 2x") }
            if CGDisplayIsMain(vd.displayID) != 0, !headless { problems.append("IS MAIN") }
            if CGDisplayMirrorsDisplay(vd.displayID) != kCGNullDirectDisplay { problems.append("MIRRORED") }
            let overlapping = all.filter { $0 != vd.displayID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay && CGDisplayBounds($0).intersects(b) }
            if !overlapping.isEmpty { problems.append("OVERLAPS \(overlapping.map(String.init).joined(separator: ","))") }
            if !problems.isEmpty { ok = false }
            print("  display \(vd.displayID): \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)) pt, \(vd.modeDescription), usable \(vd.usableBounds.integral) -> "
                + (problems.isEmpty ? "OK (2x, not main, not mirrored, no overlap)" : problems.joined(separator: ", ")))
        }
        print("main display: \(CGMainDisplayID())")
        if !made.isEmpty { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        for vd in made {
            let t0 = Date()
            do { try await DisplayGate.during { await vd.destroy() } } catch { Log.failed(.vdisplay, "removing virtual display \(vd.displayID)", error) }
            print(String(format: "removed display %u in %.2f s", vd.displayID, Date().timeIntervalSince(t0)))
        }
        let leftover = Set(onlineDisplays()).subtracting(before)
        print("after removing them:\n\(describeDisplays())")
        if !leftover.isEmpty { print("LEFT BEHIND: \(leftover.sorted())"); ok = false }
        print(ok ? "vdisplay-test: OK" : "vdisplay-test: FAILED")
        exit(ok ? 0 : 1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}
