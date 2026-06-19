#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ALFRED_RELEASE_ZIP=dist/Alfred-1.0.0.zip ./scripts/notarize_release.sh [--dry-run]

Submits a ZIP containing Alfred.app to Apple notarization, staples the returned
ticket to the app, validates stapling, and writes a stapled ZIP next to the input.

Authentication options:
  NOTARYTOOL_PROFILE         Preferred. Name of a keychain profile created with:
                              xcrun notarytool store-credentials PROFILE
  APPLE_ID                   Apple ID email. Used with APP_PASSWORD and TEAM_ID.
  APP_PASSWORD               App-specific password or keychain item.
  TEAM_ID                    Apple Developer Team ID.

Environment:
  ALFRED_RELEASE_ZIP         Required path to a ZIP created by package_release.sh.

Options:
  --dry-run                  Print planned commands without notarizing/stapling.
  -h, --help                 Show this help.
USAGE
}

step() { echo; echo "▶ $*"; }
ok() { echo "  ✓ $*"; }
die() { echo "✗ ERROR: $*" >&2; exit 1; }
quote() { printf '%q' "$1"; }
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  DRY RUN:'
    for arg in "$@"; do printf ' %s' "$(quote "$arg")"; done
    printf '\n'
  else
    "$@"
  fi
}

DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

: "${ALFRED_RELEASE_ZIP:?ALFRED_RELEASE_ZIP env var is required}"

if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
  : "${APPLE_ID:?APPLE_ID is required when NOTARYTOOL_PROFILE is not set}"
  : "${APP_PASSWORD:?APP_PASSWORD is required when NOTARYTOOL_PROFILE is not set}"
  : "${TEAM_ID:?TEAM_ID is required when NOTARYTOOL_PROFILE is not set}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ZIP_PATH="$ALFRED_RELEASE_ZIP"
if [[ "$DRY_RUN" == true ]]; then
  ZIP_DIR="$(cd "$(dirname "$ZIP_PATH")" 2>/dev/null && pwd || printf '%s' "$(dirname "$ZIP_PATH")")"
else
  ZIP_DIR="$(cd "$(dirname "$ZIP_PATH")" && pwd)"
fi
ZIP_BASE="$(basename "$ZIP_PATH" .zip)"
STAPLED_ZIP="$ZIP_DIR/$ZIP_BASE-stapled.zip"
WORK_DIR="${TMPDIR:-/tmp}/alfred-notarize-$ZIP_BASE"
APP_BUNDLE="$WORK_DIR/Alfred.app"

[[ "$DRY_RUN" == true || -f "$ZIP_PATH" ]] || die "ZIP not found: $ZIP_PATH"

NOTARY_ARGS=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
else
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID")
fi

step "Submitting ZIP for notarization"
run xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" --wait

step "Extracting app for stapling"
run rm -rf "$WORK_DIR"
run mkdir -p "$WORK_DIR"
run ditto -x -k "$ZIP_PATH" "$WORK_DIR"

step "Stapling notarization ticket"
run xcrun stapler staple "$APP_BUNDLE"
run xcrun stapler validate "$APP_BUNDLE"

step "Assessing Gatekeeper status"
run spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

step "Creating stapled ZIP"
run rm -f "$STAPLED_ZIP"
run ditto -c -k --keepParent "$APP_BUNDLE" "$STAPLED_ZIP"

if [[ "$DRY_RUN" == false ]]; then
  ok "Created $STAPLED_ZIP"
fi
