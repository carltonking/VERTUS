#!/bin/bash
# install.sh — One-shot Alfred installer.
# Deploys to ~/.alfred/app/, builds Alfred.app, copies to /Applications, registers login agent.

set -e

ALFRED_SRC="$(cd "$(dirname "$0")" && pwd)"
ALFRED_HOME="$HOME/.alfred"
ALFRED_INSTALL="$ALFRED_HOME/app"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Alfred Installer                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Python 3.10+ ───────────────────────────────────────────────────────────
echo "▸ Checking Python..."
if ! command -v python3 &>/dev/null; then
    echo "❌  python3 not found."
    echo "    Download: https://www.python.org/downloads/"
    exit 1
fi
PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    echo "❌  Python 3.10+ required (found $PY_MAJOR.$PY_MINOR)."
    echo "    Download: https://www.python.org/downloads/"
    exit 1
fi
echo "   Python $PY_MAJOR.$PY_MINOR ✓"

# ── 2. Swift compiler ─────────────────────────────────────────────────────────
echo "▸ Checking Swift compiler..."
if ! command -v swiftc &>/dev/null; then
    echo "❌  swiftc not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi
echo "   $(swiftc --version 2>&1 | head -1) ✓"

# ── 3. macOS version ─────────────────────────────────────────────────────────
echo "▸ Checking macOS version..."
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
OS_MINOR=$(sw_vers -productVersion | cut -d. -f2)
if [ "$OS_MAJOR" -lt 14 ]; then
    echo "❌  macOS 14.0 (Sonoma) or later required (found $(sw_vers -productVersion))."
    exit 1
fi
echo "   macOS $(sw_vers -productVersion) ✓"

# ── 4. Create ~/.alfred directory structure ───────────────────────────────────
echo "▸ Creating ~/.alfred directory structure..."
mkdir -p "$ALFRED_HOME/logs" "$ALFRED_HOME/db"
echo "   ~/.alfred/{logs,db} ✓"

# ── 5. Copy project to ~/.alfred/app/ ────────────────────────────────────────
echo "▸ Installing Alfred to $ALFRED_INSTALL ..."
mkdir -p "$ALFRED_INSTALL"
rsync -a \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.DS_Store' \
    --exclude='.build' \
    --exclude='alfred_ml_env' \
    "$ALFRED_SRC/" "$ALFRED_INSTALL/"
echo "   Copied ✓"

# ── 6. Build Alfred.app ───────────────────────────────────────────────────────
echo "▸ Building Alfred.app..."
bash "$ALFRED_INSTALL/AlfredMac/scripts/build_app.sh" --install
echo "   Alfred.app built and installed ✓"

# ── 7. Bootstrap .env if missing ─────────────────────────────────────────────
echo "▸ Checking configuration..."
if [ ! -f "$ALFRED_HOME/.env" ]; then
    if [ -f "$ALFRED_INSTALL/.env.example" ]; then
        cp "$ALFRED_INSTALL/.env.example" "$ALFRED_HOME/.env"
    else
        touch "$ALFRED_HOME/.env"
    fi
    echo ""
    echo "   ⚠️  No configuration found. Created ~/.alfred/.env"
    echo "   Add your API keys for the providers you want to use:"
    echo ""
    echo "     open ~/.alfred/.env"
    echo ""
else
    echo "   ~/.alfred/.env already exists ✓"
fi

# ── 8. Register launchd login agent ─────────────────────────────────────────
echo "▸ Registering login agent..."
bash "$ALFRED_INSTALL/install_launchd.sh"

# ── 9. Done ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅  Done!                                               ║"
echo "║                                                          ║"
echo "║  Alfred is in your menu bar. Press Cmd+Shift+J anywhere  ║"
echo "║  to open the bar.                                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
