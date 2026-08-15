#!/usr/bin/env bash
# Bridge for the Crawlee MCP server (our own wrapper around the crawlee npm
# library — Crawlee ships no native MCP server, and Apify's cloud server needs
# an API token; this is the local, keyless face).
#
# Points PATH at the bridge's node_modules/.bin (so npx-resolved binaries are
# found regardless of how Alfred was launched) and execs the MCP server. The
# server inherits whatever environment Alfred's session carries; nothing is
# filtered. stdout is the JSON-RPC channel — this wrapper writes nothing to it.
set -u
BRIDGE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$BRIDGE/crawlee/node_modules/.bin:$PATH"
exec node "$BRIDGE/crawlee/crawlee_mcp_server.mjs" "$@"
