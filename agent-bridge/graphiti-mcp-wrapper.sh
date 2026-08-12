#!/usr/bin/env bash
# Bridge for the graphiti MCP server (getzep/graphiti, Apache-2.0).
#
# graphiti maintains a temporal knowledge graph (entities, relations, facts
# with validity windows) in FalkorDB. This wrapper:
#   * runs the server from its repo venv (~/02 - REPOS/graphiti),
#   * uses a dedicated config tuned for Alfred's free-tier providers:
#     Groq for the LLM, Gemini for embeddings — both keys already in
#     Alfred's ProviderKeyRing and injected into this process's env
#     (GROQ_API_KEY, GEMINI_API_KEY),
#   * maps GEMINI_API_KEY → GOOGLE_API_KEY (graphiti's gemini provider
#     reads GOOGLE_API_KEY; Alfred stores the same key under GEMINI_API_KEY),
#   * talks to FalkorDB at 127.0.0.1:6379 (Docker container
#     alfred-graphiti-falkordb).
#
# Registered by Alfred via ~/.alfred/agent-servers.json.
set -u

REPOS="$HOME/02 - REPOS"
SERVER_DIR="$REPOS/graphiti/mcp_server"
PYTHON="$SERVER_DIR/.venv/bin/python"
MAIN="$SERVER_DIR/main.py"
CONFIG="$HOME/.alfred/graphiti-config.yaml"

# Fall back to GEMINI_API_KEY when GOOGLE_API_KEY isn't set — Alfred's
# ProviderKeyRing injects the former.
if [ -z "${GOOGLE_API_KEY:-}" ] && [ -n "${GEMINI_API_KEY:-}" ]; then
  export GOOGLE_API_KEY="$GEMINI_API_KEY"
fi

if [ ! -x "$PYTHON" ] || [ ! -f "$MAIN" ]; then
  echo "graphiti: server not installed at $SERVER_DIR (run agent-bridge/setup.sh)" >&2
  exit 1
fi
if [ ! -f "$CONFIG" ]; then
  echo "graphiti: config missing at $CONFIG (run agent-bridge/setup.sh to copy it)" >&2
  exit 1
fi

# -u: unbuffered stdout. Without it the MCP handshake response sits in
# Python's block buffer (flushed only at exit), so Alfred's session start
# would hang waiting for initialize. Same reason PYTHONUNBUFFERED is set
# defensively for any child the server spawns.
export PYTHONUNBUFFERED=1
exec "$PYTHON" -u "$MAIN" --config "$CONFIG" --transport stdio "$@"
