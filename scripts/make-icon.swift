// SPDX-License-Identifier: GPL-3.0-or-later
// Draws scripts/assets/AppIcon.icns: "Trail", a frosted window lifting up and to the right out of a
// graphite tile, leaving a teal light trail. From 64 px it uses the painted art in
// scripts/assets/icon-art.png (see scripts/prepare-icon-art.py); without it, and always at 16 and
// 32 px, the icon is drawn from code below. Apple's macOS icon grid: 1024 canvas, 824 body
// inset 100, continuous-corner squircle. From 128 px the trail is built as light (braided strands,
// filaments, core, glow, haze, spill on the tile and the window) at 16 bits, then dithered. 16 and 32 px get their own pixel-aligned drawing (no dots,
// rim or glow; the trail is one bold stroke). The remote badge on phantom apps uses the same teal
// (Sources/wisp/Phantom/RemoteBadge.swift).
//
// Run: swift scripts/make-icon.swift [output dir, default scripts/assets]
import AppKit
import CoreImage

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, a])!
}
let tealLight: UInt32 = 0x2BD4C0, tealDeep: UInt32 = 0x0E7C86, tealCore: UInt32 = 0xB8FFF4

func newContext(_ px: Int, gray: Bool = false) -> CGContext {
    gray ? CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
         : CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                     space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// MARK: Shapes

/// A rectangle with Apple's continuous ("squircle") corners: each corner is three cubic segments that
/// ease the curvature in over 1.528 r of the edge (the curve UIKit and the macOS icon template use).
func continuousRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    let rad = min(radius, min(r.width, r.height) / 2 / 1.52866483)
    let p = CGMutablePath()
    // Corners counter-clockwise from bottom-left; a = toward the previous corner, b = toward the next.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
    ]
    for (i, (c, a, b)) in corners.enumerated() {
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (u * a.dx + v * b.dx) * rad, y: c.y + (u * a.dy + v * b.dy) * rad)
        }
        if i == 0 { p.move(to: pt(1.52866483, 0)) } else { p.addLine(to: pt(1.52866483, 0)) }
        p.addCurve(to: pt(0.63149399, 0.07491100), control1: pt(1.08849299, 0), control2: pt(0.86840701, 0))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282401, 0.16905201), control2: pt(0.16905201, 0.37282401))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0, 0.86840701), control2: pt(0, 1.08849299))
    }
    p.closeSubpath()
    return p
}

/// Points along a chain of cubic Béziers.
func sample(_ segs: [[CGPoint]], perSegment n: Int) -> [CGPoint] {
    var out: [CGPoint] = []
    for (si, s) in segs.enumerated() {
        for i in (si == 0 ? 0 : 1)...n {
            let t = CGFloat(i) / CGFloat(n), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            out.append(CGPoint(x: a * s[0].x + b * s[1].x + c * s[2].x + d * s[3].x,
                               y: a * s[0].y + b * s[1].y + c * s[2].y + d * s[3].y))
        }
    }
    return out
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat(v >> s & 0xFF) / 255 }
    let t = max(0, min(1, t))
    return CGColor(colorSpace: srgb, components: [ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t, ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t,
                                                  ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t, 1])!
}
func smooth(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
}

/// A tapered ribbon along `pts` (t = 0 at the first point, 1 at the last) whose width, colour and opacity
/// vary along it, as an image the size of the canvas. Colour and opacity go into two offscreen images
/// (opaque round-capped strokes, so the overlaps leave no seams); the colour is then drawn through the
/// opacity mask.
func ribbon(px: Int, scale k: CGFloat, pts: [CGPoint], width: (CGFloat) -> CGFloat,
            color: (CGFloat) -> CGColor, alpha: (CGFloat) -> CGFloat) -> CGImage {
    let col = newContext(px), mask = newContext(px, gray: true)
    for c in [col, mask] { c.scaleBy(x: k, y: k); c.setLineCap(.round) }
    mask.setFillColor(gray: 0, alpha: 1)
    mask.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    for i in 0..<(pts.count - 1) {
        let t = CGFloat(i) / CGFloat(pts.count - 2)
        let w = width(t)
        guard w > 0 else { continue }
        for c in [col, mask] {
            c.setLineWidth(w)
            c.move(to: pts[i]); c.addLine(to: pts[i + 1])
        }
        col.setStrokeColor(color(t)); col.strokePath()
        mask.setStrokeColor(gray: alpha(t), alpha: 1); mask.strokePath()
    }
    let full = CGRect(x: 0, y: 0, width: px, height: px)
    let out = newContext(px)
    out.clip(to: full, mask: mask.makeImage()!)
    out.draw(col.makeImage()!, in: full)
    return out.makeImage()!
}

let ciContext = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
func blurred(_ img: CGImage, sigma: CGFloat) -> CGImage {
    guard sigma > 0.3 else { return img }
    let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: sigma)
        .cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ciContext.createCGImage(ci, from: ci.extent)!
}

/// Draws a canvas-sized image over the whole canvas (whatever the current scale).
func composite(_ ctx: CGContext, _ img: CGImage, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
    ctx.saveGState()
    ctx.setAlpha(alpha); ctx.setBlendMode(blend)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()
}

// MARK: Large sizes (64 px and up), drawn on the 1024 grid

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

func drawTile(_ ctx: CGContext, k: CGFloat, detail: Bool) {
    let tile = continuousRect(body, radius: tileRadius)
    if detail { // the template's soft drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.35))
        ctx.addPath(tile); ctx.setFillColor(rgb(0x2A2E35)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let g = CGGradient(colorsSpace: srgb, colors: [rgb(0x50555E), rgb(0x363A42), rgb(0x1E2228)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint lift in the upper-left, like light on frosted graphite.
    let sheen = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 330, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 900), endRadius: 620, options: [])
    // The teal light spilling onto the tile around the trail's turn (128 px and up: the light does it).
    if !detail {
    let spill = CGGradient(colorsSpace: srgb, colors: [rgb(tealLight, 0.16), rgb(tealLight, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spill, startCenter: CGPoint(x: 230, y: 330), startRadius: 0,
                           endCenter: CGPoint(x: 230, y: 330), endRadius: 300, options: [])
    }
    if detail {
        // Inner rim: bright along the top, fading out by the middle (Tahoe's glass edge).
        ctx.addPath(tile); ctx.setLineWidth(9); ctx.replacePathWithStrokedPath(); ctx.clip()
        let rim = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, 0.42), rgb(0xFFFFFF, 0.06), rgb(0xFFFFFF, 0.12)] as CFArray,
                             locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }
    ctx.restoreGState()
}

// The window: 480 x 324, centre (604, 590), turned 8 degrees anticlockwise (lifting to the right).
let winSize = CGSize(width: 480, height: 324), winCenter = CGPoint(x: 604, y: 590), winAngle: CGFloat = 8 * .pi / 180
let winRadius: CGFloat = 40, barHeight: CGFloat = 66
var winTransform: CGAffineTransform {
    CGAffineTransform(translationX: winCenter.x, y: winCenter.y).rotated(by: winAngle)
}
let winLocal = CGRect(x: -winSize.width / 2, y: -winSize.height / 2, width: winSize.width, height: winSize.height)

// The trail runs from its faint tail under the window's bottom-right, sweeps left along the bottom,
// turns up at the tile's left side and runs into the underside of the window.
let trailSegs: [[CGPoint]] = [
    [CGPoint(x: 640, y: 214), CGPoint(x: 420, y: 186), CGPoint(x: 205, y: 206), CGPoint(x: 172, y: 322)],
    [CGPoint(x: 172, y: 322), CGPoint(x: 142, y: 430), CGPoint(x: 330, y: 500), CGPoint(x: 560, y: 548)],
]
/// The trail at 64 px: one ribbon with a glow and a core (128 px and up use trailLight).
func drawTrail(_ ctx: CGContext, px: Int, k: CGFloat) {
    let pts = sample(trailSegs, perSegment: 80)
    let width: (CGFloat) -> CGFloat = { t in 6 + 84 * smooth(0, 0.6, t) + 24 * smooth(0.8, 1, t) }
    let alpha: (CGFloat) -> CGFloat = { t in smooth(0.0, 0.45, t) }
    let color: (CGFloat) -> CGColor = { t in mix(tealDeep, tealLight, smooth(0.1, 0.6, t)) }
    let main = ribbon(px: px, scale: k, pts: pts, width: width, color: color, alpha: alpha)
    let core = ribbon(px: px, scale: k, pts: pts, width: { t in width(t) * 0.3 },
                      color: { t in mix(tealLight, tealCore, smooth(0.3, 0.8, t)) }, alpha: { t in 0.9 * smooth(0.15, 0.6, t) })
    // Light, not paint: a wide halo and a tighter glow added onto the tile, then the ribbon with soft
    // edges, then its bright core.
    composite(ctx, blurred(main, sigma: 46 * k), alpha: 0.75, blend: .plusLighter)
    composite(ctx, blurred(main, sigma: 14 * k), alpha: 0.6, blend: .plusLighter)
    composite(ctx, blurred(main, sigma: 5 * k), alpha: 0.95)
    composite(ctx, blurred(core, sigma: 6 * k), alpha: 0.7, blend: .plusLighter)
}

var windowPath: CGPath {
    var tr = winTransform
    return continuousRect(winLocal, radius: winRadius).copy(using: &tr)!
}

/// The window's shadow on the tile.
func drawWindowShadow(_ ctx: CGContext, k: CGFloat, alpha: CGFloat = 0.55) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22 * k), blur: 46 * k, color: rgb(0x05080C, alpha))
    ctx.addPath(windowPath); ctx.setFillColor(rgb(0x1E2228)); ctx.fillPath()
    ctx.restoreGState()
}

/// The window. `light` (128 px and up) is the trail's light: it scatters through the frosted glass and
/// catches the rim where the trail passes behind.
func drawWindow(_ ctx: CGContext, px: Int, k: CGFloat, detail: Bool, backdrop: CGImage, light: CIImage? = nil) {
    let path = windowPath
    if light == nil { drawWindowShadow(ctx, k: k) }

    // Frosted glass: what's behind (tile and trail), blurred, under a milky white.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let ci = CIImage(cgImage: backdrop).clampedToExtent().applyingGaussianBlur(sigma: 34 * k)
        .cropped(to: CGRect(x: 0, y: 0, width: px, height: px))
    if let blurred = ciContext.createCGImage(ci, from: ci.extent, format: light == nil ? .RGBA8 : .RGBA16, colorSpace: srgb) {
        ctx.draw(blurred, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    ctx.concatenate(winTransform)
    let m: CGFloat = light == nil ? 1 : 0.93 // a little more glass at 128 px and up
    let milk = CGGradient(colorsSpace: srgb, colors: [rgb(0xF8FBFD, 0.92 * m), rgb(0xEAF1F5, 0.84 * m), rgb(0xDAE6EC, 0.80 * m)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(milk, start: CGPoint(x: -60, y: winLocal.maxY), end: CGPoint(x: 60, y: winLocal.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Title bar: a touch brighter, with a hairline under it.
    let bar = CGRect(x: winLocal.minX, y: winLocal.maxY - barHeight, width: winLocal.width, height: barHeight)
    ctx.setFillColor(rgb(0xFFFFFF, 0.35)); ctx.fill(bar)
    let hairline: CGFloat = detail ? 3 : 10 // at 64 px a 3-unit line would vanish
    ctx.setFillColor(rgb(0x7C8B96, detail ? 0.45 : 0.6))
    ctx.fill(CGRect(x: bar.minX, y: bar.minY - hairline / 2, width: bar.width, height: hairline))
    ctx.setFillColor(rgb(0xFFFFFF, 0.7))
    ctx.fill(CGRect(x: bar.minX, y: bar.minY - hairline / 2 - 3, width: bar.width, height: 3))
    if detail {
        ctx.setFillColor(rgb(0x7F8A93))
        for i in 0..<3 {
            let d: CGFloat = 26, cx = winLocal.minX + 42 + CGFloat(i) * 40
            ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: bar.midY - d / 2, width: d, height: d))
        }
    }
    ctx.restoreGState()

    if let light {
        // Light scattering through the frosted glass from the trail behind it.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        composite(ctx, cgImage(gain(blur(light, 55 * k), 0.16)), blend: .plusLighter)
        ctx.restoreGState()
        // The edge catching it, inside and out: brightest at the lower left, where the trail passes under.
        let rim = newContext(px)
        rim.scaleBy(x: k, y: k)
        rim.addPath(path); rim.setLineWidth(22); rim.setStrokeColor(rgb(0xFFFFFF)); rim.strokePath()
        let rimMask = blur(ciImage(rim.makeImage()!), 7 * k)
        let edge = gain(blur(light, 18 * k), 1.3).applyingFilter("CIMultiplyCompositing",
                                                                parameters: [kCIInputBackgroundImageKey: rimMask])
        composite(ctx, cgImage(edge.cropped(to: canvasExtent(px))), blend: .plusLighter)
    }

    // Rim: a thin bright edge inside, a faint dark line outside so it reads against any tile shade.
    ctx.saveGState()
    ctx.addPath(path); ctx.setLineWidth(detail ? 2.5 : 4); ctx.setStrokeColor(rgb(0x0A1016, 0.25)); ctx.strokePath()
    if detail {
        ctx.addPath(path); ctx.clip()
        ctx.addPath(path); ctx.setLineWidth(9); ctx.setStrokeColor(rgb(0xFFFFFF, 0.95)); ctx.strokePath()
    }
    ctx.restoreGState()
}

func renderLarge(_ px: Int) -> CGImage {
    let k = CGFloat(px) / 1024, detail = px >= 128
    if let art { return renderArt(px, art) }
    if detail { return renderDetailed(px) }
    let ctx = newContext(px)
    ctx.scaleBy(x: k, y: k)
    drawTile(ctx, k: k, detail: detail)
    ctx.saveGState()
    ctx.addPath(continuousRect(body, radius: tileRadius)); ctx.clip()
    drawTrail(ctx, px: px, k: k)
    let backdrop = ctx.makeImage()!
    drawWindow(ctx, px: px, k: k, detail: detail, backdrop: backdrop)
    ctx.restoreGState()
    return ctx.makeImage()!
}


// MARK: The trail's light at 128 px and up

// Light is built in Core Image (float) and added onto the scene, so the soft falloffs don't band; the
// finished icon is dithered down to 8 bits.
func ciImage(_ cg: CGImage) -> CIImage { CIImage(cgImage: cg) }
func canvasExtent(_ px: Int) -> CGRect { CGRect(x: 0, y: 0, width: px, height: px) }
func blur(_ img: CIImage, _ sigma: CGFloat) -> CIImage {
    img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: img.extent)
}
/// Scales light by `s`, with an optional per-channel tint (premultiplied, so alpha follows the brightest channel).
func gain(_ img: CIImage, _ s: CGFloat, r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1) -> CIImage {
    img.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: s * r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s * g, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: s * b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: s * max(r, g, b)),
    ])
}
func add(_ a: CIImage, _ b: CIImage) -> CIImage {
    b.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: a]).cropped(to: a.extent)
}
func cgImage(_ img: CIImage) -> CGImage {
    ciContext.createCGImage(img, from: img.extent, format: .RGBA16, colorSpace: srgb)!
}

/// One strand of the trail: offset from the trail's centre line along its normal (positive = outside the
/// loop), braiding a little, with its own width and brightness.
struct Strand {
    var offset: CGFloat, braid: CGFloat = 0, phase: CGFloat = 0, width: CGFloat, intensity: CGFloat
    var white = false // a filament: near-white rather than teal
}

// The centre line; its head runs on under the window, so no strand ends in view.
let lightSegs: [[CGPoint]] = [
    [CGPoint(x: 640, y: 214), CGPoint(x: 420, y: 186), CGPoint(x: 205, y: 206), CGPoint(x: 172, y: 322)],
    [CGPoint(x: 172, y: 322), CGPoint(x: 142, y: 430), CGPoint(x: 330, y: 500), CGPoint(x: 600, y: 556)],
]

let strands: [Strand] = [
    Strand(offset: -78, width: 70, intensity: 0.16),                        // inner haze
    Strand(offset: -34, braid: 8, phase: 1.3, width: 26, intensity: 0.42),  // inner strand
    Strand(offset: 0, width: 74, intensity: 0.80),                          // the main ribbon
    Strand(offset: 40, braid: 10, phase: 2.1, width: 34, intensity: 0.38),  // outer strand
    Strand(offset: 70, braid: 6, phase: 4.0, width: 9, intensity: 0.42),    // outer thread
    Strand(offset: 8, braid: 9, phase: 0.4, width: 5, intensity: 0.55, white: true),
    Strand(offset: -18, braid: 7, phase: 3.3, width: 3.5, intensity: 0.40, white: true),
    Strand(offset: 34, braid: 11, phase: 5.1, width: 3, intensity: 0.30, white: true),
]

/// The trail's light, ready to add onto the tile: the strands summed, then a bright core, a tight glow,
/// a wide cyan haze and a very wide spill onto the tile, plus a few soft specks near the brightest part.
func trailLight(px: Int, k: CGFloat) -> CIImage {
    let base = sample(lightSegs, perSegment: 260)
    let n = base.count
    // Unit normals, to the right of the direction of travel (outside the loop).
    let normals: [CGVector] = (0..<n).map { i in
        let a = base[max(0, i - 1)], b = base[min(n - 1, i + 1)]
        let dx = b.x - a.x, dy = b.y - a.y, l = max(1e-6, (dx * dx + dy * dy).squareRoot())
        return CGVector(dx: dy / l, dy: -dx / l)
    }
    // Thin, converged and dim at the tail; full width from the turn on; fanning out near the window.
    let taper: (CGFloat) -> CGFloat = { t in 0.08 + 0.92 * smooth(0, 0.62, t) }
    let fan: (CGFloat) -> CGFloat = { t in 0.3 + 0.7 * smooth(0, 0.55, t) + 0.35 * smooth(0.7, 1, t) }
    // Brightness: fades in from the tail, peaks under the window, ripples gently along the length.
    let level: (CGFloat, CGFloat) -> CGFloat = { t, ph in
        smooth(0, 0.5, t) * (0.72 + 0.28 * smooth(0.55, 0.92, t)) * (1 + 0.14 * sin(11 * t + ph) + 0.07 * sin(23 * t + 2 * ph))
    }
    var light = CIImage(color: .clear).cropped(to: canvasExtent(px))
    var filaments = light
    for s in strands {
        let pts = (0..<n).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(n - 1)
            let o = s.offset * fan(t) * (0.25 + 0.75 * taper(t)) + s.braid * sin(.pi * 3 * t + s.phase) * smooth(0.1, 0.5, t)
            return CGPoint(x: base[i].x + normals[i].dx * o, y: base[i].y + normals[i].dy * o)
        }
        let img = ribbon(px: px, scale: k, pts: pts, width: { t in s.width * (s.white ? 0.5 + 0.5 * taper(t) : taper(t)) },
                         color: { t in s.white ? mix(tealLight, 0xEFFFFC, smooth(0.25, 0.85, t))
                                               : mix(tealDeep, tealLight, smooth(0.05, 0.6, t)) },
                         alpha: { t in min(1, s.intensity * level(t, s.phase)) })
        if s.white { filaments = add(filaments, ciImage(img)) } else { light = add(light, ciImage(img)) }
    }
    // The lower sheet: from the turn it fans out to the right and up under the window's bottom edge,
    // a broad, dim second prong of the light.
    let sheetSegs: [[CGPoint]] = [[CGPoint(x: 168, y: 300), CGPoint(x: 210, y: 230), CGPoint(x: 430, y: 300), CGPoint(x: 740, y: 470)]]
    let sheet = ribbon(px: px, scale: k, pts: sample(sheetSegs, perSegment: 300), width: { t in 18 + 120 * smooth(0, 0.8, t) },
                       color: { t in mix(tealLight, tealDeep, 0.25 * t) },
                       alpha: { t in 0.55 * smooth(0, 0.25, t) * (1 - 0.6 * smooth(0.45, 1, t)) * (1 + 0.15 * sin(14 * t)) })
    let sheetCI = ciImage(sheet)
    // Its brighter upper edge, so the second prong reads as light and not just haze.
    let sheetEdge = sample([[CGPoint(x: 168, y: 300), CGPoint(x: 220, y: 250), CGPoint(x: 440, y: 330), CGPoint(x: 720, y: 500)]], perSegment: 300)
    light = add(light, ciImage(ribbon(px: px, scale: k, pts: sheetEdge, width: { t in 6 + 26 * smooth(0, 0.7, t) },
                                      color: { _ in rgb(tealLight) },
                                      alpha: { t in 0.42 * smooth(0, 0.2, t) * (1 - 0.5 * smooth(0.6, 1, t)) * (1 + 0.2 * sin(17 * t + 1)) })))
    // The core: a narrow near-white line down the main ribbon, brightest near the window.
    let core = ciImage(ribbon(px: px, scale: k, pts: base, width: { t in 22 * taper(t) },
                              color: { t in mix(tealLight, 0xF2FFFD, smooth(0.35, 0.85, t)) },
                              alpha: { t in 0.85 * smooth(0.2, 0.75, t) * level(t, 0) }))

    // Specks: a few small soft points of light near the brightest stretch.
    let speckCtx = newContext(px)
    speckCtx.scaleBy(x: k, y: k)
    let specks: [(t: CGFloat, o: CGFloat, r: CGFloat, a: CGFloat)] = [
        (0.58, 52, 5, 0.55), (0.66, -38, 3.5, 0.5), (0.72, 84, 4, 0.4), (0.80, 18, 6, 0.6),
        (0.84, -60, 3, 0.45), (0.89, 62, 4.5, 0.5), (0.48, -20, 3, 0.35),
    ]
    for sp in specks {
        let i = Int(sp.t * CGFloat(n - 1))
        let c = CGPoint(x: base[i].x + normals[i].dx * sp.o * fan(sp.t), y: base[i].y + normals[i].dy * sp.o * fan(sp.t))
        let g = CGGradient(colorsSpace: srgb, colors: [rgb(0xF4FFFD, sp.a), rgb(tealLight, sp.a * 0.45), rgb(tealLight, 0)] as CFArray,
                           locations: [0, 0.35, 1])!
        speckCtx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: sp.r * 2.6, options: [])
    }
    let speck = ciImage(speckCtx.makeImage()!)

    let all = add(add(light, gain(filaments, 0.9)), gain(sheetCI, 0.5))
    var out = gain(blur(all, 150 * k), 0.30, r: 0.6, g: 1, b: 1.0)              // spill onto the tile
    out = add(out, gain(blur(all, 60 * k), 0.40, r: 0.5, g: 1, b: 0.95))       // cyan haze
    out = add(out, gain(blur(all, 18 * k), 0.48, b: 0.88))                             // glow
    out = add(out, gain(blur(sheetCI, 26 * k), 0.5))                           // the lower sheet, all haze
    out = add(out, gain(blur(light, 6 * k), 0.88, b: 0.9))                                    // the strands, soft-edged
    out = add(out, blur(filaments, 1.4 * k))                                    // fine filaments
    out = add(out, gain(blur(core, 12 * k), 0.55))                              // bloom of the core
    out = add(out, gain(blur(core, 3 * k), 0.6))                             // the core
    out = add(out, gain(add(blur(speck, 0.8 * k), gain(blur(speck, 6 * k), 0.6)), 0.7))
    return out
}

/// 16-bit RGBA to 8-bit with a random dither, so the soft gradients don't band.
func dither(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    var src = [UInt16](repeating: 0, count: w * h * 4)
    let sctx = CGContext(data: &src, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: srgb,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    sctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var dst = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt32 = 0x9E3779B9
    for p in 0..<(w * h) {
        let a8 = UInt8(min(255, max(0, (Float(src[p * 4 + 3]) / 257).rounded())))
        dst[p * 4 + 3] = a8
        for c in 0..<3 {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let v = Float(src[p * 4 + c]) / 257 + Float(seed & 0xFFFF) / 65536 - 0.5
            dst[p * 4 + c] = UInt8(min(Float(a8), max(0, v.rounded())))
        }
    }
    let dctx = CGContext(data: &dst, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return dctx.makeImage()!
}

/// 128 px and up: the trail as light (trailLight), the window lit by it, drawn at 16 bits then dithered.
func renderDetailed(_ px: Int) -> CGImage {
    let k = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 16, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    ctx.scaleBy(x: k, y: k)
    drawTile(ctx, k: k, detail: true)
    ctx.saveGState()
    ctx.addPath(continuousRect(body, radius: tileRadius)); ctx.clip()
    drawWindowShadow(ctx, k: k, alpha: 0.5) // under the light: the trail glows over the shadow
    let light = trailLight(px: px, k: k)
    composite(ctx, cgImage(light), blend: .plusLighter)
    let backdrop = ctx.makeImage()!
    drawWindow(ctx, px: px, k: k, detail: true, backdrop: backdrop, light: light)
    ctx.restoreGState()
    return dither(ctx.makeImage()!)
}

// MARK: The painted art at 64 px and up

/// scripts/assets/icon-art.png: the painted "Trail" fitted to the grid by scripts/prepare-icon-art.py
/// (the finished tile, squircle-shaped, its glass rim painted in). When it is there, 64 px and up use
/// it instead of the code-drawn version; 16 and 32 px are always drawn on the pixel grid.
let art: CGImage? = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("assets/icon-art.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}()

func renderArt(_ px: Int, _ art: CGImage) -> CGImage {
    let k = CGFloat(px) / 1024
    let ctx = newContext(px)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: k, y: k)
    let tile = continuousRect(body, radius: tileRadius)
    ctx.saveGState() // the template's soft drop shadow
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: rgb(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(rgb(0x2A2E35)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.draw(art, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) // its own glass rim is painted in
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: Small sizes (16 and 32 px), drawn on the pixel grid

func renderSmall(_ px: Int) -> CGImage {
    let ctx = newContext(px)
    let s = CGFloat(px)
    let inset = (100 / 1024 * s).rounded()
    let tileRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = continuousRect(tileRect, radius: tileRect.width * 185 / 824)
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let g = CGGradient(colorsSpace: srgb, colors: [rgb(0x4A4F58), rgb(0x22262C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: [])

    // Window: an axis-aligned, pixel-snapped white card, lifted to the upper right.
    let win: CGRect, barH: CGFloat, r: CGFloat, lw: CGFloat
    let trail: [[CGPoint]]
    if px <= 16 {
        win = CGRect(x: 7, y: 7, width: 6, height: 5); barH = 1; r = 0; lw = 2
        trail = [[CGPoint(x: 11, y: 4), CGPoint(x: 7, y: 3.6), CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 6)],
                 [CGPoint(x: 4, y: 6), CGPoint(x: 4, y: 7.5), CGPoint(x: 6, y: 8.5), CGPoint(x: 8, y: 9)]]
    } else {
        win = CGRect(x: 14, y: 14, width: 13, height: 10); barH = 2; r = 2; lw = 3
        trail = [[CGPoint(x: 21, y: 7.5), CGPoint(x: 13, y: 6.5), CGPoint(x: 7.5, y: 7.5), CGPoint(x: 7.5, y: 12)],
                 [CGPoint(x: 7.5, y: 12), CGPoint(x: 7.5, y: 15.5), CGPoint(x: 11, y: 17.5), CGPoint(x: 17, y: 18.5)]]
    }
    // The trail: one bold stroke, deep teal at the tail to bright at the window.
    let pts = sample(trail, perSegment: 60)
    ctx.setLineCap(.round)
    for i in 0..<(pts.count - 1) {
        let t = CGFloat(i) / CGFloat(pts.count - 2)
        ctx.setLineWidth(lw * (0.55 + 0.45 * smooth(0, 0.5, t)))
        ctx.setStrokeColor(mix(tealDeep, tealLight, smooth(0, 0.6, t)))
        ctx.move(to: pts[i]); ctx.addLine(to: pts[i + 1]); ctx.strokePath()
    }
    // A one-pixel dark gap around the window so it separates from the trail.
    ctx.addPath(CGPath(roundedRect: win.insetBy(dx: -1, dy: -1), cornerWidth: r + 1, cornerHeight: r + 1, transform: nil))
    ctx.setFillColor(rgb(0x272B31, 0.9)); ctx.fillPath()
    let card = CGPath(roundedRect: win, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(card); ctx.setFillColor(rgb(0xECF2F5)); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(card); ctx.clip()
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: win.minX, y: win.maxY - barH, width: win.width, height: barH))
    ctx.setFillColor(rgb(0x9AA7B0)); ctx.fill(CGRect(x: win.minX, y: win.maxY - barH - 1, width: win.width, height: 1))
    ctx.restoreGState()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func render(_ px: Int) -> Data {
    let img = px <= 32 ? renderSmall(px) : renderLarge(px)
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/assets")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    try! render(s).write(to: set.appendingPathComponent("icon_\(s)x\(s).png"))
    try! render(s * 2).write(to: set.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(dir.path)/AppIcon.icns" : "iconutil failed")
