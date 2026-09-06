#!/bin/bash
# Assemble VertusBar.app from a `swift build` product so the bar gets a
# real bundle (Info.plist + bundle id) — required for the launchd agent
# (which must point at a bundle product, not a raw binary) and for a
# stable UserDefaults domain.
#
# Usage: scripts/make-bar-app.sh [release]
#   (no arg)  wraps .build/debug/VertusBar
#   release   wraps .build/release/VertusBar
#
# Output: vertus/apps/dist/VertusBar.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/${CONFIG}/VertusBar"
DIST="dist"
APP="${DIST}/VertusBar.app"

if [[ ! -x "${BIN}" ]]; then
    echo "error: ${BIN} not found — run 'swift build${CONFIG:+ -c ${CONFIG}}' first" >&2
    exit 1
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/VertusBar"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VertusBar</string>
    <key>CFBundleDisplayName</key>
    <string>Vertus Bar</string>
    <key>CFBundleIdentifier</key>
    <string>com.vertus.bar</string>
    <key>CFBundleExecutable</key>
    <string>VertusBar</string>
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
    <!-- Menu-bar/notch utility: no Dock icon, no window at launch. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "wrote ${APP}"