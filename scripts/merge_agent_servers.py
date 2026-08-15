#!/usr/bin/env python3
"""Idempotently merge Alfred's capability-bridge servers into the live
~/.alfred/agent-servers.json. Preserves existing entries (and their order),
adds or replaces the named servers, and writes a backup first.

Usage:
    python3 scripts/merge_agent_servers.py [--dry-run]
"""
import datetime
import json
import os
import shutil
import sys

HOME = os.path.expanduser("~")
CONFIG = os.path.join(HOME, ".alfred", "agent-servers.json")
BRIDGE = "/Users/carltonking/01 - PROJECTS/ALFRED/agent-bridge"

# The integrations added since the base odysseus/omp/openswarm set.
# Keep the same shape as the example config so the repo and the live file can
# never drift apart.
NEW_SERVERS = [
    {
        "name": "browser-use",
        "command": "/bin/bash",
        "args": [f"{BRIDGE}/browser-use-mcp-wrapper.sh"],
        "env": [],
    },
    {
        "name": "agentmemory",
        "command": "npx",
        "args": ["-y", "@agentmemory/mcp"],
        "env": [],
    },
    {
        "name": "prime-agent",
        "command": "python3",
        "args": [f"{BRIDGE}/prime_mcp_server.py"],
        "env": [],
    },
    {
        "name": "graphiti",
        "command": "/bin/bash",
        "args": [f"{BRIDGE}/graphiti-mcp-wrapper.sh"],
        "env": [],
    },
    {
        "name": "memory-graph",
        "command": "python3",
        "args": [f"{BRIDGE}/memory_graph_mcp_server.py"],
        "env": [],
    },
    {
        "name": "crawlee",
        "command": "/bin/bash",
        "args": [f"{BRIDGE}/crawlee-mcp-wrapper.sh"],
        "env": [],
    },
]


def main() -> int:
    dry_run = "--dry-run" in sys.argv
    if not os.path.exists(CONFIG):
        print(f"error: {CONFIG} not found", file=sys.stderr)
        return 1

    with open(CONFIG) as f:
        cfg = json.load(f)

    servers = cfg.setdefault("servers", [])
    existing = {s["name"] for s in servers}
    added, replaced = [], []
    for new in NEW_SERVERS:
        if new["name"] in existing:
            servers = [new if s["name"] == new["name"] else s for s in servers]
            replaced.append(new["name"])
        else:
            servers.append(new)
            added.append(new["name"])
    cfg["servers"] = servers

    if dry_run:
        print(f"dry-run: would add {added or 'none'}, replace {replaced or 'none'}")
        return 0

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(CONFIG, f"{CONFIG}.bak.{stamp}")
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"added: {added or 'none'}")
    print(f"replaced: {replaced or 'none'}")
    print(f"total servers now: {len(servers)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
