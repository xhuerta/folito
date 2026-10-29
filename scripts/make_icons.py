#!/usr/bin/env python3
"""Deterministically generates the Folito app icon (1024x1024, opaque, square corners).

Motif (owner-provided design, redrawn as vector-like shapes so it is crisp at 1024 px):
an open book inside a circular arrow on a blue gradient. The book was traced from
measurements of the owner's reference image. Writes the same PNG into the iOS and
watchOS asset catalogs (the system applies the rounded-rect / circular mask).
Requires Pillow. Usage: python3 scripts/make_icons.py
"""
import os
import math
from PIL import Image, ImageChops, ImageDraw, ImageFilter

K = 4                       # supersampling factor
S = 1024 * K
CX = 512                    # book is mirrored around this x

def P(x, y): return (x * K, y * K)

def bez(p0, p1, p2, n=40):
    return [((1-t)**2*p0[0] + 2*(1-t)*t*p1[0] + t*t*p2[0],
             (1-t)**2*p0[1] + 2*(1-t)*t*p1[1] + t*t*p2[1]) for t in (i/n for i in range(n+1))]

def mirror(pts): return [(2*CX - x, y) for x, y in pts]

def rounded_mask(pts, radius):
    """Polygon mask with softened corners (blur + threshold at supersampled size)."""
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon([P(x, y) for x, y in pts], fill=255)
    if radius:
        m = m.filter(ImageFilter.GaussianBlur(radius * K)).point(lambda v: 255 if v > 127 else 0)
    return m

def vgrad(top, bottom):
    g = Image.new("RGB", (1, S))
    for y in range(S):
        t = (y / (S - 1)) ** 0.9
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((S, S))

def render():
    img = vgrad((6, 140, 242), (6, 26, 84))
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse(P(212, -260) + P(812, 300), fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(120 * K))
    img = Image.composite(Image.new("RGB", (S, S), (70, 175, 255)), img, glow)
    d = ImageDraw.Draw(img)

    # ---- ring with arrow (measured: centre ~ (512, 527), outer radius ~ 382)
    cx, cy, r, w = 512 * K, 527 * K, 382 * K, 46 * K
    ring = (205, 240, 250)
    tail, head = 95, 62 + 360
    bbox = (cx - r, cy - r, cx + r, cy + r)
    for i, a in enumerate(range(tail, tail + 45)):
        t = i / 45
        col = tuple(int(ring[k] * t + (40, 110, 190)[k] * (1 - t)) for k in range(3))
        d.arc(bbox, a, a + 2, fill=col, width=int(w * (0.5 + 0.5 * t)))
    d.arc(bbox, tail + 44, head, fill=ring, width=w)
    a = math.radians(head)
    rm = r - w / 2                                   # centre line of the stroke
    hx, hy = cx + rm * math.cos(a), cy + rm * math.sin(a)
    tx, ty = -math.sin(a), math.cos(a)
    nx, ny = math.cos(a), math.sin(a)
    L, Wd = w * 2.2, w * 1.4
    d.polygon([(hx + tx * L, hy + ty * L),
               (hx + nx * Wd, hy + ny * Wd),
               (hx - nx * Wd, hy - ny * Wd)], fill=(225, 248, 255))

    # ---- book (left half measured, right half mirrored). Coordinates at 1024 scale.
    # 1) U-shaped cover outline (stroke), notch at the spine.
    # Explicit path: left upright, gently descending bottom, rounded U-notch at the spine,
    # mirrored bottom and right upright.
    left = [(265, 389), (265, 640)] + bez((265, 640), (380, 654), (452, 668))[1:] \
           + bez((452, 668), (488, 672), (497, 688))[1:]
    notch = bez((497, 688), (CX, 714), (2 * CX - 497, 688))[1:]
    cover = left + notch + mirror(left[::-1])[1:]
    cw = 21
    # Round-brush stroke: stamp a disc every ~0.5 px along the path (clean joins, round caps).
    def stamps(path):
        for (x0, y0), (x1, y1) in zip(path, path[1:]):
            n = max(1, int(math.hypot(x1 - x0, y1 - y0) * 2))
            for i in range(n + 1):
                t = i / n
                yield x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
    for x, y in stamps(cover):
        d.ellipse(P(x - cw / 2, y - cw / 2) + P(x + cw / 2, y + cw / 2), fill=(140, 212, 234))

    # 2) second page layer (light blue), visible as a strip on the outside and at the bottom.
    front_top = bez((351, 309), (455, 320), (499, 412))
    layer = [(301, 347), (352, 347)] + [(x, y + 34) for x, y in front_top if x > 352] \
            + [(499, 446), (499, 668)] + bez((499, 668), (390, 602), (301, 602))[1:]
    # 3) front page (white).
    front = front_top + [(499, 662)] + bez((499, 662), (400, 560), (347, 549))[1:]

    for pts, col in ((layer, (190, 220, 238)), (front, (247, 251, 254))):
        for side in (pts, mirror(pts)):
            img.paste(Image.new("RGB", (S, S), col), (0, 0), rounded_mask(side, 6))

    # soft shading of the front pages toward the spine
    shade = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(shade)
    for side in (front, mirror(front)):
        sd.polygon([P(x, y) for x, y in side], fill=255)
    fade = Image.new("L", (S, S), 0)
    fd = ImageDraw.Draw(fade)
    for i in range(60):
        v = int(70 * (1 - i / 60))
        fd.line(P(CX - 13 - i, 0) + P(CX - 13 - i, 1024), fill=v, width=K)
        fd.line(P(CX + 13 + i, 0) + P(CX + 13 + i, 1024), fill=v, width=K)
    mask = ImageChops.multiply(shade, fade)
    img = Image.composite(Image.new("RGB", (S, S), (170, 200, 222)), img, mask)
    return img.resize((1024, 1024), Image.LANCZOS)


OUTPUTS = (
    "iOSApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
    "WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    img = render()
    for rel in OUTPUTS:
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        img.save(path, "PNG", optimize=True)
        print("wrote", rel)


if __name__ == "__main__":
    main()
