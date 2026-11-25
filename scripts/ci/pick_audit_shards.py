#!/usr/bin/env python3
"""Decides which accessibility audits a pull request runs (accessibility.yml, job `scope`), from its changed paths.

Reads the changed paths on stdin, one per line, and prints two lines for $GITHUB_OUTPUT:
  platforms=<JSON list>    the platforms to audit: `ios` when at least one iPhone shard runs, `watch` for the watch
                           audit (FolitoWatchUITests);
  ios_shards=<JSON list>   the iPhone audit shards to run (the matrix of the `ios` job).

The platforms follow scripts/ci/pick_platforms.py (iOSApp/ -> ios, WatchApp/ and WatchWidgets/ -> watch, anything
shared or unknown -> both, docs and other workflows -> nothing), with one difference: the unit tests of the apps
(iOSApp/Tests/, WatchApp/Tests/) are not audited, so a change to them alone audits nothing.

The iPhone shards: a path that pick_platforms sends to ios maps to the shards listed for it in SHARDS_FOR_PATH,
and to ALL shards when it is not listed. Only screen files whose screens are audited by a known set of shards are
listed; everything else (LibraryView, which every audit starts from, the models, Support/, Connectivity/, the
String Catalogs, assets, the UI test target itself including AccessibilityAuditTests.swift and its helpers,
Packages/, Shared/, project.yml, scripts/ci/, the workflow) runs every shard. When in doubt, run it: a missed
shard is worse than an extra one. An empty path list (nightly, manual run, unreadable PR file list) runs all.

Shards (accessibility.yml, job `ios`):
  library   Library empty, with Readest (online, offline, the local row)
  book      Library with one book, Book detail, Find Details Online, Settings > Book Details
  catalogs  Catalogs list, Add Catalog (two sizes), a catalog page, a catalog book
  signin    Sign-in needed, Sign In, Edit Catalog, catalog search
  rest      every other audit: welcome tour, Settings, Progress Sync, Acknowledgements, Reading

Usage: scripts/ci/pick_audit_shards.py < changed-paths.txt
       scripts/ci/pick_audit_shards.py --self-test
"""
import argparse
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from pick_platforms import BOTH, affected  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = "accessibility.yml"
ALL_SHARDS = ["library", "book", "catalogs", "signin", "rest"]
CATALOG_SHARDS = ["catalogs", "signin"]

# Paths of the iPhone app whose screens only some shards audit. The types these files declare were checked for
# use elsewhere (a view used by another screen adds that screen's shard). Not listed = every shard.
SHARDS_FOR_PATH = {
    # Catalogs, Add / Edit Catalog, the sign-in forms, catalog pages, books and search.
    "iOSApp/Views/CatalogsView.swift": CATALOG_SHARDS,
    "iOSApp/Views/CatalogFormViews.swift": CATALOG_SHARDS,
    "iOSApp/Library/CatalogStore.swift": CATALOG_SHARDS,
    # Find Details Online; its DetailCard / DetailRow are also used by Book detail and the catalog screens.
    "iOSApp/Views/OnlineMatchSheet.swift": ["book"] + CATALOG_SHARDS,
    # The online details model: Book detail, Find Details Online, Settings (whole, and Book Details alone).
    "iOSApp/Library/OnlineMetadata.swift": ["book", "rest"],
    # Settings, Acknowledgements (rest) and its Book Details section (book).
    "iOSApp/Views/SettingsView.swift": ["book", "rest"],
    # Reached from Settings and the welcome tour only.
    "iOSApp/Views/SyncSettingsView.swift": ["rest"],
    "iOSApp/Views/DictionariesView.swift": ["rest"],
    "iOSApp/Views/TintedLabel.swift": ["rest"],
    "iOSApp/Views/TypographySettingsView.swift": ["rest"],
    "iOSApp/Onboarding/OnboardingView.swift": ["rest"],
    # The sample book's badge on Library rows.
    "iOSApp/Views/SampleBadge.swift": ["library", "book"],
}
# Directories mapped the same way (prefix -> shards).
SHARDS_FOR_PREFIX = {
    "iOSApp/Resources/Acknowledgements/": ["rest"],
}
# Unit tests of the apps: no audit runs them.
NOT_AUDITED_PREFIXES = ("iOSApp/Tests/", "WatchApp/Tests/")


def ios_shards_for(path):
    for prefix, shards in SHARDS_FOR_PREFIX.items():
        if path.startswith(prefix):
            return set(shards)
    return set(SHARDS_FOR_PATH.get(path, ALL_SHARDS))


def pick(paths):
    """(platforms, ios_shards) for the changed paths."""
    paths = [p.strip() for p in paths if p.strip()]
    if not paths:
        return list(BOTH), list(ALL_SHARDS)
    platforms, shards = set(), set()
    for p in paths:
        if p.startswith(NOT_AUDITED_PREFIXES):
            continue
        hit = affected(p, WORKFLOW)
        platforms |= hit
        if "ios" in hit:
            shards |= ios_shards_for(p)
    ios_shards = [s for s in ALL_SHARDS if s in shards]
    if not ios_shards:
        platforms.discard("ios")
    return [p for p in BOTH if p in platforms], ios_shards


def workflow_shards():
    """The shard names of the `case` in accessibility.yml's audit step."""
    text = (ROOT / ".github/workflows" / WORKFLOW).read_text()
    block = re.search(r'case "\$\{\{ matrix\.shard \}\}" in\n(.*?)\n\s*esac', text, re.S)
    if not block:
        return None
    return re.findall(r"^\s*([a-z][a-z-]*)\)", block.group(1), re.M)


def self_test():
    a = ALL_SHARDS
    cases = [
        ([], BOTH, a),
        (["README.md", "docs/TESTING.md"], [], []),
        (["iOSApp/Views/CatalogsView.swift"], ["ios"], ["catalogs", "signin"]),
        (["iOSApp/Views/CatalogFormViews.swift", "iOSApp/Library/CatalogStore.swift"], ["ios"], ["catalogs", "signin"]),
        (["iOSApp/Views/OnlineMatchSheet.swift"], ["ios"], ["book", "catalogs", "signin"]),
        (["iOSApp/Views/SettingsView.swift"], ["ios"], ["book", "rest"]),
        (["iOSApp/Views/TypographySettingsView.swift"], ["ios"], ["rest"]),
        (["iOSApp/Resources/Acknowledgements/License-X.txt"], ["ios"], ["rest"]),
        (["iOSApp/Views/CatalogsView.swift", "iOSApp/Views/SyncSettingsView.swift"], ["ios"], ["catalogs", "signin", "rest"]),
        # Shared or unknown: every shard.
        (["iOSApp/Views/LibraryView.swift"], ["ios"], a),
        (["iOSApp/Views/BookDetailView.swift"], ["ios"], a),
        (["iOSApp/Views/CatalogsView.swift", "iOSApp/Support/UITestingSupport.swift"], ["ios"], a),
        (["iOSApp/Resources/Localizable.xcstrings"], ["ios"], a),
        (["iOSApp/Views/NewScreen.swift"], ["ios"], a),
        (["iOSApp/UITests/AccessibilityAuditTests.swift"], ["ios"], a),
        (["iOSApp/UITests/RowNavigation.swift"], ["ios"], a),
        (["iOSApp/UITests/CatalogsUITests.swift"], ["ios"], a),
        (["Packages/ReaderCore/Sources/ReaderCore/OPDS.swift"], BOTH, a),
        (["Shared/X.swift"], BOTH, a),
        (["project.yml"], BOTH, a),
        (["scripts/ci/pick_audit_shards.py"], BOTH, a),
        ([".github/workflows/accessibility.yml"], BOTH, a),
        (["some/unknown/file"], BOTH, a),
        # The watch audit.
        (["WatchApp/Reader/ReaderView.swift"], ["watch"], []),
        (["WatchWidgets/Widget.swift", "iOSApp/Views/SampleBadge.swift"], BOTH, ["library", "book"]),
        # Unit tests and other workflows: nothing.
        (["iOSApp/Tests/LogicTests.swift", "WatchApp/Tests/LogicTests.swift"], [], []),
        ([".github/workflows/macos.yml", "scripts/check_strings.py"], [], []),
        (["iOSApp/Tests/LogicTests.swift", "iOSApp/Views/DictionariesView.swift"], ["ios"], ["rest"]),
    ]
    failed = 0
    for paths, want_platforms, want_shards in cases:
        got = pick(paths)
        if got != (want_platforms, want_shards):
            print(f"FAIL {paths}: got {got}, want {(want_platforms, want_shards)}")
            failed += 1
    # The table only names files that exist (a renamed file falls back to every shard, but the entry would rot).
    for path in list(SHARDS_FOR_PATH) + list(SHARDS_FOR_PREFIX):
        if not (ROOT / path).exists():
            print(f"FAIL SHARDS_FOR_PATH names {path}, which does not exist")
            failed += 1
    for path, shards in list(SHARDS_FOR_PATH.items()) + list(SHARDS_FOR_PREFIX.items()):
        if not shards or set(shards) - set(ALL_SHARDS):
            print(f"FAIL {path}: unknown or no shards {shards}")
            failed += 1
    # The shards here are the shards the workflow knows.
    names = workflow_shards()
    if names != ALL_SHARDS:
        print(f"FAIL {WORKFLOW} shards {names} differ from ALL_SHARDS {ALL_SHARDS}")
        failed += 1
    total = len(cases) + 1
    print(f"{total - failed}/{total} pick_audit_shards cases pass (and the path table checks)")
    return 1 if failed else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    platforms, ios_shards = pick(sys.stdin)
    print("platforms=" + json.dumps(platforms))
    print("ios_shards=" + json.dumps(ios_shards))
