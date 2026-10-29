#!/usr/bin/env python3
"""Release sanity checks for built WristReader bundles (pure stdlib; runs on macOS CI).

Usage: validate_release.py [--source-root DIR] [--ios-app PATH.app] [--watch-app PATH.app]...
  Without app paths only the source asset catalogs are checked.
Environment: RELEASE_STRICT=1 also fails when a bundle id still starts with com.example.
Exit code 1 if any check fails; every failure is printed as `FAIL: ...`.
"""
import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import json

failures = []


def fail(msg):
    failures.append(msg)
    print("FAIL:", msg)


def ok(msg):
    print("ok:  ", msg)


def check_png(path, label):
    """AppIcon must be a 1024x1024 PNG without alpha channel/transparency."""
    if not os.path.isfile(path):
        return fail(f"{label}: missing {path}")
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return fail(f"{label}: not a PNG")
    w, h, depth, ctype = struct.unpack(">IIBB", data[16:26])
    if (w, h) != (1024, 1024):
        fail(f"{label}: size is {w}x{h}, expected 1024x1024")
    # PNG color types: 0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA.
    has_trns = b"tRNS" in data[:4096] or b"tRNS" in data
    if ctype in (4, 6) or has_trns:
        fail(f"{label}: icon has an alpha channel / transparency (App Store rejects this)")
    if (w, h) == (1024, 1024) and ctype not in (4, 6) and not has_trns:
        ok(f"{label}: 1024x1024 opaque PNG")


def check_catalog(root, folder, label):
    icon = os.path.join(root, folder, "Assets.xcassets", "AppIcon.appiconset")
    cj = os.path.join(icon, "Contents.json")
    if not os.path.isfile(cj):
        return fail(f"{label}: {cj} missing")
    images = json.load(open(cj)).get("images", [])
    files = [i["filename"] for i in images if i.get("filename")]
    if not files:
        return fail(f"{label}: AppIcon.appiconset/Contents.json references no image file")
    for f in files:
        check_png(os.path.join(icon, f), f"{label} {f}")


def load_plist(path):
    try:
        with open(path, "rb") as fh:
            return plistlib.load(fh)
    except Exception as e:  # noqa: BLE001
        fail(f"cannot read {path}: {e}")
        return None


def check_bundle(app, kind):
    label = f"{kind} ({os.path.basename(app)})"
    if not os.path.isdir(app):
        return fail(f"{label}: bundle not found at {app}")
    info = load_plist(os.path.join(app, "Info.plist"))
    if info is None:
        return
    required = ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "CFBundleDisplayName", "ITSAppUsesNonExemptEncryption", "NSLocalNetworkUsageDescription"]
    required += ["LSApplicationCategoryType", "UILaunchScreen"] if kind == "ios" else ["WKApplication", "WKCompanionAppBundleIdentifier"]
    for key in required:
        if key not in info:
            fail(f"{label}: Info.plist lacks {key}")
    if info.get("ITSAppUsesNonExemptEncryption") is not False:
        fail(f"{label}: ITSAppUsesNonExemptEncryption must be false (see docs/EXPORT_COMPLIANCE.md)")
    ats = info.get("NSAppTransportSecurity", {})
    if ats.get("NSAllowsArbitraryLoads"):
        fail(f"{label}: NSAllowsArbitraryLoads must not be set")
    for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
        if info.get(key):
            fail(f"{label}: {key} should not be enabled for release")
    if "$(" in str(info.get("CFBundleDisplayName", "")) or "$(" in str(info.get("CFBundleIdentifier", "")):
        fail(f"{label}: unexpanded build variable in Info.plist")
    # Icon: compiled catalog + icon name recorded by actool.
    if not os.path.isfile(os.path.join(app, "Assets.car")):
        fail(f"{label}: Assets.car missing (asset catalog not compiled)")
    elif shutil.which("xcrun"):
        r = subprocess.run(["xcrun", "assetutil", "--info", os.path.join(app, "Assets.car")],
                           capture_output=True, text=True)
        if r.returncode == 0:
            try:
                names = {e.get("Name") for e in json.loads(r.stdout) if isinstance(e, dict)}
            except ValueError:
                names = set()
            if "AppIcon" not in names:
                fail(f"{label}: no AppIcon rendition in Assets.car")
            else:
                ok(f"{label}: AppIcon present in Assets.car")
    if "CFBundleIconName" not in info and "CFBundleIcons" not in info:
        fail(f"{label}: Info.plist has no CFBundleIconName/CFBundleIcons (AppIcon not wired)")
    # Privacy manifest.
    pm = os.path.join(app, "PrivacyInfo.xcprivacy")
    if not os.path.isfile(pm):
        fail(f"{label}: PrivacyInfo.xcprivacy missing from bundle")
    else:
        priv = load_plist(pm)
        if priv is not None:
            if priv.get("NSPrivacyTracking") is not False:
                fail(f"{label}: NSPrivacyTracking must be declared false")
            else:
                ok(f"{label}: privacy manifest present")
    # Compiled from Resources/{InfoPlist,Localizable}.xcstrings (see docs/LOCALIZATION.md).
    for lang in ("en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"):
        # English UI strings fall back to the keys, so en.lproj may hold InfoPlist.strings only.
        for table in ("InfoPlist",) if lang == "en" else ("InfoPlist", "Localizable"):
            if not os.path.isfile(os.path.join(app, f"{lang}.lproj", f"{table}.strings")):
                fail(f"{label}: {lang}.lproj/{table}.strings missing")
    bid = info.get("CFBundleIdentifier", "")
    if os.environ.get("RELEASE_STRICT") and bid.startswith("com.example"):
        fail(f"{label}: RELEASE_STRICT set but bundle id is still the placeholder {bid}")
    else:
        ok(f"{label}: bundle id {bid}")
    return info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--ios-app")
    ap.add_argument("--watch-app", action="append", default=[])
    a = ap.parse_args()
    check_catalog(a.source_root, "iOSApp", "iOS")
    check_catalog(a.source_root, "WatchApp", "watchOS")
    if a.ios_app:
        check_bundle(a.ios_app, "ios")
    for w in a.watch_app:
        check_bundle(w, "watch")
    if failures:
        print(f"\n{len(failures)} check(s) failed")
        sys.exit(1)
    print("\nall release checks passed")


if __name__ == "__main__":
    main()
