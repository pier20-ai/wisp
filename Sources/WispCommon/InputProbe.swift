// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo

// The end-to-end test's two ends meet here (docs/testing.md "End-to-end input and freshness"):
// what a test window on the host received, as JSON lines (`InputRecord`, `InputLog`), written by
// WispProbe.app on a real host and by the synthetic host from the events its injector builds; and a
// frame counter drawn into the window as black and white squares (`FrameCode`), which the viewer
// reads back from decoded frames to tell a live picture from a frozen one.

/// A frame counter as a strip of squares, drawn at a fixed place in a window and read back from a
/// decoded frame. Two rows of `bits + 2` cells, `cell` points square, from `origin` (window points,
/// top-left origin: below a standard 28 pt title bar). Row 1: white, black (the reference levels),
/// then the low 16 bits of the counter, most significant first, white = 1. Row 2: the same cells
/// inverted, so a misread (a cell blurred by compression, something drawn over it) is detected
/// rather than decoded as a wrong number.
public enum FrameCode {
    public static let origin = CGPoint(x: 12, y: 40)
    public static let cell: CGFloat = 8
    public static let bits = 16
    public static var size: CGSize { CGSize(width: CGFloat(bits + 2) * cell, height: 2 * cell) }

    /// The cells for `counter`: rects in window points (top-left origin) and whether each is white.
    public static func cells(_ counter: Int, origin o: CGPoint = origin) -> [(CGRect, Bool)] {
        var row: [Bool] = [true, false]
        for i in (0 ..< bits).reversed() { row.append((counter >> i) & 1 == 1) }
        var out: [(CGRect, Bool)] = []
        for (i, white) in row.enumerated() {
            let x = o.x + CGFloat(i) * cell
            out.append((CGRect(x: x, y: o.y, width: cell, height: cell), white))
            out.append((CGRect(x: x, y: o.y + cell, width: cell, height: cell), i < 2 ? white : !white))
        }
        return out
    }

    /// Draws the code into a bitmap context of `heightPx` pixels (bottom-left origin) at `scale` px/pt.
    public static func draw(_ counter: Int, in ctx: CGContext, heightPx: CGFloat, scale k: CGFloat) {
        for (r, white) in cells(counter) {
            ctx.setFillColor(white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: r.minX * k, y: heightPx - r.maxY * k, width: r.width * k, height: r.height * k))
        }
    }

    /// Reads the counter (its low 16 bits) from a decoded 32BGRA frame of a window `pointsWidth`
    /// points wide; nil if there's no valid code there.
    public static func decode(_ pb: CVPixelBuffer, pointsWidth: CGFloat) -> Int? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, pointsWidth > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let k = CGFloat(w) / pointsWidth
        func luma(_ p: CGPoint) -> Int? {
            let x = Int((p.x * k).rounded(.down)), y = Int((p.y * k).rounded(.down))
            guard x >= 0, x < w, y >= 0, y < h else { return nil }
            let px = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
            return (Int(px[2]) * 3 + Int(px[1]) * 6 + Int(px[0])) / 10
        }
        let cs = cells(0)
        var levels: [Int] = []
        for (r, _) in cs { guard let l = luma(CGPoint(x: r.midX, y: r.midY)) else { return nil }; levels.append(l) }
        // Cells come in pairs (row 1, row 2) per column.
        let white = levels[0], black = levels[2]
        guard white - black > 80 else { return nil }
        let mid = (white + black) / 2
        var value = 0
        for i in 2 ..< bits + 2 {
            let top = levels[2 * i] > mid, bottom = levels[2 * i + 1] > mid
            guard top != bottom else { return nil }
            value = value << 1 | (top ? 1 : 0)
        }
        return value
    }

    /// The difference between two decoded counters (16 bits, wrapping), as a frame count forward.
    public static func advance(from a: Int, to b: Int) -> Int { (b - a) & 0xFFFF }
}

/// One line of an input log: what a test window received, as an app sees it. Keys:
/// `t` (Unix time, s), `src` ("probe" / "synthetic"), `win` (the host's window ID), `ev` (the kind)
/// and, by kind:
/// - `scroll`: `dx`, `dy` (scrollingDeltaX/Y: points if `precise`, else lines), `precise`, `phase`,
///   `momentum` (NSEvent.Phase raw values), `x`, `y` (window points, top-left origin)
/// - `down`, `up`, `drag`: `button` (0 left, 1 right, 2 other), `clicks`, `x`, `y`
/// - `keyDown`, `keyUp`, `flags`: `code`, `chars` (keyDown/keyUp), `mods` (⌘⌥⌃⇧ bits of NSEvent.ModifierFlags)
/// - `resize`: `w`, `h` (window points); `key`, `resign`: the window became or stopped being key
/// - `raise`: input brought the window forward (`why`); `start`: a probe started (`windows`)
/// Test windows only: these logs hold what was typed, so they're never written by a real session.
public enum InputRecord {
    public static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The record for `e`, an event received by window `win`, at window point `p` (top-left origin).
    public static func make(_ e: NSEvent, src: String, win: UInt32, at p: CGPoint?) -> [String: Any]? {
        var d: [String: Any] = ["src": src, "win": Int(win)]
        if let p { d["x"] = round1(p.x); d["y"] = round1(p.y) }
        switch e.type {
        case .scrollWheel:
            d["ev"] = "scroll"
            d["dx"] = e.scrollingDeltaX; d["dy"] = e.scrollingDeltaY
            d["precise"] = e.hasPreciseScrollingDeltas
            d["phase"] = Int(e.phase.rawValue); d["momentum"] = Int(e.momentumPhase.rawValue)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type)
            d["ev"] = down ? "down" : "up"
            d["button"] = min(e.buttonNumber, 2); d["clicks"] = e.clickCount
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            d["ev"] = "drag"; d["button"] = min(e.buttonNumber, 2)
        case .keyDown, .keyUp:
            d["ev"] = e.type == .keyDown ? "keyDown" : "keyUp"
            d["code"] = Int(e.keyCode); d["chars"] = e.characters ?? ""
            d["mods"] = Int(e.modifierFlags.intersection(modifierMask).rawValue)
            if e.type == .keyDown, e.isARepeat { d["repeat"] = true }
        case .flagsChanged:
            d["ev"] = "flags"; d["code"] = Int(e.keyCode)
            d["mods"] = Int(e.modifierFlags.intersection(modifierMask).rawValue)
        default:
            return nil
        }
        return d
    }

    private static func round1(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
}

/// Appends records to a JSON-lines file, each line written whole (any thread).
public final class InputLog {
    public let path: String
    private let handle: FileHandle?
    private let lock = NSLock()

    public init(path: String, truncate: Bool = false) {
        self.path = path
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if truncate || !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    public func write(_ record: [String: Any]) {
        var r = record
        r["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        handle?.write(data + Data("\n".utf8))
    }
}
