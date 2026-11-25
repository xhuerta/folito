#!/usr/bin/env python3
"""Renames the PNGs exported by `xcresulttool export attachments` after their attachment names.

Usage: scripts/ci/name_attachments.py <export-dir>
"""
import json
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
for test in json.loads((out / "manifest.json").read_text()):
    for a in test.get("attachments", []):
        src, name = out / a["exportedFileName"], a.get("suggestedHumanReadableName", "")
        if src.exists() and name:
            stem = name.rsplit(".", 1)[0].split("_")[0] if name.count("_") >= 2 else name.rsplit(".", 1)[0]
            # actions/upload-artifact refuses paths with " : < > | * ? or line breaks (failure attachments such as
            # 'Debug description for `"catalogDownload" Button`' made the whole catalogs-screenshots upload fail).
            stem = re.sub(r'[":<>|*?\r\n\\/]', "-", stem)
            src.rename(out / (stem + src.suffix))
