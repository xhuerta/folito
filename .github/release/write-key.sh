#!/usr/bin/env bash
# Writes the App Store Connect API key (ASC_KEY_P8: raw PEM or base64 of the PEM) to a 600-permission
# temp file and exports its path as ASC_KEY_PATH. Never prints key material.
set -euo pipefail
: "${GITHUB_ENV:=/dev/null}"
: "${ASC_KEY_P8:?ASC_KEY_P8 missing}"
: "${ASC_KEY_ID:?ASC_KEY_ID missing}"
dir="${RUNNER_TEMP:-$(mktemp -d)}/asc-key"
umask 077
mkdir -p "$dir"
chmod 700 "$dir"
path="$dir/AuthKey_${ASC_KEY_ID}.p8"
if printf '%s' "$ASC_KEY_P8" | grep -q 'BEGIN PRIVATE KEY'; then
  printf '%s\n' "$ASC_KEY_P8" > "$path"
else
  # openssl (not base64 -d/-D) behaves the same on macOS and Linux.
  if ! printf '%s' "$ASC_KEY_P8" | tr -d ' \r\n' | openssl base64 -d -A > "$path" 2>/dev/null; then
    rm -f "$path"; echo "::error::ASC_KEY_P8 is not valid base64"; exit 1
  fi
fi
chmod 600 "$path"
if ! grep -q 'BEGIN PRIVATE KEY' "$path"; then
  rm -f "$path"
  echo "::error::ASC_KEY_P8 is neither a raw .p8 PEM nor the base64 of one (expected '-----BEGIN PRIVATE KEY-----')."
  exit 1
fi
# Defence in depth: mask every line of the key in later log output.
grep -v -e '-----' "$path" | while IFS= read -r line; do [ -n "$line" ] && echo "::add-mask::$line"; done
echo "ASC_KEY_PATH=$path" >> "$GITHUB_ENV"
echo "API key written to a temporary file (mode 600)."
