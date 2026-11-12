#!/bin/bash
# Captures the App Store screenshots of one display class in one language into app-store-screenshots/<lang>/<class>/.
#
# Picks (or creates) a simulator whose screen is a size App Store Connect accepts for the class
# (scripts/ci/appstore_simulator.py), boots it, overrides its status bar (iPhone: 9:41, Wi-Fi, full battery, no
# carrier name), runs the given screenshot suite on it and exports the attachments, named after their
# attachment names (iphone-1-library.png, watch-1-reader.png, ...). The app must already be built for testing.
#
# The xcodebuild progress (suite and test start/end, launches, taps, errors) is printed while it runs, with the
# seconds since the attempt started, so that a slow or stuck run shows where it is. An attempt that runs longer
# than ATTEMPT_MINUTES is a hang (the suite itself takes 1 to 2 minutes; a stuck test is stopped earlier by the
# test execution time allowance): the simulator screen is saved (appstore-<class>-hang-<n>.png), xcodebuild is
# stopped, the simulator is rebooted and the suite runs once more. A test failure is not retried.
# On failure, appstore-<class>.log, appstore-<class>.xcresult and the hang screenshots are left for the
# workflow to upload.
# Environment (set by macos.yml / app-store-localized.yml): XCB_FLAGS, SCHEME or XCTESTRUN (a .xctestrun file); UDID is the job's main simulator,
# which is left booted; ATTEMPT_MINUTES (default 12); SCREENSHOT_LANG (default en: en, es, fr, de, it, pt-BR, ja,
# zh-Hans), passed to the suite as TEST_RUNNER_SCREENSHOT_LANG (xcodebuild hands TEST_RUNNER_* variables to the
# test runner without the prefix): the suite launches the app in that language with its AppStoreSeeds/<lang>.json.
#
# Usage: scripts/ci/appstore_screenshots.sh iphone-medium|iphone-large|watch <Target/TestClass>
set -euo pipefail
CLASS=$1
TEST=$2
SHOT_LANG=${SCREENSHOT_LANG:-en}
case "$SHOT_LANG" in
  en|es|fr|de|it|pt-BR|ja|zh-Hans) ;;
  *) echo "::error::unknown SCREENSHOT_LANG '$SHOT_LANG'"; exit 2 ;;
esac
export TEST_RUNNER_SCREENSHOT_LANG=$SHOT_LANG
OUT=app-store-screenshots/$SHOT_LANG/$CLASS
LOG=appstore-$CLASS.log
LIMIT=$(( ${ATTEMPT_MINUTES:-12} * 60 ))
# Lines of the xcodebuild log shown live.
PROGRESS='Testing started|Test Suite .* (started|passed|failed)|Test Case .* (started|passed|failed)|error:|\*\* TEST|t = .*(Launch|Tap|Tear Down)|Restarting after|[Tt]imed out|Failed to'

U=$(python3 scripts/ci/appstore_simulator.py "$CLASS")

prepare_simulator() {
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
}

# Prints the new progress lines of the log, from line SHOWN+1 on.
SHOWN=0
show_progress() {
  local total
  total=$(wc -l < "$LOG" | tr -d ' ')
  [ "$total" -gt "$SHOWN" ] || return 0
  sed -n "$((SHOWN + 1)),${total}p" "$LOG" | grep -E "$PROGRESS" | sed "s/^/[+$(( SECONDS - START ))s] /" || true
  SHOWN=$total
}

# One run of the suite. Returns xcodebuild's status, or 124 when the attempt was stopped as a hang.
run_suite() {
  local attempt=$1 pid rc=0
  rm -rf "appstore-$CLASS.xcresult"
  SHOWN=0
  START=$SECONDS
  # shellcheck disable=SC2086
  # With XCTESTRUN (app-store-localized.yml: products built once by another job) the .xctestrun file names the
  # test bundles; otherwise the scheme of the project built in this job.
  local target=(-scheme "$SCHEME")
  [ -n "${XCTESTRUN:-}" ] && target=(-xctestrun "$XCTESTRUN")
  xcodebuild test-without-building $XCB_FLAGS \
    "${target[@]}" \
    -destination "id=$U" \
    -only-testing:"$TEST" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
    -resultBundlePath "appstore-$CLASS.xcresult" > "$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    show_progress
    kill -0 "$pid" 2>/dev/null || break
    if [ $(( SECONDS - START )) -gt "$LIMIT" ]; then
      echo "::warning::$CLASS ($SHOT_LANG): xcodebuild still running after $(( LIMIT / 60 )) min (attempt $attempt); last log lines:"
      tail -15 "$LOG" || true
      xcrun simctl io "$U" screenshot "appstore-$CLASS-hang-$attempt.png" > /dev/null 2>&1 || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 10
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
  done
  wait "$pid" || rc=$?
  show_progress
  return $rc
}

prepare_simulator
status=0
rm -rf "$OUT" appstore-"$CLASS"-hang-*.png
rc=0
run_suite 1 || rc=$?
if [ $rc -eq 124 ]; then
  echo "Rebooting the $CLASS simulator and running the suite again"
  xcrun simctl shutdown "$U" || true
  xcrun simctl boot "$U" || true
  prepare_simulator
  rc=0
  run_suite 2 || rc=$?
fi
if [ $rc -ne 0 ]; then
  status=1
  [ $rc -eq 124 ] && echo "::error::$CLASS: xcodebuild hung twice (over $(( LIMIT / 60 )) min each); see appstore-$CLASS-hang-*.png"
  # The failure with its context (the tests print the accessibility tree and attach a screenshot).
  grep -n -A80 "error:" "$LOG" | head -400 || true
  tail -40 "$LOG"
fi
grep -E "Executed [0-9]+ tests" "$LOG" | tail -1 || true

mkdir -p "$OUT"
if [ -d "appstore-$CLASS.xcresult" ]; then
  xcrun xcresulttool export attachments --path "appstore-$CLASS.xcresult" --output-path "$OUT" > /dev/null || status=1
  python3 scripts/ci/name_attachments.py "$OUT" || status=1
else
  status=1
fi
# Only the named captures: no manifest, no failure screenshots (those stay in the result bundle).
find "$OUT" -type f ! -name "${CLASS%%-*}-*.png" -delete
ls -l "$OUT"

if [ "$U" = "${UDID:-}" ]; then
  xcrun simctl status_bar "$U" clear || true
else
  xcrun simctl shutdown "$U" || true
fi
exit $status
