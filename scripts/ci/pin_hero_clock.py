#!/usr/bin/env python3
"""Paint 9:41 over the clock of the website's watch hero captures (watch-reader-hero/<lang>.png).

`xcrun simctl status_bar ... override --time 9:41` is refused for watchOS simulators ("Status bar overrides
not supported on this platform", Xcode 26.3), so `WatchAppStoreScreenshotTests/testReaderHero` shows the CI
runner's time. This covers it with 9:41, centred where the old time was and as tall, the same way
scripts/compose_appstore_screenshots.py paints 10:09 on the App Store slides (`fix_watch_clock`); nothing
else in the image changes. If the simulator already shows 9:41 (a later Xcode that supports the override),
painting it again changes nothing visible. See docs/appstore/SCREENSHOTS.md, "The website's watch image".

    python3 scripts/ci/pin_hero_clock.py watch-reader-hero/*.png   # rewrites each file in place (RGB PNG)
    python3 scripts/ci/pin_hero_clock.py --self-test

Needs Pillow and a font that compose_appstore_screenshots.py accepts for the clock (Inter, Noto Sans or
DejaVu Sans, found with fc-list). Exits 1 if a file has no clock where the hero's top bar shows it.
"""

import argparse
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from PIL import Image, ImageDraw  # noqa: E402

import compose_appstore_screenshots as compose  # noqa: E402

HERO_TIME = "9:41"
NAME = "watch-reader-hero"


def pin(path):
    """Repaint the clock of one hero capture; False when no clock was found."""
    before = Image.open(path).convert("RGB")
    after = compose.fix_watch_clock(before.copy(), NAME, text=HERO_TIME)
    if after.tobytes() == before.tobytes():
        return False
    after.save(path)
    return True


def self_test():
    w, h = 422, 514
    img = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(img)
    clock, _ = compose.font("clock", 30)
    bb = clock.getbbox("12:40")
    d.text((w / 2 - (bb[2] - bb[0]) / 2 - bb[0], 42 - bb[1]), "12:40", font=clock, fill=(255, 255, 255))
    d.text((120, 82), "Niebla", font=clock, fill=(64, 156, 255))          # the book title, blue
    d.ellipse((34, 40, 104, 104), fill=(40, 40, 40))                       # the back button
    d.rectangle((10, 140, 200, 180), fill=(255, 255, 255))                 # the chapter heading
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "es.png")
        img.save(path)
        assert pin(path), "the clock was not found"
        out = Image.open(path)
        assert out.mode == "RGB" and out.size == (w, h), (out.mode, out.size)
        a, b = img.load(), out.load()
        changed = [(x, y) for y in range(h) for x in range(w) if a[x, y] != b[x, y]]
        assert changed, "nothing was painted"
        xs, ys = [p[0] for p in changed], [p[1] for p in changed]
        assert 30 <= min(ys) and max(ys) <= 80, ("painted outside the clock row", min(ys), max(ys))
        assert w * 0.28 <= min(xs) and max(xs) <= w * 0.72, ("painted outside the clock", min(xs), max(xs))
        # The new time is narrower than "12:40" and centred on it.
        ink = [x for y in range(30, 80) for x in range(w) if min(b[x, y]) > 150]
        assert ink and abs((min(ink) + max(ink)) / 2 - w / 2) < 4, "9:41 is not centred"
        # A capture without a clock is reported, not silently passed.
        blank = os.path.join(tmp, "blank.png")
        Image.new("RGB", (w, h), (0, 0, 0)).save(blank)
        assert not pin(blank)
    print("pin_hero_clock self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    failed = []
    for path in args.files:
        if pin(path):
            print(f"{path}: clock set to {HERO_TIME}")
        else:
            print(f"::error::{path}: no clock found in the top bar")
            failed.append(path)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
