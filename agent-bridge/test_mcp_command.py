#!/usr/bin/env python3
"""Smoke-test any MCP stdio server as command + args (the fixed-argv test
harness can't pass args to non-.py bridges like npx or bash wrappers).

Usage:
    python3 test_mcp_command.py <cmd> [args...]
"""
import asyncio
import json
import subprocess
import sys


async def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        print("usage: test_mcp_command.py <cmd> [args...]", file=sys.stderr)
        return

    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    async def frame(req: dict, timeout: float = 90.0) -> dict:
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write((json.dumps(req) + "\n").encode())
        await proc.stdin.drain()
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=timeout)
        return json.loads(line)

    init = await frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "smoke-test", "version": "0.1"},
    }})
    print("initialize:", json.dumps(init, default=str)[:200])
    assert proc.stdin is not None
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode())
    await proc.stdin.drain()

    tools = await frame({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, timeout=120)
    names = [t["name"] for t in tools.get("result", {}).get("tools", [])]
    print(f"tools ({len(names)}):", names[:25])

    proc.kill()
    await proc.wait()
    err = (await proc.stderr.read()).decode(errors="replace")
    if err.strip():
        print("--- stderr tail ---")
        print(err[-1200:])


if __name__ == "__main__":
    asyncio.run(main())
