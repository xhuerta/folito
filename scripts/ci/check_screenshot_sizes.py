#!/usr/bin/env python3
"""Checks that the App Store screenshots are in sizes App Store Connect accepts. Fails (exit 1) otherwise.

The screenshots live in one directory per display class, as the `app-store-screenshots` artifact of macos.yml
has them:

    <root>/iphone-medium/*.png   iPhone with Dynamic Island, medium display (the size Apple requires)
    <root>/iphone-large/*.png    iPhone with Dynamic Island, large display (otherwise the older Face ID large
                                 size is required)
    <root>/watch/*.png           Apple Watch (required for an app with a watch app)

The artifact holds one such set per language, `<root>/<lang>/<class>/` (en, es, fr, de, it, pt-BR, ja, zh-Hans).
Given a root whose directories are languages, every language set is checked, and the Apple Watch size must be
the same in all of them. A `complications/` directory (complication snapshots for the composed iPhone images)
is not a display class and is not checked.

For every class given with --require, the directory must hold at least one PNG. Every PNG of a class must have
one of the pixel sizes accepted for that class (portrait), all PNGs of a class must have the same size (Apple
asks for one Apple Watch size in every localization; a mixed iPhone set would be a capture mistake), there may
be at most 10 per class, and none may have an alpha channel. Without --require, the classes found are checked.

The sizes are Apple's "Screenshot specifications" (App Store Connect Help),
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
as read on 2026-11-11. Apple adds sizes with each device generation: update ACCEPTED and
docs/appstore/SCREENSHOTS.md together.

Reads only the PNG header (standard library, no Pillow).

Usage: scripts/ci/check_screenshot_sizes.py <root> [--require iphone-medium,iphone-large,watch]
       scripts/ci/check_screenshot_sizes.py --self-test
"""
import pathlib
import struct
import sys
import tempfile
import zlib

ACCEPTED = {
    "iphone-medium": {(1206, 2622), (1179, 2556)},
    "iphone-large": {(1320, 2868), (1290, 2796), (1260, 2736)},
    "watch": {(422, 514), (410, 502), (416, 496), (396, 484), (368, 448), (312, 390)},
}
MAX_PER_CLASS = 10
LANGUAGES = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]
# Inputs of the composed images, not uploaded as they are.
NOT_A_CLASS = {"complications"}
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def png_info(path):
    """(width, height, has_alpha) from the PNG header; raises ValueError for anything that is not a PNG."""
    with open(path, "rb") as f:
        head = f.read(33)
        if len(head) < 33 or head[:8] != PNG_MAGIC or head[12:16] != b"IHDR":
            raise ValueError("not a PNG file")
        width, height, _depth, colour_type = struct.unpack(">IIBB", head[16:26])
        # Colour types 4 and 6 carry an alpha channel; a tRNS chunk adds transparency to the others.
        alpha = colour_type in (4, 6)
        while not alpha:
            chunk = f.read(8)
            if len(chunk) < 8:
                break
            length, kind = struct.unpack(">I4s", chunk)
            if kind == b"tRNS":
                alpha = True
            if kind in (b"IDAT", b"IEND"):
                break
            f.seek(length + 4, 1)
    return width, height, alpha


def check(root, required):
    """Returns (report lines, error lines)."""
    root = pathlib.Path(root)
    report, errors = [], []
    present = [c for c in ACCEPTED if (root / c).is_dir()]
    unknown = sorted(p.name for p in root.iterdir() if p.is_dir() and p.name not in ACCEPTED
                     and p.name not in NOT_A_CLASS) if root.is_dir() else []
    for name in unknown:
        errors.append(f"{name}/: not a known display class ({', '.join(ACCEPTED)})")
    for name in dict.fromkeys(list(required) + present):
        files = sorted((root / name).glob("*.png")) if (root / name).is_dir() else []
        if not files:
            errors.append(f"{name}/: no screenshots")
            continue
        if len(files) > MAX_PER_CLASS:
            errors.append(f"{name}/: {len(files)} screenshots, App Store Connect takes at most {MAX_PER_CLASS}")
        sizes = set()
        for path in files:
            try:
                width, height, alpha = png_info(path)
            except (OSError, ValueError) as error:
                errors.append(f"{name}/{path.name}: {error}")
                continue
            sizes.add((width, height))
            ok = (width, height) in ACCEPTED[name]
            report.append(f"{name}/{path.name}: {width} x {height} {'ok' if ok else 'NOT ACCEPTED'}")
            if not ok:
                wanted = ", ".join(f"{w} x {h}" for w, h in sorted(ACCEPTED[name], reverse=True))
                errors.append(f"{name}/{path.name}: {width} x {height} is not an accepted size ({wanted})")
            if alpha:
                errors.append(f"{name}/{path.name}: has an alpha channel or transparency")
        if len(sizes) > 1:
            errors.append(f"{name}/: mixed sizes {sorted(sizes)}; use one size per display class")
    return report, errors


def check_languages(root, required):
    """Like check(), for a root holding one set per language; the watch size must match across languages."""
    root = pathlib.Path(root)
    report, errors, watch = [], [], {}
    for lang in sorted(p.name for p in root.iterdir() if p.is_dir()):
        if lang not in LANGUAGES:
            errors.append(f"{lang}/: not a screenshot language ({', '.join(LANGUAGES)})")
            continue
        r, e = check(root / lang, required)
        report += [f"{lang}/{line}" for line in r]
        errors += [f"{lang}/{line}" for line in e]
        for path in sorted((root / lang / "watch").glob("*.png")):
            try:
                watch.setdefault(png_info(path)[:2], []).append(lang)
            except (OSError, ValueError):
                pass
    if len(watch) > 1:
        errors.append("watch: sizes differ between languages "
                      + "; ".join(f"{w} x {h}: {', '.join(sorted(set(l)))}" for (w, h), l in sorted(watch.items())))
    return report, errors


def is_language_root(root):
    root = pathlib.Path(root)
    return root.is_dir() and any(p.is_dir() and p.name in LANGUAGES for p in root.iterdir())


def write_png(path, width, height, colour_type=2):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, colour_type, 0, 0, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(PNG_MAGIC + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b""))


def self_test():
    everything = ["iphone-medium", "iphone-large", "watch"]
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        write_png(root / "iphone-medium" / "a.png", 1206, 2622)
        write_png(root / "iphone-large" / "a.png", 1320, 2868)
        write_png(root / "watch" / "a.png", 422, 514)
        write_png(root / "watch" / "b.png", 422, 514)
        assert check(root, everything)[1] == [], check(root, everything)[1]
        assert png_info(root / "watch" / "a.png") == (422, 514, False)

        # A required class that is missing.
        assert any("no screenshots" in e for e in check(root / "watch", ["watch"])[1])
        # iPhone SE and a 42 mm watch: sizes Apple does not take for these classes.
        write_png(root / "iphone-medium" / "se.png", 750, 1334)
        errors = check(root, everything)[1]
        assert any("se.png: 750 x 1334 is not an accepted size" in e for e in errors), errors
        assert any("iphone-medium/: mixed sizes" in e for e in errors), errors
        (root / "iphone-medium" / "se.png").unlink()
        write_png(root / "watch" / "small.png", 374, 446)
        assert any("small.png: 374 x 446 is not an accepted size" in e for e in check(root, everything)[1])
        (root / "watch" / "small.png").unlink()
        # Two accepted watch sizes in one set.
        write_png(root / "watch" / "c.png", 410, 502)
        assert any("watch/: mixed sizes" in e for e in check(root, everything)[1])
        (root / "watch" / "c.png").unlink()
        # Alpha channel, a file that is not a PNG, an unknown directory, too many files.
        write_png(root / "watch" / "alpha.png", 422, 514, colour_type=6)
        assert any("alpha.png: has an alpha channel" in e for e in check(root, everything)[1])
        (root / "watch" / "alpha.png").write_bytes(b"not a png")
        assert any("alpha.png: not a PNG file" in e for e in check(root, everything)[1])
        (root / "watch" / "alpha.png").unlink()
        (root / "ipad").mkdir()
        assert any("ipad/: not a known display class" in e for e in check(root, everything)[1])
        (root / "ipad").rmdir()
        for i in range(MAX_PER_CLASS):
            write_png(root / "iphone-large" / f"more-{i}.png", 1320, 2868)
        assert any("at most 10" in e for e in check(root, everything)[1])
    with tempfile.TemporaryDirectory() as tmp:
        # One set per language, with complication snapshots beside them.
        root = pathlib.Path(tmp)
        for lang in ("en", "ja"):
            write_png(root / lang / "iphone-medium" / "a.png", 1206, 2622)
            write_png(root / lang / "iphone-large" / "a.png", 1320, 2868)
            write_png(root / lang / "watch" / "a.png", 422, 514)
            write_png(root / lang / "complications" / "c.png", 540, 228, colour_type=6)
        assert is_language_root(root) and not is_language_root(root / "en")
        assert check_languages(root, everything)[1] == [], check_languages(root, everything)[1]
        # A language missing a class, and a watch size that differs from the other languages.
        (root / "ja" / "iphone-large" / "a.png").unlink()
        write_png(root / "ja" / "watch" / "a.png", 410, 502)
        errors = check_languages(root, everything)[1]
        assert any(e.startswith("ja/iphone-large/: no screenshots") for e in errors), errors
        assert any("sizes differ between languages" in e for e in errors), errors
        (root / "xx").mkdir()
        assert any("xx/: not a screenshot language" in e for e in check_languages(root, everything)[1])
    print("check_screenshot_sizes self-test OK")


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    required = []
    if "--require" in args:
        i = args.index("--require")
        required = [c for c in args[i + 1].split(",") if c]
        del args[i:i + 2]
    if len(args) != 1 or any(c not in ACCEPTED for c in required):
        sys.exit(__doc__)
    report, errors = (check_languages if is_language_root(args[0]) else check)(args[0], required)
    print("\n".join(report))
    if errors:
        print("\n".join("error: " + e for e in errors), file=sys.stderr)
        sys.exit(1)
    print(f"App Store screenshot sizes OK ({len(report)} images)")


if __name__ == "__main__":
    main()
