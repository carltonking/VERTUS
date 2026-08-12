#!/usr/bin/env python3
"""End-to-end smoke test for memory_graph_mcp_server.py.

Boots the server over stdio, lists tools, and calls both tools with live
queries against the real agentmemory (:3111) and graphiti (FalkorDB :6379)
stores. Prints PASS/FAIL per step; exits non-zero on failure.

Usage: python3 test_memory_graph.py
"""
import asyncio
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER = sys.argv[1] if len(sys.argv) > 1 else "memory_graph_mcp_server.py"


async def main() -> int:
    params = StdioServerParameters(command=sys.executable, args=[SERVER])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            tools = result.tools if hasattr(result, "tools") else result
            names = [t.name for t in tools]
            print(f"tools: {names}")
            assert "memory_graph_query" in names, "memory_graph_query missing"
            assert "memory_graph_person" in names, "memory_graph_person missing"

            # 1. Merged query — "Carlton" should hit graphiti entities + agentmemory.
            r = await session.call_tool("memory_graph_query", {"query": "Carlton", "limit": 5})
            text = r.content[0].text if r.content else ""
            print("=== memory_graph_query('Carlton') ===")
            print(text)
            assert "[graphiti]" in text or "[agentmemory]" in text, "no store sections returned"

            # 2. Person deep dive — Carlton exists in the graph (verified earlier).
            r = await session.call_tool("memory_graph_person", {"name": "Carlton"})
            text = r.content[0].text if r.content else ""
            print("=== memory_graph_person('Carlton') ===")
            print(text)
            assert "Carlton" in text, "Carlton not found in person result"

            # 3. A name the graph probably doesn't know — must still answer gracefully.
            r = await session.call_tool("memory_graph_person", {"name": "Zzzz-No-Such-Person"})
            text = r.content[0].text if r.content else ""
            print("=== memory_graph_person('Zzzz-No-Such-Person') ===")
            print(text[:200])

            # 4. Empty query — must return a clear error, not crash.
            r = await session.call_tool("memory_graph_query", {"query": ""})
            text = r.content[0].text if r.content else ""
            assert "query is required" in text.lower(), f"expected error, got: {text[:100]}"

            print("\nALL PASS")
            return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
