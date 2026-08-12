"""
prime_mcp_server.py

MCP stdio server exposing the prime-agent coding agent
(PrimeIntellect-ai/prime-agent) as a tool for Alfred.

prime-agent is the self-improving RLM fork of pi: recursive subagents,
a persistent IPython kernel as its primary tool, and a `/refine`
self-improvement loop that updates its own skills and memory from its
trajectory. Each call here spawns `prime-agent -p "<prompt>"` (print mode)
in the requested working directory and returns the agent's final output.

Install: npm install -g <prime-agent release tarball>   (see README)
Run standalone (for testing):  python3 prime_mcp_server.py
Registered by Alfred via ~/.alfred/agent-servers.json.
"""

import asyncio
import shutil
import os
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

server = Server("prime-agent")


def resolve_prime() -> str | None:
    """The prime-agent CLI, on the usual user bins or npm-global.

    Deliberately no fallback to `pi`: prime-agent is a *different* agent
    (self-improving RLM fork), and silently driving pi from a tool named
    run_prime_task would be misleading. If prime-agent is missing the caller
    gets the explicit install error below instead.
    """
    return (
        shutil.which("prime-agent")
        or shutil.which("prime-agent.js")
        or f"{Path.home()}/.npm-global/bin/prime-agent"
    )


async def run_prime(prompt: str, cwd: str, timeout_seconds: int) -> str:
    binary = resolve_prime()
    if not binary or not os.access(binary, os.X_OK):
        return (
            "Error: prime-agent (coding agent) is not installed. "
            "Install it from the GitHub releases tarball: "
            "curl -L https://github.com/PrimeIntellect-ai/prime-agent/releases "
            "→ npm install -g prime-agent-<ver>.tgz"
        )

    workdir = Path(cwd).expanduser() if cwd else Path.home()
    if not workdir.is_dir():
        workdir = Path.home()

    # `prime-agent -p` writes nothing to stdout until the turn ends; capture
    # both streams so a noisy provider never wedges the pipe. --mode text is
    # the print-mode default; keep it explicit for clarity.
    proc = await asyncio.create_subprocess_exec(
        binary, "-p", "--mode", "text", prompt,
        cwd=str(workdir),
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=os.environ.copy(),
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_seconds)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return f"Error: prime-agent task timed out after {timeout_seconds}s. The request may still be running."

    out = stdout.decode("utf-8", errors="replace").strip()
    err = stderr.decode("utf-8", errors="replace").strip()
    if proc.returncode != 0:
        tail = err[-2000:] if err else "no stderr"
        return f"Error: prime-agent exited with code {proc.returncode}.\n{tail}"
    if not out:
        return "prime-agent returned no output." + (f"\n[stderr] {err[-1000:]}" if err else "")
    return out


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="run_prime_task",
            description=(
                "Run a coding task with prime-agent, the self-improving RLM coding agent. "
                "Use for: multi-file software engineering, long-running autonomous tasks, "
                "debugging, refactoring, and anything where the agent should reason over a "
                "whole repository. prime-agent runs recursively (it can spawn its own "
                "subagents), uses a persistent IPython kernel as its primary tool, and "
                "improves its own skills/memory over time via its /refine loop. It works "
                "autonomously: reads files, edits code, runs commands in the working "
                "directory."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "The task to give prime-agent, in plain language.",
                    },
                    "working_directory": {
                        "type": "string",
                        "description": "Absolute path of the project to work in. Defaults to the user's home directory.",
                    },
                    "timeout_seconds": {
                        "type": "integer",
                        "description": "Max seconds to wait. Default 600 (prime-agent tasks can be long).",
                    },
                },
                "required": ["prompt"],
            },
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "run_prime_task":
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    prompt = arguments.get("prompt", "")
    cwd = arguments.get("working_directory", "")
    timeout = int(arguments.get("timeout_seconds", 600))

    if not prompt.strip():
        return [TextContent(type="text", text="Error: prompt is required.")]

    result = await run_prime(prompt, cwd, timeout)
    return [TextContent(type="text", text=result)]


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
