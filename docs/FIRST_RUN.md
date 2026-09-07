# First run — fresh machine

What a new Mac needs to run the VERTUS fleet. This file is tested literally:
every step below was executed from scratch against a machine with no
`~/.vertus` at all.

## Prerequisites

- macOS 13+ with the Xcode Command Line Tools (`xcode-select --install`).
- The hermes fork checked out at `~/.hermes/hermes-agent` **with its own
  venv installed** (the fork's install instructions; the hub spawns the
  gateway with `~/.hermes/hermes-agent/venv/bin/python`). Override with
  `VERTUS_HERMES_REPO` / `VERTUS_HERMES_PYTHON` if the fork lives elsewhere.
- Tailscale (optional — the hub also binds your tailnet IP so VertusPhone
  can reach it; without it the hub binds 127.0.0.1 only).

## Install

```bash
# 1. Get the repo.
git clone <your-remote> VERTUS && cd VERTUS

# 2. Install the launchd agents (hub + bar). No log-dir setup needed: the
#    hub creates ~/.vertus/{token,agents,logs} itself at first boot, and
#    launchd spawns fine even when the log parent dir does not exist yet
#    (verified by testing without it).
cp disabled-launchagents/com.vertus.server.plist  ~/Library/LaunchAgents/
cp disabled-launchagents/com.vertusbar.dev.plist  ~/Library/LaunchAgents/

# 3. Build the clients BEFORE starting the bar agent — its plist launches
#    dist/VertusBar.app, and KeepAlive will relaunch a missing binary in a
#    hot loop.
cd vertus/apps && bash scripts/build-apps.sh release && cd ../..

# 4. Start everything.
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vertus.server.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vertusbar.dev.plist
```

## Verify

```bash
# The bearer token is created automatically at first hub boot.
curl -s -H "Authorization: Bearer $(cat ~/.vertus/token)" \
     http://127.0.0.1:8787/api/health
# expect: "status": "ok", every subsystem ok, agents >= 1
```

The `primary` agent is auto-created at boot (its home, sandbox, and persona
are materialized under `~/.vertus/agents/primary/`). Create more agents and
routines in the VERTUS app (`open /Applications/Vertus.app`), or via
`POST /api/agents` and `POST /api/routines`.

Everything survives reboot (both agents are installed in
`~/Library/LaunchAgents/`). The hub's log rotates at
`~/.vertus/logs/vertus.log` (5MB × 5) and its stdout/stderr land in
`~/.vertus/logs/server.{out,err}` via launchd.