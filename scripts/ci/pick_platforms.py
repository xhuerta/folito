#!/usr/bin/env python3
"""Decides which macOS platforms (ios, watch) a pull request needs, from the paths it changes.

Reads the changed paths on stdin, one per line, and prints two lines for $GITHUB_OUTPUT:
  platforms=<JSON list>   the platforms whose macOS jobs must run;
  skipped=<JSON list>     the others, whose checks a cheap Linux job reports as passed (same check names).

Each path maps to the platforms it can affect:
  * iOSApp/                                   -> ios
  * WatchApp/, WatchWidgets/                  -> watch (the iOS scheme embeds the watch app, but the watch job
                                                 builds the very same targets)
  * docs/, *.md, Linux-only or release-only tooling, and the workflows other than the one asking -> nothing
  * anything else (Packages/, Shared/, WidgetShared/, project.yml, Config/, scripts/ci/, the asking workflow,
    unknown paths)                            -> both: when in doubt, run both.
An empty path list (push to main, manual run, unreadable PR file list) runs both.

Usage: scripts/ci/pick_platforms.py [--workflow macos.yml] < changed-paths.txt
       scripts/ci/pick_platforms.py --self-test
"""
import argparse
import json
import sys

BOTH = ["ios", "watch"]
IOS_ONLY = ("iOSApp/",)
WATCH_ONLY = ("WatchApp/", "WatchWidgets/")
# Paths no macOS build or test reads. Kept in step with the paths-ignore of macos.yml's push trigger.
IRRELEVANT_PREFIXES = (
    "docs/",
    "signatures/",
    "scripts/kosync-server/",
    "scripts/site/",
    "scripts/partial_md5_",
)
IRRELEVANT_FILES = (
    "scripts/check_real_books.sh",
    "scripts/make_icons.py",
    "scripts/check_strings.py",
    "scripts/validate_release.py",
    ".github/dependabot.yml",
)
# Workflows that build or test on macOS simulators; a change to one runs only that workflow's jobs.
SIMULATOR_WORKFLOWS = ("macos.yml", "accessibility.yml")


# Workflows that never run the simulator jobs (Linux, CLA, release archive / TestFlight).
OTHER_WORKFLOWS = ("linux.yml", "cla.yml", "release.yml", "release-check.yml")


def affected(path, workflow):
    if path.endswith(".md"):
        return set()
    if path.startswith(IOS_ONLY):
        return {"ios"}
    if path.startswith(WATCH_ONLY):
        return {"watch"}
    if path.startswith(".github/workflows/"):
        name = path.rsplit("/", 1)[-1]
        return set(BOTH) if name == workflow or name not in SIMULATOR_WORKFLOWS + OTHER_WORKFLOWS else set()
    if path.startswith(IRRELEVANT_PREFIXES) or path in IRRELEVANT_FILES:
        return set()
    return set(BOTH)


def platforms(paths, workflow="macos.yml"):
    paths = [p.strip() for p in paths if p.strip()]
    if not paths:
        return list(BOTH)
    needed = set()
    for p in paths:
        needed |= affected(p, workflow)
    return [p for p in BOTH if p in needed]


def self_test():
    cases = [
        ([], "macos.yml", BOTH),
        (["iOSApp/Views/A.swift"], "macos.yml", ["ios"]),
        (["WatchApp/A.swift", "WatchWidgets/B.swift"], "macos.yml", ["watch"]),
        (["iOSApp/A.swift", "WatchApp/B.swift"], "macos.yml", BOTH),
        (["Packages/ReaderCore/Sources/X.swift"], "macos.yml", BOTH),
        (["project.yml"], "accessibility.yml", BOTH),
        (["Shared/X.swift", "iOSApp/A.swift"], "macos.yml", BOTH),
        (["scripts/ci/boot_simulator.sh"], "macos.yml", BOTH),
        (["docs/TESTING.md", "README.md"], "macos.yml", []),
        (["iOSApp/README.md", "docs/x.png"], "macos.yml", []),
        ([".github/workflows/linux.yml"], "macos.yml", []),
        ([".github/workflows/accessibility.yml"], "macos.yml", []),
        ([".github/workflows/accessibility.yml"], "accessibility.yml", BOTH),
        ([".github/workflows/macos.yml"], "macos.yml", BOTH),
        ([".github/workflows/new.yml"], "macos.yml", BOTH),
        (["scripts/kosync-server/docker-compose.yml", "scripts/check_strings.py"], "macos.yml", []),
        (["docs/TESTING.md", "WatchApp/A.swift"], "macos.yml", ["watch"]),
        (["Config/Base.xcconfig"], "macos.yml", BOTH),
        (["some/unknown/file"], "macos.yml", BOTH),
    ]
    failed = 0
    for paths, workflow, want in cases:
        got = platforms(paths, workflow)
        if got != want:
            print(f"FAIL {paths} ({workflow}): got {got}, want {want}")
            failed += 1
    print(f"{len(cases) - failed}/{len(cases)} pick_platforms cases pass")
    return 1 if failed else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--workflow", default="macos.yml", help="file name of the workflow asking")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    need = platforms(sys.stdin, args.workflow)
    print("platforms=" + json.dumps(need))
    print("skipped=" + json.dumps([p for p in BOTH if p not in need]))
