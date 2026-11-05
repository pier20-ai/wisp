// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The "remote" badge put on phantom apps' icons, in the app icon's family (scripts/make-icon.swift):
/// a disc in the trail's teal (#2BD4C0 to #0E7C86) with a white rim and a white swoosh ending in an
/// arrowhead, the trail of a window that came from elsewhere. Self-contained (AppKit and CoreGraphics
/// only) so the icon scripts can paste it in for contact sheets.
///
/// Draws into the current NSGraphicsContext; `rect` should be square (the disc fills its shorter side).
func drawRemoteBadge(in rect: CGRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let d = min(rect.width, rect.height)
    let disc = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                                CGFloat(hex & 0xFF) / 255, a])!
    }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: disc.minX + x * d, y: disc.minY + y * d) }

    ctx.saveGState()
    defer { ctx.restoreGState() }

    // White rim, lifted off the icon by a soft shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -d * 0.025), blur: d * 0.08, color: c(0x000000, 0.4))
    ctx.setFillColor(c(0xFFFFFF))
    ctx.fillEllipse(in: disc)
    ctx.restoreGState()

    // Teal disc, lighter at the top.
    let inner = disc.insetBy(dx: d * 0.075, dy: d * 0.075)
    ctx.saveGState()
    ctx.addEllipse(in: inner); ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [c(0x2BD4C0), c(0x0E7C86)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: inner.midX, y: inner.maxY), end: CGPoint(x: inner.midX, y: inner.minY), options: [])
    ctx.restoreGState()

    // The glyph: a swoosh that thickens as it sweeps up and to the right, then an arrowhead.
    let p0 = p(0.25, 0.27), c1 = p(0.27, 0.50), c2 = p(0.40, 0.58), p1 = p(0.57, 0.62)
    let n = 40
    ctx.setLineCap(.round)
    ctx.setStrokeColor(c(0xFFFFFF))
    var prev = p0
    for i in 1...n {
        let t = CGFloat(i) / CGFloat(n), u = 1 - t
        let pt = CGPoint(x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x,
                         y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y)
        ctx.setLineWidth(d * (0.045 + 0.065 * t))
        ctx.move(to: prev); ctx.addLine(to: pt); ctx.strokePath()
        prev = pt
    }
    let dx = p1.x - c2.x, dy = p1.y - c2.y, len = (dx * dx + dy * dy).squareRoot()
    let ux = dx / len, uy = dy / len
    let tip = CGPoint(x: p1.x + ux * d * 0.19, y: p1.y + uy * d * 0.19)
    let base = CGPoint(x: p1.x - ux * d * 0.02, y: p1.y - uy * d * 0.02), half = d * 0.13
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
    ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
    ctx.closePath()
    ctx.setFillColor(c(0xFFFFFF))
    ctx.setLineJoin(.round); ctx.setLineWidth(d * 0.025)
    ctx.drawPath(using: .fillStroke)
}
