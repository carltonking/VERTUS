#!/usr/bin/env bash
# falkordb-launchd.sh — keep the graphiti FalkorDB container alive.
#
# launchd runs this at login (RunAtLoad) and keeps it resident (KeepAlive),
# matching the OpenSwarm service pattern in agent-bridge/setup.sh.
#
# Why a loop instead of a one-shot: Docker Desktop boots slowly at login, and
# the container can vanish entirely when Docker restarts (seen 2026-08-10).
# `--restart unless-stopped` on the container only helps once Docker is up and
# the container exists — so this script waits for the daemon, ensures the
# container exists and is running, then re-checks every 30s forever. It never
# exits, which keeps launchd's KeepAlive satisfied without respawn churn.
#
# Pause: `touch ~/.alfred/falkordb.paused` stops the self-healing (e.g. to free
# RAM for the night). Delete the file to resume. Logs only on state transitions
# so an idle run never grows the log.
set -uo pipefail

NAME="alfred-graphiti-falkordb"
IMAGE="falkordb/falkordb:latest"
PORT="6379:6379"
LOG_DIR="${HOME}/.alfred/logs"
LOG="${LOG_DIR}/falkordb-launchd.log"
PAUSE_FILE="${HOME}/.alfred/falkordb.paused"

mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Track last known state so we only log when it changes, not every 30s tick.
PREV_DOCKER=""
PREV_RUNNING=""
PREV_PAUSED=""

ensure_running() {
  if ! docker inspect "$NAME" >/dev/null 2>&1; then
    if [ "$PREV_RUNNING" != "missing" ]; then
      log "container missing — creating"
      PREV_RUNNING="missing"
    fi
    docker run -d --name "$NAME" --restart unless-stopped -p "$PORT" "$IMAGE" >> "$LOG" 2>&1
  elif [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    if [ "$PREV_RUNNING" != "stopped" ]; then
      log "container stopped — starting"
      PREV_RUNNING="stopped"
    fi
    docker start "$NAME" >> "$LOG" 2>&1
  else
    PREV_RUNNING="running"
  fi
}

log "falkordb-launchd starting"

while true; do
  if [ -f "$PAUSE_FILE" ]; then
    if [ "$PREV_PAUSED" != "yes" ]; then
      log "paused (found $PAUSE_FILE) — not self-healing until it's removed"
      PREV_PAUSED="yes"
    fi
  else
    PREV_PAUSED="no"
    if docker info >/dev/null 2>&1; then
      if [ "$PREV_DOCKER" != "up" ]; then
        log "docker daemon up"
        PREV_DOCKER="up"
      fi
      ensure_running
    else
      if [ "$PREV_DOCKER" != "down" ]; then
        log "docker daemon not up — will retry every 30s"
        PREV_DOCKER="down"
      fi
    fi
  fi
  sleep 30
done
