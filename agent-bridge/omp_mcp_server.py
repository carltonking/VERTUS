"""
omp_mcp_server.py

MCP stdio server exposing the oh-my-pi (omp) coding agent as a tool for Alfred.
Each call spawns `omp -p "<prompt>"` (print mode) in the requested working
directory and returns the agent's final text output. omp is the enhanced
successor of the Pi coding agent (fork of badlogic/pi-mono) and adds
hash-anchored edits, LSP-aware operations, in-process grep/glob/bash, and
subagent fan-out — Alfred gets all of it through the same one-shot contract
the old `pi -p` bridge used.

Run standalone (for testing):  python3 omp_mcp_server.py
Registered by Alfred via ~/.alfred/agent-servers.json.
"""

import asyncio
import json
import os
import shutil
import sys
from pathlib import Path

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

server = Server("omp-agent")

# Derived from ~/.omp/agent/models.db; keeps the bridge deterministic about
# which provider/model a one-shot task runs on. The env check mirrors what
# Alfred's ProviderKeyRing injects into Hermes (and thus into this process).
MODEL_BY_KEY_ENV = [
    ("GEMINI_API_KEY", "google/gemini-2.5-flash-lite"),
    ("GOOGLE_API_KEY", "google/gemini-2.5-flash-lite"),
    ("GROQ_API_KEY", "groq/llama-3.1-8b-instant"),
    ("OPENROUTER_API_KEY", "openrouter/google/gemini-2.5-flash:free"),
]


def resolve_omp() -> str | None:
    for candidate in ("omp", "pi"):
        found = shutil.which(candidate)
        if found:
            return found
    # omp installs to ~/.bun/bin/omp; launchd-spawned bridges may miss bun's bin dir.
    for home_bin in ("~/.bun/bin/omp", "~/.npm-global/bin/omp"):
        path = Path(home_bin).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def default_model() -> str | None:
    """Pick a model from the provider keys Alfred injected into this process's
    environment, in the same order ProviderKeyRing stores them."""
    override = os.environ.get("OMP_MODEL", "").strip()
    if override:
        return override
    for env_key, model in MODEL_BY_KEY_ENV:
        if os.environ.get(env_key, "").strip():
            return model
    return None


async def run_omp(prompt: str, cwd: str, timeout_seconds: int) -> str:
    binary = resolve_omp()
    if not binary:
        return ("Error: omp (oh-my-pi coding agent) is not installed. "
                "Install with: bun install -g @oh-my-pi/pi-coding-agent")

    workdir = Path(cwd).expanduser()
    if not workdir.is_dir():
        workdir = Path.home()

    argv = [binary, "-p", prompt]
    model = default_model()
    if model:
        argv += ["--model", model]
    argv += [
        "--max-time", str(timeout_seconds),
        "--no-session",
        "--cwd", str(workdir),
    ]

    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=os.environ.copy(),
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_seconds + 30)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return (f"Error: omp task timed out after {timeout_seconds}s. "
                "The request may still be running.")

    out = stdout.decode("utf-8", errors="replace").strip()
    err = stderr.decode("utf-8", errors="replace").strip()
    if proc.returncode != 0:
        tail = err[-2000:] if err else "no stderr"
        return f"Error: omp exited with code {proc.returncode}.\n{tail}"
    if not out:
        return "omp returned no output." + (f"\n[stderr] {err[-1000:]}" if err else "")
    return out


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="run_omp_task",
            description=(
                "Run a coding task with the omp coding agent (oh-my-pi, the enhanced fork of "
                "pi.dev). Use for: writing or editing code in a repository, debugging, code "
                "review, refactoring, running tests, or any multi-file software task. omp works "
                "autonomously: it reads files, edits code with hash-anchored patches, uses LSP "
                "for renames/diagnostics, and runs commands in the working directory."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "The task to give omp, in plain language.",
                    },
                    "working_directory": {
                        "type": "string",
                        "description": "Absolute path of the project to work in. Defaults to the user's home directory.",
                    },
                    "timeout_seconds": {
                        "type": "integer",
                        "description": "Max seconds to wait. Default 300.",
                    },
                },
                "required": ["prompt"],
            },
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "run_omp_task":
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    prompt = arguments.get("prompt", "")
    cwd = arguments.get("working_directory", "")
    timeout = int(arguments.get("timeout_seconds", 300))

    if not prompt.strip():
        return [TextContent(type="text", text="Error: prompt is required.")]

    result = await run_omp(prompt, cwd, timeout)
    return [TextContent(type="text", text=result)]


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())