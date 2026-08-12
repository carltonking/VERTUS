#!/usr/bin/env bash
# Setup + status for Alfred's external capability bridges.
#
# Wires the repos in ~/02 - REPOS into Alfred's Hermes sessions:
#   odysseus (memory/rag/email/image-gen),
#   omp (coding agent, oh-my-pi), openswarm (multi-agent deliverables).
#
# Usage:  ./setup.sh            # install services + report status
#         ./setup.sh --status   # just report status
set -euo pipefail

REPOS="$HOME/02 - REPOS"
ALFRED_CONFIG="$HOME/.alfred/agent-servers.json"
OPENSWARM_PORT=8080
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { echo; echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

# ---------------------------------------------------------------------------
# OpenSwarm: venv + launchd service (auto-start on login)
# ---------------------------------------------------------------------------
setup_openswarm() {
  local dir="$REPOS/OpenSwarm"
  if [ ! -d "$dir/.venv" ]; then
    warn "OpenSwarm venv missing — creating (this takes a few minutes)"
    /opt/homebrew/bin/python3.12 -m venv "$dir/.venv" || python3.12 -m venv "$dir/.venv" || python3 -m venv "$dir/.venv"
    "$dir/.venv/bin/pip" install -q --upgrade pip
    # OpenSwarm's patches target agency-swarm 1.9.x; newer versions break server.py
    "$dir/.venv/bin/pip" install -q -r "$dir/requirements.txt"
    "$dir/.venv/bin/pip" install -q "agency-swarm[fastapi,jupyter,litellm]==1.9.8"
  fi
  if [ ! -f "$dir/.env" ]; then
    cp "$dir/.env.example" "$dir/.env"
    warn "Fill in a provider key in $dir/.env (OPENAI_API_KEY, ANTHROPIC_API_KEY, or GOOGLE_API_KEY) — OpenSwarm won't answer until you do."
  fi

  local plist="$HOME/Library/LaunchAgents/com.alfred.openswarm.plist"
  if [ ! -f "$plist" ]; then
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alfred.openswarm</string>
    <key>ProgramArguments</key>
    <array>
        <string>$dir/.venv/bin/python</string>
        <string>$dir/server.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$dir</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$dir/server.log</string>
    <key>StandardErrorPath</key>
    <string>$dir/server.err</string>
</dict>
</plist>
PLIST
    launchctl bootstrap gui/$(id -u) "$plist" 2>/dev/null && ok "OpenSwarm service installed + started (http://127.0.0.1:$OPENSWARM_PORT)" || warn "launchctl failed — start manually: cd $dir && .venv/bin/python server.py"
  else
    launchctl kickstart -k gui/$(id -u)/com.alfred.openswarm 2>/dev/null || true
    ok "OpenSwarm service already installed (restarted)"
  fi
}

# ---------------------------------------------------------------------------
# browser-use: venv + Playwright browser for the browser-automation MCP server
# ---------------------------------------------------------------------------
setup_browser_use() {
  local bridge="$(cd "$(dirname "$0")" && pwd)"
  local venv="$bridge/.venvs/browser-use"
  if [ ! -x "$venv/bin/browser-use" ]; then
    warn "browser-use venv missing — creating"
    python3 -m venv "$venv"
    "$venv/bin/pip" install -q --upgrade pip
    "$venv/bin/pip" install -q browser-use
  fi
  if [ -x "$venv/bin/browser-use" ]; then
    ok "browser-use ready ($("$venv/bin/browser-use" --version 2>/dev/null || echo 'installed'))"
  else
    warn "browser-use install incomplete — run: $venv/bin/browser-use --doctor"
  fi
}

# ---------------------------------------------------------------------------
# agentmemory: hermes plugin + pi extension + MCP server
# ---------------------------------------------------------------------------
setup_agentmemory() {
  if ! command -v agentmemory >/dev/null 2>&1 && [ ! -x "$HOME/.npm-global/bin/agentmemory" ]; then
    warn "agentmemory not installed — run: npm install -g @agentmemory/agentmemory"
  else
    ok "agentmemory: $(agentmemory --version 2>/dev/null || echo installed)"
  fi
  if [ ! -d "$HOME/.hermes/plugins/agentmemory" ]; then
    warn "hermes agentmemory plugin missing — copy integrations/hermes to ~/.hermes/plugins/agentmemory"
  else
    ok "hermes agentmemory plugin installed"
  fi
  if [ ! -d "$HOME/.pi/agent/extensions/agentmemory" ]; then
    warn "pi agentmemory extension missing — copy integrations/pi to ~/.pi/agent/extensions/agentmemory"
  else
    ok "pi agentmemory extension installed"
  fi
}

# ---------------------------------------------------------------------------
# prime-agent: self-improving RLM coding agent (global npm install)
# ---------------------------------------------------------------------------
setup_prime_agent() {
  if command -v prime-agent >/dev/null 2>&1; then
    ok "prime-agent: $(prime-agent --version 2>/dev/null | head -1)"
  else
    warn "prime-agent not installed — install the release tarball: npm install -g <prime-agent-<ver>.tgz>"
  fi
}

# ---------------------------------------------------------------------------
# agentmemory: launchd service (auto-start the REST memory server on login)
# ---------------------------------------------------------------------------
setup_agentmemory_service() {
  local cli="$HOME/.npm-global/bin/agentmemory"
  local plist="$HOME/Library/LaunchAgents/com.alfred.agentmemory.plist"
  if [ ! -x "$cli" ]; then
    warn "agentmemory CLI not installed at $cli — launchd service skipped"
    return
  fi
  # Always rewrite the plist — it's generated, and a stale copy (old PATH, old
  # paths) silently defeats any fix made to the heredoc below. Write first,
  # then bootstrap only if the service isn't loaded yet, kickstart if it is.
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alfred.agentmemory</string>
    <key>ProgramArguments</key>
    <array>
        <string>$cli</string>
    </array>
    <!-- launchd's default PATH is /usr/bin:/bin:/usr/sbin:/sbin — node lives in
         /usr/local/bin, and the CLI shebang is #!/usr/bin/env node. Without this
         the job exits 127 immediately (env: node: No such file or directory). -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$HOME/.agentmemory</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.agentmemory/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.agentmemory/launchd.err</string>
</dict>
</plist>
PLIST
  if [ "$(launchctl list 2>/dev/null | grep -c com.alfred.agentmemory)" -eq 0 ]; then
    launchctl bootstrap gui/$(id -u) "$plist" 2>/dev/null && ok "agentmemory service installed + started (REST :3111)" || warn "launchctl failed — start manually: $cli"
  else
    launchctl kickstart -k gui/$(id -u)/com.alfred.agentmemory 2>/dev/null || true
    ok "agentmemory service already installed (restarted)"
  fi
}

# ---------------------------------------------------------------------------
# graphiti FalkorDB: launchd service (auto-start the Docker container on login)
# ---------------------------------------------------------------------------
setup_falkordb() {
  local wrapper="$BRIDGE_ROOT/agent-bridge/falkordb-launchd.sh"
  local plist="$HOME/Library/LaunchAgents/com.alfred.falkordb.plist"
  chmod +x "$wrapper"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found — FalkorDB launchd service skipped"
    return
  fi
  # Always rewrite the plist (same rationale as setup_agentmemory_service).
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alfred.falkordb</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$wrapper</string>
    </array>
    <!-- Same PATH fix as agentmemory: docker lives in /usr/local/bin, which is not
         on launchd's default PATH — the wrapper could never find it. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.alfred/logs/falkordb.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.alfred/logs/falkordb.err</string>
</dict>
</plist>
PLIST
    mkdir -p "$HOME/.alfred/logs"
  if [ "$(launchctl list 2>/dev/null | grep -c com.alfred.falkordb)" -eq 0 ]; then
    launchctl bootstrap gui/$(id -u) "$plist" 2>/dev/null && ok "FalkorDB service installed + started (:6379)" || warn "launchctl failed — start manually: bash $wrapper"
  else
    launchctl kickstart -k gui/$(id -u)/com.alfred.falkordb 2>/dev/null || true
    ok "FalkorDB service already installed (restarted)"
  fi
}

# ---------------------------------------------------------------------------
# graphiti: FalkorDB (Docker) + MCP server venv + Alfred config
# ---------------------------------------------------------------------------
setup_graphiti() {
  local server_dir="$REPOS/graphiti/mcp_server"
  if [ ! -x "$server_dir/.venv/bin/python" ]; then
    warn "graphiti server not installed at $server_dir — clone getzep/graphiti there and pip install -e .[providers] in mcp_server/"
  else
    ok "graphiti MCP server: $server_dir"
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q alfred-graphiti-falkordb; then
    ok "graphiti FalkorDB container running (:6379)"
  else
    warn "graphiti FalkorDB not running — start Docker, then: docker run -d --name alfred-graphiti-falkordb --restart unless-stopped -p 6379:6379 falkordb/falkordb:latest"
  fi
  if [ ! -f "$HOME/.alfred/graphiti-config.yaml" ]; then
    cp "$BRIDGE_ROOT/graphiti/alfred-config.yaml" "$HOME/.alfred/graphiti-config.yaml" && ok "wrote graphiti config"
  else
    ok "graphiti config present"
  fi
}

# ---------------------------------------------------------------------------
# Agent servers config
# ---------------------------------------------------------------------------
write_config() {
  if [ -f "$ALFRED_CONFIG" ]; then
    # Merge in any newly-added bridge servers idempotently.
    python3 "$BRIDGE_ROOT/scripts/merge_agent_servers.py" && ok "merged new servers into $ALFRED_CONFIG"
    return
  fi
  local bridge="$(cd "$(dirname "$0")" && pwd)"
  cat > "$ALFRED_CONFIG" <<JSON
{
  "servers": [
    {"name": "odyssey-memory",    "command": "python3", "args": ["$REPOS/odysseus/mcp_servers/memory_server.py"],   "env": []},
    {"name": "odyssey-rag",       "command": "python3", "args": ["$REPOS/odysseus/mcp_servers/rag_server.py"],      "env": []},
    {"name": "odyssey-email",     "command": "python3", "args": ["$REPOS/odysseus/mcp_servers/email_server.py"],    "env": []},
    {"name": "odyssey-image-gen", "command": "python3", "args": ["$REPOS/odysseus/mcp_servers/image_gen_server.py"],"env": []},
    {"name": "omp-agent",          "command": "python3", "args": ["$bridge/omp_mcp_server.py"],                        "env": []},
    {"name": "openswarm",         "command": "python3", "args": ["$bridge/openswarm_mcp_server.py"],                 "env": []},
    {"name": "browser-use",       "command": "/bin/bash", "args": ["$bridge/browser-use-mcp-wrapper.sh"],             "env": []},
    {"name": "agentmemory",       "command": "npx",    "args": ["-y", "@agentmemory/mcp"],                          "env": []},
    {"name": "prime-agent",       "command": "python3", "args": ["$bridge/prime_mcp_server.py"],                     "env": []},
    {"name": "graphiti",          "command": "/bin/bash", "args": ["$bridge/graphiti-mcp-wrapper.sh"],               "env": []},
    {"name": "memory-graph",      "command": "python3", "args": ["$bridge/memory_graph_mcp_server.py"],              "env": []}
  ]
}
JSON
  ok "wrote $ALFRED_CONFIG"
}

# ---------------------------------------------------------------------------
# Obsidian vault: the home of Alfred's memory
# ---------------------------------------------------------------------------
setup_vault() {
  local vault="$REPOS/myPKA/PKM"
  mkdir -p "$HOME/.alfred"
  if [ ! -d "$vault" ]; then
    warn "vault not found at $vault — Alfred's memory stays in $HOME/.alfred/vault"
    return
  fi
  cat > "$HOME/.alfred/obsidian.json" <<JSON
{"vaultPath": "$vault"}
JSON
  ok "memory vault: $vault"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
status() {
  echo
  echo "Alfred capability bridges"
  echo "────────────────────────"
  [ -f "$ALFRED_CONFIG" ] && ok "config: $(grep -c '"name"' "$ALFRED_CONFIG") servers in $ALFRED_CONFIG" || warn "config missing — run ./setup.sh"
  if [ -f "$HOME/.alfred/obsidian.json" ]; then
    local vault="$(sed -n 's/.*"vaultPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.alfred/obsidian.json")"
    [ -d "$vault" ] && ok "memory vault: $vault" || warn "memory vault configured but missing: $vault"
  else
    warn "memory vault not configured — run ./setup.sh"
  fi
  if curl -s --max-time 2 "http://127.0.0.1:$OPENSWARM_PORT/openapi.json" >/dev/null 2>&1; then
    ok "OpenSwarm server: running on :$OPENSWARM_PORT"
  else
    warn "OpenSwarm server: not running (cd $REPOS/OpenSwarm && .venv/bin/python server.py)"
  fi
  ok "omp agent: $(command -v omp || echo "$HOME/.bun/bin/omp") $(omp --version 2>/dev/null | head -1 || true)"
  ok "prime-agent: $(command -v prime-agent || echo "not installed") $(prime-agent --version 2>/dev/null | head -1 || true)"
  ok "hermes: $HOME/.hermes/hermes-agent/venv/bin/hermes (agentmemory plugin: $([ -d "$HOME/.hermes/plugins/agentmemory" ] && echo yes || echo no))"
  ok "browser-use MCP: $([ -x "$(cd "$(dirname "$0")" && pwd)/.venvs/browser-use/bin/browser-use" ] && echo ready || echo 'not installed')"
  ok "graphiti: $([ -x "$REPOS/graphiti/mcp_server/.venv/bin/python" ] && echo ready || echo 'not installed')"
  # grep -c (not -q): under `set -o pipefail`, grep -q exits on the first match and
  # SIGPIPEs launchctl, whose rc 141 then fails the pipeline — false "not loaded".
  if [ "$(launchctl list 2>/dev/null | grep -c com.alfred.agentmemory)" -gt 0 ]; then
    ok "agentmemory service: loaded (REST :3111)"
  else
    warn "agentmemory service: not loaded (run ./setup.sh)"
  fi
  if [ "$(launchctl list 2>/dev/null | grep -c com.alfred.falkordb)" -gt 0 ]; then
    ok "FalkorDB service: loaded (container :6379)"
  else
    warn "FalkorDB service: not loaded (run ./setup.sh)"
  fi
}

# ---------------------------------------------------------------------------
# MCP bridge smoke test: every registered server boots and answers tools/list.
# Complements the status checks above — those verify backing services and
# installs; this proves the bridges themselves speak MCP. Exits nonzero when
# any server fails, so `./setup.sh --status` doubles as a release gate.
# ---------------------------------------------------------------------------
run_smoke_test() {
  step "MCP bridge smoke test (boot + tools/list for every server)"
  python3 "$BRIDGE_ROOT/agent-bridge/smoke_test_servers.py" --concurrency 4 --timeout 60
}

MODE="${1:---install}"
case "$MODE" in
  --status) status; run_smoke_test ;;
  *) write_config; setup_openswarm; setup_browser_use; setup_agentmemory; setup_agentmemory_service; setup_prime_agent; setup_graphiti; setup_falkordb; setup_vault; status ;;
esac
