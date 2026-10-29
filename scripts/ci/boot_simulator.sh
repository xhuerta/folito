#!/bin/bash
# Picks (or creates) a simulator for the given platform, writes its UDID to $2 and boots it.
# CI starts this in the background right after checkout so the simulator boots while the app compiles.
# Usage: scripts/ci/boot_simulator.sh ios|watch <udid-file>
set -euo pipefail
PLATFORM=$1
OUT=$2
case "$PLATFORM" in
  ios)   RT_PREFIX=iOS;     NAME_PREFIX=iPhone;        DT_MATCH=iPhone ;;
  watch) RT_PREFIX=watchOS; NAME_PREFIX="Apple Watch"; DT_MATCH=Apple-Watch ;;
  *) echo "unknown platform $PLATFORM" >&2; exit 2 ;;
esac

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if k.split('.')[-1].startswith('$RT_PREFIX') for x in v if x['name'].startswith('$NAME_PREFIX')]
print(c[-1]['udid'] if c else '')")
if [ -z "$UDID" ]; then
  RT=$(xcrun simctl list runtimes available -j | python3 -c "
import json,sys
r=[x['identifier'] for x in json.load(sys.stdin)['runtimes'] if x['identifier'].split('.')[-1].startswith('$RT_PREFIX')]
print(r[-1] if r else '')")
  DT=$(xcrun simctl list devicetypes -j | python3 -c "
import json,sys
t=[x['identifier'] for x in json.load(sys.stdin)['devicetypes'] if '$DT_MATCH' in x['identifier']]
print(t[-1] if t else '')")
  echo "creating $PLATFORM simulator: $DT / $RT"
  UDID=$(xcrun simctl create "CI $PLATFORM" "$DT" "$RT")
fi
[ -n "$UDID" ] || { xcrun simctl list devices available; exit 1; }
echo "$PLATFORM simulator: $UDID"
echo "$UDID" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
# -b boots the device if needed and waits until it has finished booting.
xcrun simctl bootstatus "$UDID" -b
echo "booted"
