#!/bin/bash
# ONE command to build the VERTUS app as a real .app bundle.
#
#   scripts/build-app.sh [release]
#     (no arg)  swift build (debug) + bundle
#     release   swift build -c release + bundle
#
# The bundle step is not cosmetic: UNUserNotificationCenter requires a real
# bundle, SMAppService (login item) requires a bundle, and the app gets a
# stable bundle id (com.vertus.app) for UserDefaults.
# Output: vertus/apps/dist/Vertus.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"

if [[ "${CONFIG}" == "release" ]]; then
    swift build -c release
else
    swift build
fi

BIN=".build/${CONFIG}/Vertus"
DIST="dist"
# Bundle folder name matches the display name (Finder shows the file name;
# a VERTUS.app folder with a "Vertus" plist reads as two different apps).
APP="${DIST}/Vertus.app"

if [[ ! -x "${BIN}" ]]; then
    echo "error: ${BIN} not found — run 'swift build${CONFIG:+ -c ${CONFIG}}' first" >&2
    exit 1
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/Vertus"
# App icon (Dock/Finder) — the VERTUS diamond.
cp "assets/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"
# Menubar/panel images: primary load path is Bundle resources now that the
# app is always bundled (the legacy vertus-bar/ dir remains a fallback).
cp "vertus-bar/menubar-icon.png" "${APP}/Contents/Resources/"
cp "vertus-bar/LOGO_DARKMODE.png" "${APP}/Contents/Resources/"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Vertus</string>
    <key>CFBundleDisplayName</key>
    <string>Vertus</string>
    <key>CFBundleIdentifier</key>
    <string>com.vertus.app</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Vertus</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "${APP}" 2>/dev/null || true

echo "app bundled:"
echo "  ${APP}"
echo "bundle id: com.vertus.app (display name Vertus)"