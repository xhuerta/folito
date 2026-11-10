#!/usr/bin/env python3
"""Sorts the attachments of one UI-test result bundle into one directory per suite.

macos.yml runs the iPhone UI suites in a single `xcodebuild` call (one result bundle) and still uploads one
screenshot artifact per suite. This script takes the directory written by
`xcrun xcresulttool export attachments` and moves every attachment into the directory of its test class, named
after the attachment (same naming as name_attachments.py).

Usage: scripts/ci/split_ui_attachments.py <export-dir> <TestClass>=<directory> [...]
"""
import json
import pathlib
import sys

export = pathlib.Path(sys.argv[1])
suites = dict(arg.split("=", 1) for arg in sys.argv[2:])
for directory in suites.values():
    pathlib.Path(directory).mkdir(parents=True, exist_ok=True)

for test in json.loads((export / "manifest.json").read_text()):
    identifier = test.get("testIdentifier", "")
    directory = next((d for cls, d in suites.items() if cls in identifier), None)
    if directory is None:
        print(f"warning: no directory for the attachments of {identifier!r}", file=sys.stderr)
        continue
    for a in test.get("attachments", []):
        src, name = export / a["exportedFileName"], a.get("suggestedHumanReadableName", "")
        if not src.exists():
            continue
        stem = src.stem
        if name:
            stem = name.rsplit(".", 1)[0].split("_")[0] if name.count("_") >= 2 else name.rsplit(".", 1)[0]
        src.rename(pathlib.Path(directory) / (stem + src.suffix))
