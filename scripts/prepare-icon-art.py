#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fits the painted "Trail" icon art onto Apple's macOS icon grid, for scripts/make-icon.swift.

The art is a 1024 px render with its own tile: larger than Apple's 824 px body and rounder at the
corners. It is scaled so its tile spans the body (inset 100 px), then the outer band of the tile is
stretched radially so its edge, bevel and all, lands exactly on Apple's continuous-corner squircle;
the interior is untouched. Output: a 1024 px RGBA PNG of the finished tile (no shadow), which
make-icon.swift clips to the squircle and shadows. Run once when the art changes (Pillow, NumPy, SciPy):

    python3 scripts/prepare-icon-art.py art.png scripts/assets/icon-art.png
"""
import sys
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

BAND = 64         # px (output) of the tile's edge that is stretched; inside it the art is untouched
SS = 4            # supersampling for the squircle mask

def continuous_rect_mask(size, rect, radius, ss=SS):
    """Apple's continuous-corner rectangle (the same curve as make-icon.swift), antialiased."""
    k = [1.52866483, 1.08849299, 0.86840701, 0.63149399, 0.07491100, 0.37282401, 0.16905201]
    x0, y0, x1, y1 = rect
    r = min(radius, (x1 - x0) / 2 / k[0])
    corners = [((x0, y0), (0, 1), (1, 0)), ((x1, y0), (-1, 0), (0, 1)),
               ((x1, y1), (0, -1), (-1, 0)), ((x0, y1), (1, 0), (0, -1))]
    pts = []
    def bez(p0, p1, p2, p3, n=40):
        t = np.linspace(0, 1, n)[:, None]
        return ((1-t)**3)*p0 + 3*((1-t)**2)*t*p1 + 3*(1-t)*t*t*p2 + t**3*p3
    for (c, a, b) in corners:
        pt = lambda u, v: np.array([c[0] + (u*a[0] + v*b[0]) * r, c[1] + (u*a[1] + v*b[1]) * r])
        segs = [(pt(k[0], 0), pt(k[1], 0), pt(k[2], 0), pt(k[3], k[4])),
                (pt(k[3], k[4]), pt(k[5], k[6]), pt(k[6], k[5]), pt(k[4], k[3])),
                (pt(k[4], k[3]), pt(0, k[2]), pt(0, k[1]), pt(0, k[0]))]
        for s in segs: pts.extend(bez(*s).tolist())
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).polygon([(x * ss, y * ss) for x, y in pts], fill=255)
    return np.asarray(m.resize((size, size), Image.LANCZOS)).astype(np.float32) / 255

def edge_radius(mask, c, angles, rmax):
    """Distance from c to where mask drops below 0.5, along each angle (sub-pixel)."""
    rs = np.arange(0, rmax, 0.25)
    xs = c[0] + np.cos(angles)[:, None] * rs; ys = c[1] + np.sin(angles)[:, None] * rs
    v = ndimage.map_coordinates(mask, [ys, xs], order=1)
    return rs[np.argmax(v < 0.5, axis=1)]

src, dst = sys.argv[1], sys.argv[2]
art = np.asarray(Image.open(src).convert("RGBA")).astype(np.float32) / 255
a = art[..., 3]
ys, xs = np.where(a > 0.5)
x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1

# Scale the art so its tile's bounding box is the 824 px body.
sx, sy = 824 / (x1 - x0), 824 / (y1 - y0)
yy, xx = np.mgrid[0:1024, 0:1024].astype(np.float32) + 0.5
c = np.array([512.0, 512.0])
squircle = continuous_rect_mask(1024, (100, 100, 924, 924), 185)
# The art's tile in output coordinates (premultiplied channels, sampled with the same scale).
def sample(px, py):
    sxp = (px - 100) / sx + x0 - 0.5; syp = (py - 100) / sy + y0 - 0.5
    return np.stack([ndimage.map_coordinates(art[..., ch] * (a if ch < 3 else 1), [syp, sxp], order=3, mode="constant")
                     for ch in range(4)], -1)
art_alpha_out = sample(xx, yy)[..., 3]

angles = np.linspace(-np.pi, np.pi, 4096, endpoint=False)
r_sq = edge_radius(squircle, c, angles, 740)
r_art = edge_radius(art_alpha_out, c, angles, 740) - 0.5   # just inside the art's antialiased edge

# For each output pixel: its angle and distance; map distances in the outer band [r_sq-BAND, r_sq]
# onto [r_sq-BAND, r_art], so the art's edge meets the squircle's.
dx, dy = xx - c[0], yy - c[1]
d = np.hypot(dx, dy); th = np.arctan2(dy, dx)
idx = ((th + np.pi) / (2 * np.pi) * len(angles)).astype(int) % len(angles)
rs, ra = r_sq[idx], r_art[idx]
inner = rs - BAND
t = np.clip((d - inner) / BAND, 0, None)
d2 = np.where(d > inner, inner + t * (ra - inner), d)
scale = np.where(d > 0, d2 / np.maximum(d, 1e-6), 1)
out = sample(c[0] + dx * scale, c[1] + dy * scale)
rgb = out[..., :3] / np.maximum(out[..., 3:], 1e-6)
alpha = squircle
img = np.dstack([rgb.clip(0, 1), alpha]) * 255
Image.fromarray(img.round().astype(np.uint8), "RGBA").save(dst, optimize=True)
print(f"wrote {dst} (scale {sx:.4f} x {sy:.4f}; edge stretch {np.min(ra - rs):+.1f} to {np.max(ra - rs):+.1f} px)")
