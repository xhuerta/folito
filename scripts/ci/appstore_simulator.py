#!/usr/bin/env python3
"""Prints the UDID of the simulator the App Store screenshots of one display class are taken on.

Classes (docs/appstore/SCREENSHOTS.md): `iphone-medium` and `iphone-large` are the two iPhone sizes App Store
Connect needs ("Dynamic Island, medium display" and "Dynamic Island, large display"); `watch` is the one Apple
Watch size used in every localization. Each class has a list of device models in order of preference, newest
first; the first model the runner has (on its newest runtime) is used, and when it has none of them as a
device, one is created from the first model whose device type is installed. Only models whose screen is an
accepted screenshot size are listed: an Apple Watch Series 11 (42mm), for instance, is not.

Exits 1, with the available models on stderr, when the runner cannot provide the class: the workflow then
fails instead of capturing a size App Store Connect would refuse. scripts/ci/check_screenshot_sizes.py
checks the pixels of what was captured.

Usage: scripts/ci/appstore_simulator.py iphone-medium|iphone-large|watch
       scripts/ci/appstore_simulator.py --self-test
"""
import json
import re
import subprocess
import sys

CLASSES = {
    # 1206 x 2622, then 1179 x 2556.
    "iphone-medium": ("iOS", ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16", "iPhone 15 Pro",
                              "iPhone 15", "iPhone 14 Pro"]),
    # 1320 x 2868, then 1290 x 2796, then 1260 x 2736.
    "iphone-large": ("iOS", ["iPhone 17 Pro Max", "iPhone 16 Pro Max", "iPhone 16 Plus", "iPhone 15 Pro Max",
                             "iPhone 15 Plus", "iPhone 14 Pro Max", "iPhone Air"]),
    # 422 x 514, 410 x 502, 416 x 496, 396 x 484.
    "watch": ("watchOS", ["Apple Watch Ultra 3 (49mm)", "Apple Watch Ultra 2 (49mm)", "Apple Watch Ultra (49mm)",
                          "Apple Watch Series 11 (46mm)", "Apple Watch Series 10 (46mm)",
                          "Apple Watch Series 9 (45mm)", "Apple Watch Series 8 (45mm)",
                          "Apple Watch Series 7 (45mm)"]),
}


def version(runtime_id):
    """com.apple.CoreSimulator.SimRuntime.iOS-18-5 -> [18, 5]"""
    return [int(n) for n in re.findall(r"\d+", runtime_id.split(".")[-1])]


def runtimes(listing, platform):
    """Identifiers of the installed runtimes of `platform`, newest first."""
    ids = {r["identifier"] for r in listing.get("runtimes", []) if r.get("isAvailable", True)}
    ids |= set(listing.get("devices", {}))
    return sorted((i for i in ids if i.split(".")[-1].startswith(platform + "-")), key=version, reverse=True)


def choose(listing, name):
    """("device", udid, model) for an existing simulator, ("create", device type, runtime, model) for one to
    create, or None when the runner has none of the class's models."""
    platform, models = CLASSES[name]
    available = runtimes(listing, platform)
    for model in models:
        for runtime in available:
            for device in listing.get("devices", {}).get(runtime, []):
                if device["name"] == model and device.get("isAvailable", True):
                    return ("device", device["udid"], model)
    types = {t["name"]: t["identifier"] for t in listing.get("devicetypes", [])}
    for model in models:
        if model in types and available:
            return ("create", types[model], available[0], model)
    return None


def self_test():
    listing = {
        "runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5", "isAvailable": True},
                     {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "isAvailable": True},
                     {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-1", "isAvailable": True}],
        "devicetypes": [{"name": "Apple Watch Ultra 2 (49mm)", "identifier": "type.ultra2"},
                        {"name": "iPhone 16 Plus", "identifier": "type.16plus"}],
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16 Pro", "udid": "OLD-16-PRO", "isAvailable": True},
                {"name": "iPhone 16 Pro Max", "udid": "GONE", "isAvailable": False}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
                {"name": "iPhone 17 Pro Max", "udid": "NEW-17-PRO-MAX", "isAvailable": True},
                {"name": "iPhone 16 Pro", "udid": "NEW-16-PRO", "isAvailable": True},
                {"name": "iPhone 17 Pro", "udid": "NEW-17-PRO", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-1": [
                {"name": "Apple Watch Series 11 (42mm)", "udid": "SMALL", "isAvailable": True}],
        },
    }
    assert choose(listing, "iphone-medium") == ("device", "NEW-17-PRO", "iPhone 17 Pro")
    assert choose(listing, "iphone-large") == ("device", "NEW-17-PRO-MAX", "iPhone 17 Pro Max")
    # The 42 mm watch is not an accepted size: a 49 mm one is created instead.
    assert choose(listing, "watch") == ("create", "type.ultra2", "com.apple.CoreSimulator.SimRuntime.watchOS-26-1",
                                        "Apple Watch Ultra 2 (49mm)")
    del listing["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-1"][0]
    assert choose(listing, "iphone-large") == ("create", "type.16plus", "com.apple.CoreSimulator.SimRuntime.iOS-26-1",
                                               "iPhone 16 Plus")
    listing["devicetypes"] = []
    assert choose(listing, "watch") is None
    print("appstore_simulator self-test OK")


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) != 2 or sys.argv[1] not in CLASSES:
        sys.exit(__doc__)
    name = sys.argv[1]
    listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "-j"], check=True, capture_output=True).stdout)
    picked = choose(listing, name)
    if picked is None:
        platform, models = CLASSES[name]
        have = sorted({d["name"] for r in runtimes(listing, platform) for d in listing["devices"].get(r, [])})
        print(f"no simulator for App Store class {name}: wanted one of {models}; the runner has {have}",
              file=sys.stderr)
        sys.exit(1)
    if picked[0] == "create":
        _, device_type, runtime, model = picked
        udid = subprocess.run(["xcrun", "simctl", "create", f"App Store {name}", device_type, runtime],
                              check=True, capture_output=True, text=True).stdout.strip()
        print(f"{name}: created {model} on {runtime.split('.')[-1]}", file=sys.stderr)
    else:
        _, udid, model = picked
        print(f"{name}: {model}", file=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
