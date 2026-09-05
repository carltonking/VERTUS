#!/bin/bash
# Assemble VertusFleet.app from a `swift build` product so the app gets a
# real bundle (Info.plist + bundle id) — required for UNUserNotificationCenter
# local notifications and `open -a VertusFleet` / NSWorkspace launch.
#
# Usage: scripts/make-fleet-app.sh [release]
#   (no arg)  wraps .build/debug/VertusFleet
#   release   wraps .build/release/VertusFleet
#
# Output: vertus/apps/dist/VertusFleet.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/${CONFIG}/VertusFleet"
DIST="dist"
APP="${DIST}/VertusFleet.app"

if [[ ! -x "${BIN}" ]]; then
    echo "error: ${BIN} not found — run 'swift build${CONFIG:+ -c ${CONFIG}}' first" >&2
    exit 1
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/VertusFleet"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VertusFleet</string>
    <key>CFBundleDisplayName</key>
    <string>Vertus Fleet</string>
    <key>CFBundleIdentifier</key>
    <string>com.vertus.fleet</string>
    <key>CFBundleExecutable</key>
    <string>VertusFleet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "wrote ${APP}"