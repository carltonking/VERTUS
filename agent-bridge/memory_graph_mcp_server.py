"""
memory_graph_mcp_server.py

MCP stdio server giving Hermes one tool that searches BOTH memory stores at
once when asked about people, organizations, or relationships:

  * agentmemory  — the persistent coding-agent memory (hybrid BM25 + vector +
                   graph) at REST :3111, full of observations/memories.
  * graphiti     — the temporal knowledge graph in FalkorDB (Docker container
                   alfred-graphiti-falkordb, graph "alfred"), holding named
                   entities (Person/Organization/Topic/…) and RELATES_TO
                   relationship facts between them.

Rather than spawning graphiti's own MCP server (a ~heavy python process with a
slow cold start), this server queries FalkorDB directly over redis — the graph
is already running on 127.0.0.1:6379, and the Cypher below matches graphiti's
own schema (Entity nodes with .name/.summary, RELATES_TO edges with .fact).
agentmemory is queried over its documented REST API, the same endpoints the
hermes plugin and Alfred's AgentMemoryClient use.

Tools:
  memory_graph_query(query, limit)   — merged search: entities + relationships
                                       from graphiti, memories from agentmemory.
  memory_graph_person(name)          — deep dive on one person/entity: profile,
                                       every relationship in/out, memories
                                       mentioning them.

Both stores are best-effort: if one is down the other still answers, and each
section names its source so the caller can tell which store it came from.

Run standalone (for testing):  python3 memory_graph_mcp_server.py
Registered by Alfred via ~/.alfred/agent-servers.json.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

server = Server("memory-graph")

# ---------------------------------------------------------------------------
# Backends
# ---------------------------------------------------------------------------

AGENTMEMORY_URL = "http://localhost:3111"
FALKORDB_HOST = "127.0.0.1"
FALKORDB_PORT = 6379
FALKORDB_GRAPH = "alfred"

_redis_client: Any = None


def _get_redis():
    """Lazy, memoised redis client for FalkorDB. Imported inside the function
    so the server still boots when redis isn't installed (the mcp SDK is the
    only hard dependency; the rest is best-effort per call)."""
    global _redis_client
    if _redis_client is not None:
        return _redis_client
    import redis  # system python3 has redis 7.4.0
    candidate = redis.Redis(
        host=FALKORDB_HOST,
        port=FALKORDB_PORT,
        decode_responses=True,
        socket_timeout=3,
        socket_connect_timeout=3,
    )
    candidate.ping()  # raises if unreachable — only memoize a live client
    _redis_client = candidate
    return _redis_client


def _graphiti_healthy() -> bool:
    """Probe the graphiti store so callers can say 'unreachable' explicitly
    instead of silently returning no graph sections."""
    try:
        _get_redis()
        return True
    except Exception:
        return False


def _graph_query(query: str) -> list[list[Any]]:
    """Run Cypher against graphiti's FalkorDB graph and return the data rows.
    Result shape from GRAPH.QUERY is [header, rows, stats]; rows is a list of
    value-lists. Never raises for a running store — returns [] on any failure."""
    try:
        client = _get_redis()
        raw = client.execute_command("GRAPH.QUERY", FALKORDB_GRAPH, query)
        if not isinstance(raw, list) or len(raw) < 2:
            return []
        rows = raw[1]
        return [r for r in rows if isinstance(r, list)] if rows else []
    except Exception:
        return []


def _agentmemory_search(query: str, limit: int) -> dict:
    """POST /agentmemory/smart-search — hybrid semantic + keyword + graph
    search, the same endpoint the hermes plugin and AgentMemoryClient use.
    Returns {"ok": bool, "results": [..]} and never raises."""
    import urllib.request
    body = json.dumps({"query": query, "limit": limit}).encode()
    req = urllib.request.Request(
        f"{AGENTMEMORY_URL}/agentmemory/smart-search",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            payload = json.loads(resp.read().decode())
        results = payload.get("results") or payload.get("memories") or []
        return {"ok": True, "results": results}
    except Exception:
        return {"ok": False, "results": []}


def _fmt_agentmemory(result: dict) -> str:
    """One line per memory: title + type + timestamp (narrative when present)."""
    obs = result.get("observation") or result
    title = obs.get("title") or obs.get("content") or obs.get("text") or ""
    ntype = obs.get("type") or ""
    ts = (obs.get("timestamp") or "")[:10]
    narrative = obs.get("narrative") or ""
    line = title if not narrative else f"{title} — {narrative[:180]}"
    line = line.replace("\n", " ").strip()
    return f"- {line}" + (f"  [{ntype} {ts}]" if (ntype or ts) else "")


# ---------------------------------------------------------------------------
# Graphiti queries
# ---------------------------------------------------------------------------

def _cypher_string(value: str) -> str:
    """Escape a user string for interpolation into a Cypher string literal.
    FalkorDB 1.x accepts parameterised queries, but this server's tiny helper
    doesn't pass params — so values are interpolated literally, and must be
    escaped (quotes, backslashes, control chars) to stay a single safe string."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace("'", "\\'")
        .replace('"', '\\"')
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("\0", " ")
    )
    return f"'{escaped}'"


def _labels_to_kind(labels: Any) -> str:
    """The most specific label: FalkorDB returns labels as a JSON-ish string
    like '[Entity, Person]' or a real list — pick the label that isn't the
    generic 'Entity' base."""
    if isinstance(labels, list):
        items = [str(l) for l in labels]
    else:
        items = [s.strip() for s in str(labels).strip("[]").split(",") if s.strip()]
    return next((l for l in items if l != "Entity"), items[0] if items else "Entity")


def _graphiti_entities(query: str, limit: int) -> list[dict]:
    rows = _graph_query(
        f"MATCH (n:Entity) WHERE toLower(n.name) CONTAINS toLower({_cypher_string(query)}) "
        f"RETURN n.name, labels(n), n.summary LIMIT {max(1, min(int(limit), 30))}",
    )
    out = []
    for r in rows:
        out.append({"name": r[0], "kind": _labels_to_kind(r[1]), "summary": (r[2] or "").strip()})
    return out


def _graphiti_relationships(query: str, limit: int) -> list[dict]:
    q = _cypher_string(query)
    rows = _graph_query(
        f"MATCH (a)-[r:RELATES_TO]->(b) "
        f"WHERE toLower(a.name) CONTAINS toLower({q}) "
        f"OR toLower(b.name) CONTAINS toLower({q}) "
        f"RETURN a.name, b.name, r.fact LIMIT {max(1, min(int(limit), 30))}",
    )
    return [
        {
            "source": r[0],
            "target": r[1],
            "fact": (r[2] or "").replace("\n", " ").strip(),
        }
        for r in rows
    ]


def _graphiti_person(name: str) -> dict:
    """Profile + every relationship (in and out) for one entity."""
    q = _cypher_string(name)
    entity_rows = _graph_query(
        f"MATCH (n:Entity) WHERE toLower(n.name) = toLower({q}) "
        f"RETURN n.name, labels(n), n.summary LIMIT 1",
    )
    profile = None
    if entity_rows:
        profile = {
            "name": entity_rows[0][0],
            "kind": _labels_to_kind(entity_rows[0][1]),
            "summary": (entity_rows[0][2] or "").strip(),
        }
    rel_rows = _graph_query(
        f"MATCH (a)-[r:RELATES_TO]->(b) "
        f"WHERE toLower(a.name) = toLower({q}) OR toLower(b.name) = toLower({q}) "
        f"RETURN a.name, b.name, r.fact LIMIT 30",
    )
    relationships = [
        {
            "source": r[0],
            "target": r[1],
            "fact": (r[2] or "").replace("\n", " ").strip(),
        }
        for r in rel_rows
    ]
    return {"profile": profile, "relationships": relationships}


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def _run_query(query: str, limit: int) -> str:
    query = query.strip()
    if not query:
        return "Error: query is required."

    sections: list[str] = []

    # graphiti — entities and relationship facts matching the name. The query
    # helpers never raise (they swallow store errors and return []), so the
    # store's liveness is probed explicitly to distinguish "no data" from
    # "graphiti is down" in the reply.
    graphiti_up = _graphiti_healthy()
    entities = _graphiti_entities(query, limit)
    relationships = _graphiti_relationships(query, limit)

    if graphiti_up:
        if entities:
            lines = [f"- {e['name']} [{e['kind']}]" + (f": {e['summary'][:160]}" if e["summary"] else "")
                     for e in entities]
            sections.append("[graphiti] entities:\n" + "\n".join(lines))
        if relationships:
            lines = [f"- {r['source']} → {r['target']}" + (f": {r['fact'][:160]}" if r["fact"] else "")
                     for r in relationships]
            sections.append("[graphiti] relationships:\n" + "\n".join(lines))
        if not entities and not relationships:
            sections.append("[graphiti] no matching entities or relationships in the graph")
    else:
        sections.append("[graphiti] store unreachable (is FalkorDB running on :6379?)")

    # agentmemory — hybrid search over observations/memories.
    mem = _agentmemory_search(query, limit)
    if mem["ok"] and mem["results"]:
        lines = [_fmt_agentmemory(r) for r in mem["results"]]
        sections.append("[agentmemory] memories:\n" + "\n".join(lines))
    elif mem["ok"]:
        sections.append("[agentmemory] no memories matched (store healthy)")
    else:
        sections.append("[agentmemory] store unreachable (is agentmemory running on :3111?)")

    if not sections:
        return f"No results for \"{query}\" in either store."
    return "\n\n".join(sections)


def _run_person(name: str) -> str:
    name = name.strip()
    if not name:
        return "Error: name is required."

    data = _graphiti_person(name)
    sections: list[str] = []

    profile = data["profile"]
    if profile:
        header = f"{profile['name']} [{profile['kind']}]"
        if profile["summary"]:
            header += f"\n{profile['summary']}"
        sections.append(header)
    else:
        sections.append(f"No graphiti entity found for \"{name}\" (the graph may not have met them yet).")

    rels = data["relationships"]
    if rels:
        lines = []
        for r in rels:
            # The arrow always points source → target; render from the queried
            # person's side so "Carlton → Alfred" reads the same way the
            # graph stores it, whatever side of the edge the person is on.
            if r["source"].lower() == name.lower():
                lines.append(f"- {r['source']} → {r['target']}" + (f": {r['fact'][:180]}" if r["fact"] else ""))
            else:
                lines.append(f"- {r['source']} → {r['target']} (incoming to {name})" + (f": {r['fact'][:180]}" if r["fact"] else ""))
        sections.append("relationships:\n" + "\n".join(lines))
    else:
        sections.append("No relationship edges found for this entity yet.")

    # agentmemory memories about the person.
    mem = _agentmemory_search(name, 8)
    if mem["ok"] and mem["results"]:
        lines = [_fmt_agentmemory(r) for r in mem["results"]]
        sections.append("[agentmemory] memories:\n" + "\n".join(lines))
    elif mem["ok"]:
        sections.append("[agentmemory] no memories matched (store healthy)")
    else:
        sections.append("[agentmemory] store unreachable (is agentmemory running on :3111?)")

    return "\n\n".join(sections)


# ---------------------------------------------------------------------------
# MCP surface
# ---------------------------------------------------------------------------

@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="memory_graph_query",
            description=(
                "Search Alfred's combined memory graph — agentmemory (persistent observations) "
                "and graphiti (temporal knowledge graph with named people, organizations and "
                "relationship facts) — in one call. Use when the user asks about a person, who "
                "someone is, what someone works on, how two people/entities are related, or any "
                "relationship/fact about a named person or organization. Returns matching "
                "entities, RELATES_TO relationship facts, and relevant memories, each labeled "
                "with its source store."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The person, organization, or relationship to search for (e.g. \"Carlton\", \"who is Sarah\", \"what does Alex work on\").",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max results per store. Default 6.",
                    },
                },
                "required": ["query"],
            },
        ),
        Tool(
            name="memory_graph_person",
            description=(
                "Deep dive on ONE person or entity in Alfred's memory graph: their stored "
                "profile/summary (if the graph knows them), every relationship edge in or out "
                "(who they work with, work on, prefer, etc.), and agentmemory memories "
                "mentioning them. Use for 'tell me about X' / 'what do you know about X' when "
                "the subject is a specific person or organization."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "The person's or entity's name (e.g. \"Carlton\", \"Alfred\").",
                    },
                },
                "required": ["name"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "memory_graph_query":
        query = arguments.get("query", "")
        limit = max(1, min(int(arguments.get("limit", 6)), 30))
        return [TextContent(type="text", text=_run_query(query, limit))]
    if name == "memory_graph_person":
        return [TextContent(type="text", text=_run_person(arguments.get("name", "")))]
    return [TextContent(type="text", text=f"Unknown tool: {name}")]


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
