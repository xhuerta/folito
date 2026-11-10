#!/usr/bin/env python3
"""Decides which macOS jobs (ios, watch) a pull request needs, from the paths it changes.

Reads the changed paths on stdin, one per line, and prints `platforms=<JSON list>` for $GITHUB_OUTPUT.

The watch scheme compiles nothing under iOSApp/, so a PR that only touches iOSApp/ skips the watch job. The iOS
scheme does embed the watch app, but the watch job builds the very same targets, so a PR that only touches
WatchApp/ or WatchWidgets/ skips the iOS job. Anything else (Packages/ReaderCore, Shared, WidgetShared,
project.yml, Config, scripts, workflows, ...) and an empty list run both: when in doubt, run both.

Usage: scripts/ci/pick_platforms.py < changed-paths.txt
"""
import json
import sys

IOS_ONLY = ("iOSApp/",)
WATCH_ONLY = ("WatchApp/", "WatchWidgets/")


def platforms(paths):
    paths = [p.strip() for p in paths if p.strip()]
    if paths and all(p.startswith(IOS_ONLY) for p in paths):
        return ["ios"]
    if paths and all(p.startswith(WATCH_ONLY) for p in paths):
        return ["watch"]
    return ["ios", "watch"]


if __name__ == "__main__":
    print("platforms=" + json.dumps(platforms(sys.stdin)))
