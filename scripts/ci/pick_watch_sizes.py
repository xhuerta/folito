#!/usr/bin/env python3
"""Reads `xcrun simctl list devices available -j` on stdin and prints the UDIDs of the smallest and the
largest Apple Watch simulator (by the case size in the name, e.g. "(41mm)") of the newest watchOS runtime.
Prints one UDID when only one size is available."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]


def version(key):
    return [int(n) for n in re.findall(r"\d+", key.split(".")[-1])]


runtimes = sorted((k for k in devices if "watchOS" in k and devices[k]), key=version)
watches = []
for key in reversed(runtimes):
    watches = [d for d in devices[key] if d["name"].startswith("Apple Watch") and re.search(r"\((\d+)mm\)", d["name"])]
    if watches:
        break
if not watches:
    sys.exit(0)
watches.sort(key=lambda d: int(re.search(r"\((\d+)mm\)", d["name"]).group(1)))
picked = [watches[0]] if watches[0]["udid"] == watches[-1]["udid"] else [watches[0], watches[-1]]
for d in picked:
    print(d["name"], file=sys.stderr)
print(" ".join(d["udid"] for d in picked))
