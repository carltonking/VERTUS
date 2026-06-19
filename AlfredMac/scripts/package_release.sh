#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: VERSION=1.0.0 [BUILD_NUMBER=100] [DEVELOPER_ID_APPLICATION='Developer ID Application: Name (TEAMID)'] ./scripts/package_release.sh [--dry-run] [--skip-sign]

Builds Alfred.app with scripts/build_app.sh, optionally signs it with Developer ID
and hardened runtime, verifies the app, and creates a ZIP release artifact.

Environment:
  VERSION                    Required release version, e.g. 1.0.0
  BUILD_NUMBER               Optional build number. Defaults to VERSION.
  BUNDLE_ID                  Optional bundle id. Defaults to com.alfred.app.
  SU_FEED_URL                Optional Sparkle appcast URL. Omitted from Info.plist when unset.
  SPARKLE_PUBLIC_KEY         Optional Sparkle EdDSA public key.
  DEVELOPER_ID_APPLICATION   Required unless --skip-sign or --dry-run.

Options:
  --dry-run                  Print planned commands without building/signing/zipping.
  --skip-sign                Create an unsigned/ad-hoc-signed ZIP for internal testing only.
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
SKIP_SIGN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-sign)
      SKIP_SIGN=true
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

: "${VERSION:?VERSION env var is required, e.g. VERSION=1.0.0}"

if [[ "$SKIP_SIGN" == false && "$DRY_RUN" == false ]]; then
  : "${DEVELOPER_ID_APPLICATION:?DEVELOPER_ID_APPLICATION is required unless --skip-sign or --dry-run}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="Alfred"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

step "Preparing release package"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

if [[ "$DRY_RUN" == true ]]; then
  echo "  VERSION=$VERSION"
  echo "  BUILD_NUMBER=${BUILD_NUMBER:-$VERSION}"
  echo "  BUNDLE_ID=${BUNDLE_ID:-com.alfred.app}"
  echo "  SU_FEED_URL=${SU_FEED_URL:-<not set>}"
  if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    echo "  SPARKLE_PUBLIC_KEY=<set>"
  else
    echo "  SPARKLE_PUBLIC_KEY=<not set>"
  fi
  echo "  APP_BUNDLE=$APP_BUNDLE"
  echo "  ZIP_PATH=$ZIP_PATH"
  echo "  DEVELOPER_ID_APPLICATION=${DEVELOPER_ID_APPLICATION:-<required for signed release>}"
fi

step "Building app bundle"
run "$SCRIPT_DIR/build_app.sh" --clean

if [[ "$SKIP_SIGN" == false ]]; then
  step "Signing app with Developer ID Application"
  SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Example (TEAMID)}"
  run codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  run codesign --verify --deep --strict "$APP_BUNDLE"
  ok "Developer ID signature verified"
else
  step "Skipping Developer ID signing"
  echo "  This artifact is for internal testing only."
fi

step "Creating ZIP artifact"
run ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ "$DRY_RUN" == false ]]; then
  [[ -f "$ZIP_PATH" ]] || die "ZIP was not created at $ZIP_PATH"
  ok "Created $ZIP_PATH"
  echo
  echo "Next:"
  echo "  ALFRED_RELEASE_ZIP=\"$ZIP_PATH\" ./scripts/notarize_release.sh"
fi
