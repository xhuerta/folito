#!/bin/bash
# Captures the App Store screenshots of one display class into app-store-screenshots/<class>/.
#
# Picks (or creates) a simulator whose screen is a size App Store Connect accepts for the class
# (scripts/ci/appstore_simulator.py), boots it, overrides its status bar (iPhone: 9:41, Wi-Fi, full battery, no
# carrier name), runs the given screenshot suite on it and exports the attachments, named after their
# attachment names (iphone-1-library.png, watch-1-reader.png, ...). The app must already be built for testing.
# Environment (set by macos.yml): XCB_FLAGS, SCHEME; UDID is the job's main simulator, which is left booted.
#
# Usage: scripts/ci/appstore_screenshots.sh iphone-medium|iphone-large|watch <Target/TestClass>
set -euo pipefail
CLASS=$1
TEST=$2
OUT=app-store-screenshots/$CLASS

U=$(python3 scripts/ci/appstore_simulator.py "$CLASS")
xcrun simctl bootstatus "$U" -b > /dev/null
case "$CLASS" in
  iphone-*)
    xcrun simctl status_bar "$U" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 --operatorName ""
    ;;
  watch)
    # The watch shows only the clock. Xcode 26.3 refuses the override on watchOS ("Status bar overrides not
    # supported on this platform"): the capture then shows the runner's clock (docs/appstore/SCREENSHOTS.md).
    xcrun simctl status_bar "$U" override --time 10:09 2>/dev/null \
      || echo "::notice::simctl status_bar does not support watchOS simulators; the watch screenshots show the runner's clock"
    ;;
esac

status=0
rm -rf "appstore-$CLASS.xcresult" "$OUT"
# shellcheck disable=SC2086
xcodebuild test-without-building $XCB_FLAGS \
  -scheme "$SCHEME" \
  -destination "id=$U" \
  -only-testing:"$TEST" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
  -resultBundlePath "appstore-$CLASS.xcresult" > "appstore-$CLASS.log" 2>&1 || status=1
grep -E "Test Case .*(passed|failed)|Executed [0-9]+ tests|error:" "appstore-$CLASS.log" || true
# A failed run: the failure with its context (the tests print the accessibility tree).
[ $status -eq 0 ] || { grep -n -A80 "error:" "appstore-$CLASS.log" | head -400; tail -40 "appstore-$CLASS.log"; }

mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "appstore-$CLASS.xcresult" --output-path "$OUT" || status=1
python3 scripts/ci/name_attachments.py "$OUT" || status=1
# Only the named captures: no manifest, no automatic failure screenshots.
find "$OUT" -type f ! -name "${CLASS%%-*}-*.png" -delete
ls -l "$OUT"

if [ "$U" = "${UDID:-}" ]; then
  xcrun simctl status_bar "$U" clear || true
else
  xcrun simctl shutdown "$U" || true
fi
exit $status
