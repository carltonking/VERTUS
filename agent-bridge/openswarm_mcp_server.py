"""
openswarm_mcp_server.py

MCP stdio server exposing the OpenSwarm multi-agent system as a tool for
Alfred. OpenSwarm runs as a FastAPI server (agency_swarm) — this wrapper
delegates each call to `POST /{agency}/get_response` and returns the agency's
final output. The model spawns specialist agents (slides, deep research, data
analysis, docs, image/video generation) for a single prompt.

Start OpenSwarm before use:
    cd "$HOME/02 - REPOS/OpenSwarm"
    python server.py        # serves http://127.0.0.1:8080, agency "open-swarm"

Run standalone (for testing):  python3 openswarm_mcp_server.py
"""

import asyncio
import json
import urllib.error
import urllib.request

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

server = Server("openswarm")

DEFAULT_AGENCY = "open-swarm"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8080


async def post_get_response(prompt: str, agency: str, host: str, port: int, timeout: int) -> str:
    url = f"http://{host}:{port}/{agency}/get_response"
    body = json.dumps({"message": prompt}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        return (
            "Error: OpenSwarm server is not reachable. "
            "Start it with: cd ~/02 - REPOS/OpenSwarm && python server.py "
            f"(listening on {host}:{port}). Underlying error: {e}"
        )
    except Exception as e:
        return f"Error talking to OpenSwarm: {e}"

    # agency_swarm get_response returns {"response": ...}; be tolerant of
    # alternate shapes.
    if isinstance(payload, dict):
        for key in ("response", "message", "output", "result"):
            if key in payload and payload[key]:
                text = payload[key]
                if isinstance(text, list):
                    text = "\n".join(str(item) for item in text)
                return str(text)
    return json.dumps(payload, ensure_ascii=False, default=str)


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="run_openswarm_task",
            description=(
                "Run a task with the OpenSwarm multi-agent system. Use for big deliverables: "
                "polished slide decks, deep research reports, data visualizations, documents, "
                "images, or videos generated from a single prompt. OpenSwarm routes the request "
                "to specialist agents (orchestrator, slides, deep research, data analyst, docs, "
                "image/video generation). Requires the OpenSwarm server to be running locally."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "What to produce, in plain language (e.g. 'make a 10-slide deck on Q2 results').",
                    },
                    "agency": {
                        "type": "string",
                        "description": "Agency name on the server. Default 'open-swarm'.",
                    },
                    "host": {
                        "type": "string",
                        "description": "Server host. Default 127.0.0.1.",
                    },
                    "port": {
                        "type": "integer",
                        "description": "Server port. Default 8080.",
                    },
                    "timeout_seconds": {
                        "type": "integer",
                        "description": "Max seconds to wait for the agency. Default 600.",
                    },
                },
                "required": ["prompt"],
            },
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "run_openswarm_task":
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    prompt = arguments.get("prompt", "")
    if not prompt.strip():
        return [TextContent(type="text", text="Error: prompt is required.")]

    agency = arguments.get("agency", DEFAULT_AGENCY)
    host = arguments.get("host", DEFAULT_HOST)
    port = int(arguments.get("port", DEFAULT_PORT))
    timeout = int(arguments.get("timeout_seconds", 600))

    result = await post_get_response(prompt, agency, host, port, timeout)
    return [TextContent(type="text", text=result)]


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
