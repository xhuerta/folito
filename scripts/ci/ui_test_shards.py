#!/usr/bin/env python3
"""The two shards of the iPhone UI suites (macos.yml, UI tier), and the check that every UI test class runs.

Every XCTestCase subclass under iOSApp/UITests is either in exactly one shard of SHARDS or in RUN_ELSEWHERE (the
workflow that runs it instead). `--check` fails otherwise, so a new class cannot silently stop running; it also
runs in `--matrix`, i.e. in macos.yml's `scope` job, and in linux.yml's `ci-scripts`.

The `ios` job runs shard ui-1 after the unit tests, on the app it built for them; the `ios-ui-2` job (the same
`test` job of macos.yml, another matrix leg) builds the app and runs shard ui-2 only. The shards are balanced by
the duration of the classes on CI (main, Nov 2026): Onboarding 3 min, OnlineMetadata 3.5, Covers 2.5,
ReadestLibrary 2, Catalogs about 11 (with search); LibraryBrowse (6 tests, new in #211) goes with Catalogs
in ui-2, as ui-1 also waits for the unit tests (about 1.5 min).

Usage: scripts/ci/ui_test_shards.py --check
       scripts/ci/ui_test_shards.py --only-testing ui-1      # -only-testing arguments, one per line
       scripts/ci/ui_test_shards.py --artifacts ui-1         # Class=artifact-directory, for split_ui_attachments.py
       scripts/ci/ui_test_shards.py --matrix '["ios","watch"]' --ui-tier true    # the `test` job's matrix (JSON)
       scripts/ci/ui_test_shards.py --self-test
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
UI_TESTS = ROOT / "iOSApp/UITests"
BUNDLE = "FolitoUITests"

SHARDS = {
    "ui-1": ["OnboardingUITests", "ReadestLibraryUITests", "CoversUITests", "OnlineMetadataUITests"],
    "ui-2": ["CatalogsUITests", "LibraryBrowseUITests"],
}
# Screenshot artifact of each class (one artifact per suite).
ARTIFACTS = {
    "OnboardingUITests": "onboarding-screenshots",
    "ReadestLibraryUITests": "readest-library-screenshots",
    "CoversUITests": "covers-iphone",
    "OnlineMetadataUITests": "online-metadata-screenshots",
    "CatalogsUITests": "catalogs-screenshots",
    "LibraryBrowseUITests": "library-browse-screenshots",
}
# Classes of the bundle that the UI tier does not run, and where they run.
RUN_ELSEWHERE = {
    "AccessibilityAuditTests": "accessibility.yml (audit shards)",
    "AppStoreScreenshotTests": "macos.yml app-store-iphone (label `screenshots`), app-store-localized.yml",
}

CLASS_RE = re.compile(r"\bclass[ \t]+(\w+)[ \t]*:[ \t]*([\w.]+)")


def test_classes(sources):
    """Names of the XCTestCase subclasses (direct or through another class of the sources) in {name: text}."""
    parents = {}
    for text in sources.values():
        text = re.sub(r"//[^\n]*", "", text)
        for name, parent in CLASS_RE.findall(text):
            parents[name] = parent.split(".")[-1]
    found = set()
    for name in parents:
        seen, cur = set(), name
        while cur in parents and cur not in seen:
            seen.add(cur)
            cur = parents[cur]
        if cur == "XCTestCase":
            found.add(name)
    return found


def problems(classes):
    out = []
    assigned = {}
    for shard, names in SHARDS.items():
        for n in names:
            if n in assigned or n in RUN_ELSEWHERE:
                out.append(f"{n} is assigned more than once ({assigned.get(n, 'RUN_ELSEWHERE')}, {shard})")
            assigned[n] = shard
            if n not in ARTIFACTS:
                out.append(f"{n} has no screenshot artifact in ARTIFACTS")
    for n in sorted(classes):
        if n not in assigned and n not in RUN_ELSEWHERE:
            out.append(f"{n} (iOSApp/UITests) is in no UI shard: add it to SHARDS (or RUN_ELSEWHERE) in "
                       f"scripts/ci/ui_test_shards.py")
    for n in sorted(set(assigned) | set(RUN_ELSEWHERE)):
        if n not in classes:
            out.append(f"{n} is listed in scripts/ci/ui_test_shards.py but is not a test class in iOSApp/UITests")
    for shard, names in SHARDS.items():
        if not names:
            out.append(f"shard {shard} is empty")
    return out


def check():
    sources = {p.name: p.read_text() for p in sorted(UI_TESTS.rglob("*.swift"))}
    issues = problems(test_classes(sources))
    for i in issues:
        print(f"::error::{i}", file=sys.stderr)
    if not issues:
        print(f"UI shards: every test class of iOSApp/UITests runs ({', '.join(f'{s}: {len(n)}' for s, n in SHARDS.items())})",
              file=sys.stderr)
    return 1 if issues else 0


def matrix(platforms, ui_tier):
    """The `test` job's matrix: one leg per platform, plus ios-ui-2 in the UI tier."""
    legs = []
    for p in platforms:
        if p == "ios":
            legs.append({"platform": "ios", "name": "ios", "ui_shard": "ui-1" if ui_tier else "", "ui_only": False})
            if ui_tier:
                legs += [{"platform": "ios", "name": f"ios-{s}", "ui_shard": s, "ui_only": True}
                         for s in SHARDS if s != "ui-1"]
        else:
            legs.append({"platform": p, "name": p, "ui_shard": "", "ui_only": False})
    return {"include": legs}


def self_test():
    failed = 0
    sources = {
        "A.swift": "import XCTest\nfinal class A: XCTestCase {}\n@MainActor final class B: XCTestCase {}\n",
        "C.swift": "class Base: XCTestCase {}\nfinal class D: Base {}\nstruct E {}\nclass F: NSObject {}\n"
                   "// final class Commented: XCTestCase {}\nenum G { final class H: XCTest.XCTestCase {} }\n",
    }
    got = test_classes(sources)
    want = {"A", "B", "Base", "D", "H"}
    if got != want:
        print(f"FAIL test_classes: got {sorted(got)}, want {sorted(want)}")
        failed += 1
    real = set(n for names in SHARDS.values() for n in names) | set(RUN_ELSEWHERE)
    if problems(real):
        print(f"FAIL problems(real classes): {problems(real)}")
        failed += 1
    if not any("NewUITests" in p for p in problems(real | {"NewUITests"})):
        print("FAIL an unassigned class is not reported")
        failed += 1
    if not any("CoversUITests" in p for p in problems(real - {"CoversUITests"})):
        print("FAIL a listed class that does not exist is not reported")
        failed += 1
    m = matrix(["ios", "watch"], True)["include"]
    if [(l["name"], l["ui_shard"], l["ui_only"]) for l in m] != [("ios", "ui-1", False), ("ios-ui-2", "ui-2", True),
                                                                   ("watch", "", False)]:
        print(f"FAIL matrix UI tier: {m}")
        failed += 1
    m = matrix(["ios"], False)["include"]
    if [(l["name"], l["ui_shard"]) for l in m] != [("ios", "")]:
        print(f"FAIL matrix fast tier: {m}")
        failed += 1
    if matrix(["watch"], True)["include"] != [{"platform": "watch", "name": "watch", "ui_shard": "", "ui_only": False}]:
        print("FAIL matrix watch only")
        failed += 1
    print(f"ui_test_shards self-test: {'FAILED' if failed else 'ok'}")
    return 1 if failed or check() else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--self-test", action="store_true")
    g.add_argument("--only-testing", metavar="SHARD", choices=sorted(SHARDS))
    g.add_argument("--artifacts", metavar="SHARD", choices=sorted(SHARDS))
    g.add_argument("--matrix", metavar="PLATFORMS_JSON")
    ap.add_argument("--ui-tier", default="false")
    args = ap.parse_args()
    if args.check:
        sys.exit(check())
    if args.self_test:
        sys.exit(self_test())
    if args.only_testing:
        print("\n".join(f"-only-testing:{BUNDLE}/{n}" for n in SHARDS[args.only_testing]))
    elif args.artifacts:
        print("\n".join(f"{n}={ARTIFACTS[n]}" for n in SHARDS[args.artifacts]))
    else:
        if check():
            sys.exit(1)
        print("matrix=" + json.dumps(matrix(json.loads(args.matrix), args.ui_tier == "true")))
