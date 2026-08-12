#!/usr/bin/env bash
# Bridge for the browser-use MCP server (browser-use/browser-use, MIT).
#
# browser-use 3.x runs its MCP server via `browser-use --mcp`. This wrapper
# points PATH at the project venv (so the `browser-use` binary and its
# Playwright browser install are found regardless of how Alfred was launched)
# and lets the server inherit the provider keys Alfred's ProviderKeyRing
# injects into the session environment.
set -u
BRIDGE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$BRIDGE/.venvs/browser-use/bin:$PATH"
exec "$BRIDGE/.venvs/browser-use/bin/browser-use" --mcp "$@"
