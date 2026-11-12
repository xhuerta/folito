#!/bin/bash
# Targeted run (workflow_dispatch input only_testing): builds one scheme and runs just the given tests on a
# simulator picked by boot_simulator.sh. See docs/TESTING.md ("Targeted runs").
# Usage: scripts/ci/run_only_testing.sh ios|watch "<Target[/Class[/test]]>[,<another>...]"
# Environment: XCB_FLAGS (shared build settings, as in macos.yml), ARCH (runner architecture).
set -euo pipefail
PLATFORM=$1
ONLY=$2
case "$PLATFORM" in
  ios)   SCHEME=Folito;      SDK="iOS Simulator" ;;
  watch) SCHEME=FolitoWatch; SDK="watchOS Simulator" ;;
  *) echo "::error::platform must be ios or watch, got '$PLATFORM'"; exit 2 ;;
esac
SELECTION=()
IFS=', ' read -r -a ITEMS <<< "$ONLY"
for t in "${ITEMS[@]}"; do
  [ -n "$t" ] || continue
  # xcodebuild identifiers only: Target/Class/test, optionally with "()".
  [[ "$t" =~ ^[A-Za-z0-9_]+(/[A-Za-z0-9_]+(/[A-Za-z0-9_]+(\(\))?)?)?$ ]] || { echo "::error::not a test identifier: '$t'"; exit 2; }
  SELECTION+=("-only-testing:$t")
done
[ ${#SELECTION[@]} -gt 0 ] || { echo "::error::only_testing is empty"; exit 2; }
echo "scheme $SCHEME: ${SELECTION[*]}"

nohup scripts/ci/boot_simulator.sh "$PLATFORM" "$RUNNER_TEMP/udid" > "$RUNNER_TEMP/boot.log" 2>&1 &
BOOT=$!
# shellcheck disable=SC2086
xcodebuild build-for-testing $XCB_FLAGS -scheme "$SCHEME" -destination "generic/platform=$SDK" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES > build.log 2>&1 || { grep -E "error:" build.log; tail -80 build.log; exit 1; }
wait "$BOOT" || { cat "$RUNNER_TEMP/boot.log"; exit 1; }
UDID=$(cat "$RUNNER_TEMP/udid")
set -o pipefail
# shellcheck disable=SC2086
xcodebuild test-without-building $XCB_FLAGS -scheme "$SCHEME" -destination "id=$UDID" "${SELECTION[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 300 \
  -resultBundlePath targeted.xcresult 2>&1 | tee targeted.log
