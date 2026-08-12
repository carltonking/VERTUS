#!/usr/bin/env python3
"""Smoke-test an MCP stdio server: initialize, tools/list, optional tool call.

Usage:
    python3 test_mcp_server.py <server_script> [tool_name] [tool_args_json]
"""
import asyncio
import json
import subprocess
import sys


async def main() -> None:
    script = sys.argv[1]
    tool_name = sys.argv[2] if len(sys.argv) > 2 else None
    tool_args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

    # Non-.py bridges (shell wrappers) exec directly; Python servers run via
    # the interpreter.
    if script.endswith(".py"):
        argv = ["python3", script]
    else:
        argv = [script]

    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    async def frame(req: dict, timeout: float = 30.0) -> dict:
        assert proc.stdin is not None and proc.stdout is not None
        proc.stdin.write((json.dumps(req) + "\n").encode())
        await proc.stdin.drain()
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=timeout)
        except asyncio.TimeoutError:
            raise TimeoutError(f"no response in {timeout}s")
        return json.loads(line)

    init = await frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "smoke-test", "version": "0.1"},
    }})
    print("initialize:", json.dumps(init, default=str)[:300])
    assert proc.stdin is not None
    proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n").encode())
    await proc.stdin.drain()

    tools = await frame({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = [t["name"] for t in tools.get("result", {}).get("tools", [])]
    print("tools:", names)

    if tool_name:
        result = await frame({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                              "params": {"name": tool_name, "arguments": tool_args}}, timeout=600)
        text = ""
        for c in result.get("result", {}).get("content", []):
            text += c.get("text", "")
        print(f"tool call [{tool_name}]:")
        print(text[:3000])

    proc.kill()
    await proc.wait()
    err = (await proc.stderr.read()).decode(errors="replace")
    if err.strip():
        print("--- stderr tail ---")
        print(err[-1500:])


if __name__ == "__main__":
    asyncio.run(main())
