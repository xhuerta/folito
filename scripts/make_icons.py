#!/usr/bin/env python3
"""Deterministically generates the WristReader app icon (1024x1024, opaque, square corners).

Motif: an open book with a small watch face (and crown) resting above its spine.
Outputs the same PNG into the iOS and watchOS asset catalogs. Requires Pillow.
Usage: python3 scripts/make_icons.py
"""
import math
import os
from PIL import Image, ImageDraw

SIZE = 1024
SS = 2  # supersampling factor
S = SIZE * SS

BG_TOP = (24, 54, 88)
BG_BOTTOM = (11, 27, 48)
PAGE_L = (250, 244, 230)
PAGE_R = (238, 229, 208)
PAGE_EDGE = (205, 190, 160)
COVER = (232, 140, 58)
LINE = (190, 176, 148)
FACE = (14, 30, 52)
RING = (232, 140, 58)
HAND = (250, 244, 230)


def p(x, y):
    return (x * S / 1024.0, y * S / 1024.0)


def pts(seq):
    return [p(x, y) for x, y in seq]


def bezier(p0, p1, p2, n=40):
    out = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        out.append((x, y))
    return out


def background():
    img = Image.new("RGB", (S, S))
    px = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
        px.line([(0, y), (S, y)], fill=c)
    return img


def draw(img):
    d = ImageDraw.Draw(img)
    # Cover (slightly larger, behind the pages).
    cover = pts([(120, 470), (512, 560), (904, 470), (904, 800), (512, 890), (120, 800)])
    d.polygon(cover, fill=COVER)
    # Left page: top edge curves up toward the spine.
    left = [p(*q) for q in bezier((150, 440), (330, 400), (512, 520))]
    left += pts([(512, 840)])
    left += [p(*q) for q in bezier((512, 840), (330, 730), (150, 770))]
    d.polygon(left, fill=PAGE_L)
    right = [p(*q) for q in bezier((874, 440), (694, 400), (512, 520))]
    right += pts([(512, 840)])
    right += [p(*q) for q in bezier((512, 840), (694, 730), (874, 770))]
    d.polygon(right, fill=PAGE_R)
    # Spine shadow line.
    d.line(pts([(512, 520), (512, 840)]), fill=PAGE_EDGE, width=int(8 * SS))
    # Text lines on both pages.
    for i in range(4):
        y0 = 560 + i * 48
        a = [p(*q) for q in bezier((200, y0 - 20), (330, y0 - 30), (470, y0 + 28))]
        b = [p(*q) for q in bezier((554, y0 + 28), (694, y0 - 30), (824, y0 - 20))]
        d.line(a, fill=LINE, width=int(12 * SS), joint="curve")
        d.line(b, fill=LINE, width=int(12 * SS), joint="curve")

    # Watch face above the spine.
    cx, cy, r = 512, 330, 190
    cxs, cys = p(cx, cy)
    rs = r * SS * S / SIZE / SS
    # Crown on the right side.
    d.rounded_rectangle([p(cx + r - 6, cy - 34), p(cx + r + 44, cy + 34)], radius=14 * SS, fill=RING)
    d.ellipse([cxs - rs, cys - rs, cxs + rs, cys + rs], fill=RING)
    ri = rs * 0.86
    d.ellipse([cxs - ri, cys - ri, cxs + ri, cys + ri], fill=FACE)
    # Hour ticks.
    for k in range(12):
        a = math.radians(k * 30)
        r1, r2 = ri * (0.80 if k % 3 == 0 else 0.86), ri * 0.94
        w = int((14 if k % 3 == 0 else 8) * SS)
        d.line([(cxs + r1 * math.sin(a), cys - r1 * math.cos(a)),
                (cxs + r2 * math.sin(a), cys - r2 * math.cos(a))], fill=HAND, width=w)
    # Hands: roughly 10:10.
    for ang, ln, w in ((-60, 0.52, 18), (60, 0.70, 14)):
        a = math.radians(ang)
        d.line([(cxs, cys), (cxs + ri * ln * math.sin(a), cys - ri * ln * math.cos(a))],
               fill=HAND, width=int(w * SS), joint="curve")
    hub = 16 * SS
    d.ellipse([cxs - hub, cys - hub, cxs + hub, cys + hub], fill=RING)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    img = background()
    draw(img)
    img = img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    for rel in ("iOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
                "WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img.save(path, "PNG", optimize=True)
        print("wrote", rel)


if __name__ == "__main__":
    main()
