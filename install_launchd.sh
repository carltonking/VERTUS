#!/bin/bash
# install_launchd.sh — Register Alfred.app to launch on login via launchd.
set -e

ALFRED_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.alfred.launcher.plist"
PLIST_SRC="$ALFRED_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Alfred — Install Launch Agent                           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Unload existing agent (makes reinstall safe)
if launchctl list | grep -q "com.alfred.launcher"; then
    echo "   Unloading existing agent..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/.alfred/logs"

# Stamp the log dir token
sed -e "s|__LOG_DIR__|$HOME/.alfred/logs|g" \
    "$PLIST_SRC" > "$PLIST_DEST"

echo "   Copied plist to $PLIST_DEST"

launchctl load "$PLIST_DEST"
echo ""
echo "✅  Alfred launch agent installed."
echo ""
echo "   Alfred starts automatically on login."
echo "   Press Cmd+Shift+J anywhere to open the bar."
echo ""
echo "   To start now:   launchctl start com.alfred.launcher"
echo "   To remove:      launchctl unload $PLIST_DEST"
echo ""
