#!/usr/bin/env bash
# Resolves release parameters and (for real runs) verifies required secrets/variables.
# Reads configuration from the environment, writes results to $GITHUB_ENV and $GITHUB_STEP_SUMMARY.
# Never prints secret values.
set -euo pipefail

: "${GITHUB_ENV:=/dev/null}"
: "${GITHUB_STEP_SUMMARY:=/dev/null}"

# ---- mode -------------------------------------------------------------------------------------
# Real (signed, uploading) runs only for a pushed tag or a manual dispatch with dry_run=false.
# Everything else (manual default, pull_request) is a dry run that needs no secrets.
dry=true
if [ "${EVENT_NAME:-}" = "push" ] && [ "${REF_TYPE:-}" = "tag" ]; then dry=false; fi
if [ "${EVENT_NAME:-}" = "workflow_dispatch" ] && [ "${DRY_RUN_INPUT:-true}" = "false" ]; then dry=false; fi
lane="${LANE_INPUT:-testflight}"
case "$lane" in testflight|appstore-metadata-none) ;; *) echo "::error::Unknown lane '$lane'"; exit 1;; esac

# ---- version ----------------------------------------------------------------------------------
version="${VERSION_INPUT:-}"
if [ -z "$version" ] && [ "${REF_TYPE:-}" = "tag" ]; then version="${REF_NAME#v}"; fi
# Default: the project's own version, Config/Base.xcconfig (`MARKETING_VERSION = 1.2.3`).
if [ -z "$version" ] && [ -f Config/Base.xcconfig ]; then
  version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\([^[:space:]/]*\).*$/\1/p' Config/Base.xcconfig | head -1)
fi
if ! printf '%s' "$version" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
  echo "::error::MARKETING_VERSION '$version' is not 1-3 dot-separated integers (e.g. 1.0 or 1.0.0). Use a tag like v1.0.0 or the marketing_version input."
  exit 1
fi
build="${RUN_NUMBER:?RUN_NUMBER missing}"

# ---- bundle id / name -------------------------------------------------------------------------
bundle="${BUNDLE_ID_BASE:-}"
app_name="${APP_NAME:-}"

missing=()
problems=()
if [ "$dry" = "false" ]; then
  [ -n "${ASC_KEY_ID:-}" ]     || missing+=("secret ASC_KEY_ID")
  [ -n "${ASC_ISSUER_ID:-}" ]  || missing+=("secret ASC_ISSUER_ID")
  [ -n "${ASC_KEY_P8:-}" ]     || missing+=("secret ASC_KEY_P8")
  [ -n "${APPLE_TEAM_ID:-}" ]  || missing+=("secret APPLE_TEAM_ID")
  [ -n "$bundle" ]             || missing+=("repository variable BUNDLE_ID_BASE")
  if [ -n "${APPLE_TEAM_ID:-}" ] && ! printf '%s' "$APPLE_TEAM_ID" | grep -Eq '^[A-Z0-9]{10}$'; then
    problems+=("APPLE_TEAM_ID must be the 10-character Team ID (letters/digits)")
  fi
  if [ -n "$bundle" ]; then
    printf '%s' "$bundle" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' || problems+=("BUNDLE_ID_BASE is not a valid reverse-DNS identifier")
    case "$bundle" in com.example.*|*.watchkitapp) problems+=("BUNDLE_ID_BASE must be your own identifier (not com.example.* and without the .watchkitapp suffix)");; esac
  fi
else
  [ -n "$bundle" ] || bundle="com.example.wristreader"
fi

if [ "${#missing[@]}" -gt 0 ] || [ "${#problems[@]}" -gt 0 ]; then
  {
    echo "::error title=Release configuration incomplete::Cannot run a real release."
    if [ "${#missing[@]}" -gt 0 ]; then
      echo "Missing:"; printf '  - %s\n' "${missing[@]}"
    fi
    if [ "${#problems[@]}" -gt 0 ]; then
      echo "Invalid:"; printf '  - %s\n' "${problems[@]}"
    fi
    echo "See docs/RELEASE.md. Tip: run this workflow with dry_run=true to test without secrets."
  } >&2
  {
    echo "### Release blocked: configuration incomplete"
    [ "${#missing[@]}" -gt 0 ] && { echo "Missing:"; printf -- '- %s\n' "${missing[@]}"; }
    [ "${#problems[@]}" -gt 0 ] && { echo "Invalid:"; printf -- '- %s\n' "${problems[@]}"; }
    echo; echo "See docs/RELEASE.md."
  } >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi

{
  echo "WR_DRY_RUN=$dry"
  echo "WR_LANE=$lane"
  echo "WR_VERSION=$version"
  echo "WR_BUILD=$build"
  echo "WR_BUNDLE_ID=$bundle"
  echo "WR_APP_NAME=$app_name"
} >> "$GITHUB_ENV"

echo "dry_run=$dry lane=$lane version=$version build=$build bundle=$bundle app_name=${app_name:-<default>}"
