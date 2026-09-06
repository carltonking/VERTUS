#!/bin/bash
# ONE command to build both macOS clients as real .app bundles.
#
#   scripts/build-apps.sh [release]
#     (no arg)  swift build (debug) + both bundles
#     release   swift build -c release + both bundles
#
# The bundle step is not cosmetic: UNUserNotificationCenter requires a real
# bundle, launchd's bar agent must point at a bundle product, and the app
# gets a stable bundle id (com.vertus.fleet / com.vertus.bar) for
# UserDefaults. Output: vertus/apps/dist/VertusFleet.app and
# vertus/apps/dist/VertusBar.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"

if [[ "${CONFIG}" == "release" ]]; then
    swift build -c release
else
    swift build
fi

bash scripts/make-fleet-app.sh "${CONFIG}"
bash scripts/make-bar-app.sh "${CONFIG}"

echo "both apps wrapped:"
echo "  dist/VertusFleet.app"
echo "  dist/VertusBar.app"