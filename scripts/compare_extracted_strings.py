#!/usr/bin/env python3
"""Compares the strings the Swift compiler extracted during an Xcode build with the String Catalogs.

check_strings.py finds localizable literals with a source scanner (it runs on Linux without Xcode). This
script checks the catalogs against what Xcode itself extracts, so a key whose exact form differs (for example
`%lld` versus `%@` for an interpolated Int, or a different escape) is caught: at run time such a key would
not be found and the text would stay in English.

Input: the `.stringsdata` files that the compiler writes next to the object files when
SWIFT_EMIT_LOC_STRINGS=YES (project.yml), under a DerivedData directory.

Fails (exit 1) when a key extracted for an app target's `Localizable` table is missing from that target's
`Localizable.xcstrings`. Catalog keys the compiler did not extract are listed as warnings (stale, or used
through a `String`/`LocalizedStringResource` variable).

Usage: scripts/compare_extracted_strings.py <DerivedData dir> [...]
"""
from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Xcode target name -> its Localizable catalog. Keep in sync with project.yml and check_strings.py.
TARGETS = {
    "Folito": "iOSApp/Resources/Localizable.xcstrings",
    "FolitoWatch": "WatchApp/Resources/Localizable.xcstrings",
}

TARGET_RE = re.compile(r"/([^/]+)\.build/Objects-normal/")


def load_stringsdata(path: Path) -> dict:
    raw = path.read_bytes()
    try:
        return json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return plistlib.loads(raw)


def extracted_keys(roots: list[Path]) -> tuple[dict[str, dict[str, str]], int]:
    """target -> {key: source file}, number of .stringsdata files read."""
    result: dict[str, dict[str, str]] = {t: {} for t in TARGETS}
    files = 0
    for root in roots:
        for path in root.rglob("*.stringsdata"):
            m = TARGET_RE.search(path.as_posix())
            if not m or m.group(1) not in TARGETS:
                continue
            files += 1
            data = load_stringsdata(path)
            source = Path(str(data.get("source", path.name))).name
            for entry in data.get("tables", {}).get("Localizable", []):
                key = entry.get("key")
                if key:
                    result[m.group(1)].setdefault(key, source)
    return result, files


def main() -> int:
    roots = [Path(a).expanduser() for a in sys.argv[1:]]
    if not roots:
        print(__doc__)
        return 2
    extracted, files = extracted_keys(roots)
    if files == 0:
        print("error: no .stringsdata files for the app targets found (is SWIFT_EMIT_LOC_STRINGS=YES and the "
              f"build done?) under: {', '.join(map(str, roots))}")
        return 1
    errors = 0
    for target, catalog in TARGETS.items():
        keys = set(json.loads((ROOT / catalog).read_text(encoding="utf-8"))["strings"])
        found = extracted[target]
        if not found:
            print(f"error: {target}: nothing extracted (target not built?)")
            errors += 1
            continue
        for key in sorted(set(found) - keys):
            print(f"error: {target}: Xcode extracts {json.dumps(key, ensure_ascii=False)} ({found[key]}) "
                  f"but {catalog} has no such key")
            errors += 1
        for key in sorted(keys - set(found)):
            print(f"warning: {target}: {catalog} key {json.dumps(key, ensure_ascii=False)} was not extracted "
                  "by the compiler (stale, or looked up through a variable)")
        print(f"{target}: {len(found)} keys extracted by Xcode, {len(keys)} in {catalog}")
    if errors:
        print(f"\n{errors} key(s) extracted by Xcode are missing from the catalogs. Copy the exact key into the "
              "catalog (and translate it), or change the source so it produces the existing key.")
        return 1
    print("String Catalogs match what Xcode extracts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
