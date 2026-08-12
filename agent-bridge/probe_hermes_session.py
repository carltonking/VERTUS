#!/usr/bin/env python3
"""Probe: register Alfred's external MCP servers in a real `hermes acp`
session and confirm they register. Mirrors HermesSession.swift's session/new
payload exactly (loaded from ~/.alfred/agent-servers.json)."""
import asyncio
import json
import subprocess
import sys
from pathlib import Path


def load_servers() -> list[dict]:
    raw = json.loads(Path.home().joinpath(".alfred/agent-servers.json").read_text())
    return [
        {"name": s["name"], "command": s["command"],
         "args": s.get("args", []), "env": [{"name": e["name"], "value": e["value"]} for e in s.get("env", [])]}
        for s in raw["servers"]
    ]


async def main() -> None:
    servers = load_servers()
    print(f"servers to register: {[s['name'] for s in servers]}")

    proc = await asyncio.create_subprocess_exec(
        str(Path.home() / ".hermes/hermes-agent/venv/bin/hermes"), "acp",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    pending = []
    logs = []

    async def drain_stderr():
        assert proc.stderr is not None
        while True:
            line = await proc.stderr.readline()
            if not line:
                break
            logs.append(line.decode(errors="replace").rstrip())

    asyncio.get_event_loop().create_task(drain_stderr())

    async def frame(req: dict, timeout: float = 60.0) -> dict:
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write((json.dumps(req) + "\n").encode())
        await proc.stdin.drain()
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=timeout)
        return json.loads(line)

    init = await frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": 1,
        "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        "clientInfo": {"name": "alfred-probe", "version": "0.1"},
    }})
    print("initialize:", json.dumps(init, default=str)[:200])

    sess = await frame({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {
        "cwd": str(Path.home()),
        "mcpServers": servers,
    }})
    print("session/new:", json.dumps(sess, default=str)[:300])

    await asyncio.sleep(8)
    reg = [l for l in logs if "mcp" in l.lower() or "tool" in l.lower() or "server" in l.lower()]
    print("--- hermes logs (mcp/tool/server) ---")
    print("\n".join(reg[-30:]) if reg else "(none)")

    proc.kill()
    await proc.wait()


if __name__ == "__main__":
    asyncio.run(main())
