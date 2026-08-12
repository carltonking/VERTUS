#!/usr/bin/env python3
"""Smoke-test every MCP server registered in the agent-bridge config.

Launches each server from the live config (or the repo example), completes the
MCP stdio handshake (initialize → notifications/initialized → tools/list), and
prints a pass/fail table. Exits nonzero if any server fails, so it can gate a
release checklist or CI.

Usage:
    python3 smoke_test_servers.py                  # live config (~/.alfred/agent-servers.json)
    python3 smoke_test_servers.py --config agent-servers.example.json
    python3 smoke_test_servers.py --server graphiti --server memory-graph
    python3 smoke_test_servers.py --json           # machine-readable summary
    python3 smoke_test_servers.py --timeout 60     # per-request timeout in seconds
    python3 smoke_test_servers.py --concurrency 4  # run up to 4 servers at once

A server "passes" if it answers tools/list — the backing service (FalkorDB,
agentmemory…) does not need to be up, since the question is whether
the bridge itself boots and speaks MCP. Backing-service health is checked by
`./setup.sh --status` instead.
"""
import argparse
import asyncio
import json
import os
import signal
import sys
import time

DEFAULT_CONFIG = os.path.expanduser("~/.alfred/agent-servers.json")
REPO_EXAMPLE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "agent-servers.example.json")


def load_servers(config_path: str) -> list[dict]:
    """Read the servers array from the given config file. Falls back to the
    repo example when the live file is missing (fresh machine, CI).

    Raises FileNotFoundError for an explicit --config that doesn't exist — the
    caller turns that into a clean usage error rather than a traceback."""
    path = config_path or (DEFAULT_CONFIG if os.path.exists(DEFAULT_CONFIG) else REPO_EXAMPLE)
    with open(path) as f:
        data = json.load(f)
    return data.get("servers", [])


class ServerResult:
    def __init__(self, name: str):
        self.name = name
        self.ok = False
        self.tool_count = 0
        self.error = ""
        self.stderr_tail = ""

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "ok": self.ok,
            "tools": self.tool_count,
            "error": self.error,
        }


async def read_frame(proc, expected_id: int, timeout: float) -> dict:
    """Read newline-delimited JSON frames until the one with `expected_id`.

    Some bridges log stray lines to stdout before the real frames (wrappers
    echoing "starting…", npx progress). Those aren't valid JSON frames, so
    skip anything that doesn't parse rather than failing the handshake on it.
    """
    assert proc.stdout is not None
    while True:
        try:
            line = await asyncio.wait_for(proc.stdout.readline(), timeout=timeout)
        except asyncio.TimeoutError:
            raise TimeoutError(f"no response in {timeout:.0f}s")
        if not line:
            raise EOFError("server closed stdout")
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue  # stray stdout log line, not a frame
        if obj.get("id") == expected_id:
            return obj
        # Tolerate servers that echo ids as strings ("1" instead of 1) — a
        # strict int compare would loop until timeout on a healthy server.
        if isinstance(obj.get("id"), str) and obj["id"].lstrip("-").isdigit():
            if int(obj["id"]) == expected_id:
                return obj


async def smoke_server(name: str, command: str, args: list[str], env: dict, timeout: float) -> ServerResult:
    result = ServerResult(name)
    # The config's `env` is a list of {"name","value"} pairs merged over the
    # inherited environment (the agent inherits Alfred's session env too).
    proc_env = os.environ.copy()
    for pair in env:
        if isinstance(pair, dict) and pair.get("name") and pair.get("value") is not None:
            proc_env[pair["name"]] = str(pair["value"])

    try:
        proc = await asyncio.create_subprocess_exec(
            command, *args,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=proc_env,
            # Own process group, so cleanup can kill the whole tree — npx and
            # node wrapper servers (agentmemory) leave a child holding the
            # pipes; killing just the parent would hang wait() forever.
            start_new_session=True,
        )
    except FileNotFoundError as e:
        result.error = f"command not found: {command}"
        return result
    except Exception as e:  # noqa: BLE001 — a launch failure is just a failed server
        result.error = f"launch failed: {e}"
        return result

    assert proc.stdin is not None

    async def kill_tree() -> None:
        """SIGKILL the server and everything it spawned. Bounded — if the kill
        itself wedges (zombie group), don't hang the whole run."""
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except Exception:  # noqa: BLE001 — best-effort cleanup
            try:
                proc.kill()
            except ProcessLookupError:
                pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=5)
        except (asyncio.TimeoutError, ProcessLookupError):
            pass

    async def send(obj: dict) -> None:
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        await proc.stdin.drain()

    try:
        # 1. initialize.
        await send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "smoke-test", "version": "0.1"},
        }})
        init = await read_frame(proc, 1, timeout)
        if "error" in init:
            raise RuntimeError(f"initialize failed: {json.dumps(init['error'])[:200]}")

        # 1b. initialized notification (some servers gate tools/list on it).
        await send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

        # 2. tools/list — the actual pass/fail gate.
        await send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = await read_frame(proc, 2, timeout)
        tool_list = tools.get("result", {}).get("tools", [])
        result.tool_count = len(tool_list)
        result.ok = True
    except asyncio.CancelledError:
        await kill_tree()
        raise
    except Exception as e:  # noqa: BLE001 — any handshake failure is reported per-server
        result.error = str(e)
    finally:
        await kill_tree()
        if result.error:
            try:
                err = (await asyncio.wait_for(proc.stderr.read(), timeout=5)).decode(errors="replace").strip()
            except Exception:  # noqa: BLE001 — stderr is best-effort
                err = ""
            result.stderr_tail = err[-600:] if err else ""

    return result


async def run_all(servers: list[dict], timeout: float, json_mode: bool = False,
                   concurrency: int = 1) -> list[ServerResult]:
    """Smoke-test every server, at most `concurrency` at a time.

    Sequential (concurrency == 1) keeps the familiar numbered pass in config
    order. Parallel uses a semaphore so slow bridges (graphiti, browser-use)
    overlap instead of serialising the whole run; each line still prints as its
    server finishes, so fast results surface immediately rather than waiting
    on the slowest. The returned list is always in config order — JSON output
    and the exit code don't depend on finish order.
    """
    # In --json mode progress goes to stderr so stdout carries only the JSON
    # summary (clean for CI to parse).
    out = sys.stderr if json_mode else sys.stdout
    total = len(servers)
    results: dict[int, ServerResult] = {}
    semaphore = asyncio.Semaphore(max(1, concurrency))

    async def test_one(index: int, server: dict) -> None:
        name = server.get("name") or f"<unnamed #{index}>"
        async with semaphore:
            started = time.monotonic()
            result = await smoke_server(
                name,
                server.get("command", ""),
                server.get("args", []) or [],
                server.get("env", []) or [],
                timeout,
            )
            elapsed = time.monotonic() - started
        results[index] = result
        # One write per line so concurrent tasks never interleave mid-line.
        if result.ok:
            out.write(f"  [{index:2d}/{total:2d}] {name} … OK ({result.tool_count} tools, {elapsed:.1f}s)\n")
        else:
            out.write(f"  [{index:2d}/{total:2d}] {name} … FAIL ({elapsed:.1f}s)\n")
        out.flush()

    await asyncio.gather(*(test_one(i, s) for i, s in enumerate(servers, 1)))
    return [results[i] for i in range(1, total + 1)]


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test all agent-bridge MCP servers")
    parser.add_argument("--config", default=None, help="config file to read (default: live config, else repo example)")
    parser.add_argument("--server", action="append", default=[], help="only test these server names (repeatable)")
    parser.add_argument("--timeout", type=float, default=60.0, help="per-request timeout in seconds (default 60)")
    parser.add_argument("--concurrency", type=int, default=1,
                        help="run up to N servers at once (default 1 = sequential)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable summary instead of prose")
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error("--concurrency must be >= 1")

    try:
        servers = load_servers(args.config)
    except FileNotFoundError:
        print(f"error: config file not found: {args.config}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f"error: config file is not valid JSON: {e}", file=sys.stderr)
        return 2
    if args.server:
        wanted = set(args.server)
        servers = [s for s in servers if s.get("name") in wanted]
        missing = wanted - {s.get("name") for s in servers}
        if missing:
            if not servers:
                print(f"error: no servers found for: {', '.join(sorted(missing))}", file=sys.stderr)
                return 2
            # Partial miss: some names matched, so keep going — but say so,
            # because a typo silently shrinking coverage defeats the point.
            print(f"warning: no servers found for: {', '.join(sorted(missing))}", file=sys.stderr)

    if not args.json:
        if args.concurrency > 1:
            print(f"Smoke-testing {len(servers)} MCP server(s)… (concurrently, {args.concurrency} at a time)")
        else:
            print(f"Smoke-testing {len(servers)} MCP server(s)…")
    results = asyncio.run(run_all(servers, args.timeout,
                                  json_mode=args.json, concurrency=args.concurrency))

    passed = [r for r in results if r.ok]
    failed = [r for r in results if not r.ok]

    if args.json:
        print(json.dumps({
            "total": len(results),
            "passed": len(passed),
            "failed": len(failed),
            "servers": [r.as_dict() for r in results],
        }, indent=2))
    else:
        print()
        print(f"Result: {len(passed)}/{len(results)} OK")
        for r in failed:
            print(f"\n✗ {r.name}: {r.error}")
            if r.stderr_tail:
                print(f"  stderr tail: {r.stderr_tail}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
