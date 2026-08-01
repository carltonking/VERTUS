#!/usr/bin/env bash
set -euo pipefail

# Build a local Alfred.app bundle that macOS Privacy settings can authorize.
# This is for development/local use. Release packaging lives in package_release.sh.

usage() {
  cat <<USAGE
Usage: ./scripts/build_app.sh [--install] [--clean]

Options:
  --install   Copy Alfred.app to /Applications after building.
  --clean     Remove the local build directory before building.
  -h, --help  Show this help.
USAGE
}

step() { echo; echo "▶ $*"; }
ok() { echo "  ✓ $*"; }
die() { echo "✗ ERROR: $*" >&2; exit 1; }

INSTALL=false
CLEAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL=true
      shift
      ;;
    --clean)
      CLEAN=true
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_ROOT="$REPO_ROOT/build"
SCRATCH_PATH="$BUILD_ROOT/swiftpm"

APP_NAME="Alfred"
BUNDLE_ID="${BUNDLE_ID:-com.alfred.app}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
SU_FEED_URL="${SU_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
APP_ICON_SOURCE="$REPO_ROOT/Alfred/Resources/AppIcon.icns"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

if [[ "$CLEAN" == true ]]; then
  step "Cleaning local app build output"
  rm -rf "$BUILD_ROOT"
  ok "Removed $BUILD_ROOT"
fi

mkdir -p "$BUILD_ROOT"

SPARKLE_PUBLIC_KEY_PLIST=""
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_PUBLIC_KEY_PLIST="  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_KEY}</string>"
fi
SPARKLE_FEED_PLIST=""
if [[ -n "$SU_FEED_URL" ]]; then
  SPARKLE_FEED_PLIST="  <key>SUFeedURL</key>
  <string>${SU_FEED_URL}</string>"
fi
APP_ICON_PLIST=""
if [[ -f "$APP_ICON_SOURCE" ]]; then
  APP_ICON_PLIST="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>"
fi

step "Building Swift package"
# Capture the bin path first (a graph query), then do the actual compile — avoids re-entering
# SwiftPM a second time purely to read the path after the build. The real build still runs below and
# the existence check that follows still validates the produced binary.
BIN_DIR="$(swift build -c release --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH" --show-bin-path)"
swift build -c release --package-path "$REPO_ROOT" --scratch-path "$SCRATCH_PATH"
BINARY_PATH="$BIN_DIR/$APP_NAME"

[[ -f "$BINARY_PATH" ]] || die "Binary not found at $BINARY_PATH"
ok "Built $BINARY_PATH"

step "Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# alfred-mcp: the MCP shim Hermes spawns to reach Alfred's macOS tools. It must
# ship inside the bundle so it inherits the same signature, and so HermesSession
# can locate it relative to the main executable.
if [[ -f "$BIN_DIR/alfred-mcp" ]]; then
  cp "$BIN_DIR/alfred-mcp" "$APP_BUNDLE/Contents/MacOS/alfred-mcp"
  chmod +x "$APP_BUNDLE/Contents/MacOS/alfred-mcp"
else
  echo "  ! alfred-mcp not found in $BIN_DIR — Hermes will have no macOS tools"
fi

if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  cp -R "$BIN_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
fi

find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

if [[ -f "$APP_ICON_SOURCE" ]]; then
  cp "$APP_ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
${APP_ICON_PLIST}
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Alfred uses AppleEvents to control apps when you ask it to.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Alfred needs Accessibility access for app context, app interaction, and typing into apps.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Alfred reads your screen when you ask about visible screen context.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Alfred records meetings you start so it can transcribe them on-device.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Alfred transcribes recorded meetings on-device using the Speech framework.</string>
  <key>NSContactsUsageDescription</key>
  <string>Alfred looks up contacts to text the person you name.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Alfred reads and creates calendar events when you ask.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Alfred reads and creates calendar events when you ask.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Alfred reads and creates reminders when you ask.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Alfred reads and creates reminders when you ask.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Alfred uses your location to estimate travel time to calendar events and remind you when to leave.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_ID}</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>alfred</string>
      </array>
    </dict>
  </array>
${SPARKLE_FEED_PLIST}
${SPARKLE_PUBLIC_KEY_PLIST}
</dict>
</plist>
PLIST

if command -v install_name_tool >/dev/null 2>&1; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

ok "Created $APP_BUNDLE"

step "Signing $APP_NAME.app for local development"
# Prefer a STABLE self-signed identity so macOS permission grants (Accessibility, Automation,
# Microphone, …) persist across rebuilds. Ad-hoc signatures change every build and force macOS
# to re-prompt for everything. Create the identity once with scripts/create_signing_cert.sh.
SIGN_IDENTITY="${SIGN_IDENTITY:-Alfred Local Signing}"
# NOTE: no `-v` — a self-signed local identity is untrusted (so not "valid" for Gatekeeper), but
# codesign signs with it fine and TCC permissions key on its stable cert, which is what we want.
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  ok "Signed with stable identity '$SIGN_IDENTITY' (permissions persist across rebuilds)"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
  ok "Ad-hoc signature verified"
  echo "  ⚠ No stable signing identity found — macOS will RE-PROMPT for permissions on every"
  echo "    rebuild. Fix it once: ./scripts/create_signing_cert.sh && ./scripts/build_app.sh --install"
fi

if [[ "$INSTALL" == true ]]; then
  step "Installing to $INSTALL_PATH"
  rm -rf "$INSTALL_PATH"
  cp -R "$APP_BUNDLE" "$INSTALL_PATH"
  ok "Installed $INSTALL_PATH"
  # Remove the staging copy so it doesn't linger in ~/…/build and show up in Spotlight as a
  # duplicate "Alfred (build)". The real, launchable app now lives only in /Applications.
  rm -rf "$APP_BUNDLE"
  ok "Removed staging bundle (installed copy is the only Alfred.app)"
fi

echo
if [[ "$INSTALL" == true ]]; then
  echo "Installed app (the only Alfred.app):"
  echo "  $INSTALL_PATH"
  echo
  echo "Launch with:"
  echo "  open \"$INSTALL_PATH\""
else
  echo "Alfred app bundle is ready:"
  echo "  $APP_BUNDLE"
  echo
  echo "Launch with:"
  echo "  open \"$APP_BUNDLE\""
fi
