"""Per-agent session manager for the VERTUS hub.

Replaces the hub's single shared AgentBridge with one bridge per agent id:

    SessionManager(registry, factory)
        .get_or_create_session("primary")   -> bridge (created on first use)
        .get_or_create_session("scout")     -> a *different* bridge, own queue,
                                               own worker thread, own engine session

Properties:
  - Keyed by agent id; unknown ids raise KeyError (the hub maps that to 404
    using the registry, so /api/prompt and /api/events can't address agents
    that don't exist).
  - Lazy: a bridge (and its engine gateway) is only created the first time
    that agent is prompted or streamed — except the agent the manager is
    seeded with at startup (the primary), which the hub prewarms exactly like
    the old single-session hub so default clients see no cold-start change.
  - Thread-safe: the hub is a ThreadingHTTPServer; the keyed map is guarded
    by a lock. Concurrency comes from each bridge owning its own queue +
    worker, so two agents can be mid-prompt at the same time — there is no
    manager-level lock anywhere near the prompt path.
  - No hermes/gateway knowledge: the factory callable builds the bridge for
    an agent id (the hub passes AgentBridge; tests pass fakes).
  - Introspection without side effects: ``status(agent_id)`` reports the
    bridge's live state (or a never-built idle payload) WITHOUT creating a
    bridge — the hub's GET /api/agents/<id>/status endpoint never
    instantiates an engine as a side effect.
  - Deletion support: ``drop(agent_id)`` pops + closes a live bridge so a
    hub DELETE can tear an agent down without racing the worker.

Lock discipline (Step C) — this module participates in a documented global
order; see the module docstring of vertus_server.py for the full rules.
In short: the ONLY nested acquisition in the system is
SessionManager._lock → AgentRegistry._lock (inside get_or_create_session's
factory), and AgentRegistry never takes this lock, so no cycle exists.
Engine calls (bridge close/spawn/prompt) never happen while the map lock is
held — drop() pops under the lock, then closes outside it.

No network calls, no secrets. Prompt 3 will point each session's tools at
the agent's sandbox/ directory; this module only isolates sessions.
"""

from __future__ import annotations

import threading
from typing import Callable

DEFAULT_AGENT_ID = "primary"


class SessionManager:
    """Keyed, lazy, thread-safe map of agent_id -> bridge instance."""

    def __init__(
        self,
        registry,
        factory: Callable[[str], object],
        seed_agent_id: str = DEFAULT_AGENT_ID,
    ) -> None:
        """``factory(agent_id)`` builds the bridge for one agent.

        ``seed_agent_id`` is created eagerly at construction (the hub then
        prewarms it) so the default/primary flow behaves like the old
        single-session hub; every other agent is lazy.
        """
        self.registry = registry
        self._factory = factory
        self._lock = threading.Lock()
        self._sessions: dict[str, object] = {}
        self._sessions[seed_agent_id] = factory(seed_agent_id)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def get_or_create_session(self, agent_id: str):
        """Return the live bridge for ``agent_id``, creating it on first use.

        Raises KeyError when the registry doesn't know the agent (hub → 404).
        """
        agent_id = str(agent_id or DEFAULT_AGENT_ID).strip() or DEFAULT_AGENT_ID
        with self._lock:
            bridge = self._sessions.get(agent_id)
            if bridge is not None:
                return bridge
        # Validate outside the map lock; registry has its own lock. Unknown
        # ids raise KeyError before we ever build a bridge for them.
        self.registry.get_agent(agent_id)
        with self._lock:
            bridge = self._sessions.get(agent_id)
            if bridge is None:  # re-check: another thread may have won
                # Re-validate UNDER the map lock. A concurrent hub DELETE
                # removes the registry entry and THEN drops the map entry;
                # without this second check a prompt that validated just
                # before the delete could resurrect a zombie bridge for an
                # agent that no longer exists.
                self.registry.get_agent(agent_id)
                bridge = self._factory(agent_id)
                self._sessions[agent_id] = bridge
            return bridge

    def has_session(self, agent_id: str) -> bool:
        """True when a bridge already exists for this agent (no creation)."""
        agent_id = str(agent_id or DEFAULT_AGENT_ID).strip() or DEFAULT_AGENT_ID
        with self._lock:
            return agent_id in self._sessions

    def status(self, agent_id: str) -> dict:
        """Live turn state for an agent WITHOUT creating a bridge.

        An agent that has never been prompted/streamed has no bridge; it
        reports the canonical idle payload so callers (the hub's DELETE
        guard, GET /status) never instantiate an engine as a side effect.
        """
        agent_id = str(agent_id or DEFAULT_AGENT_ID).strip() or DEFAULT_AGENT_ID
        with self._lock:
            bridge = self._sessions.get(agent_id)
        if bridge is None:
            return {
                "state": "idle",
                "queue_depth": 0,
                "turn_started_at": None,
                "gateway_alive": False,
            }
        return bridge.status()

    def drop(self, agent_id: str) -> bool:
        """Close and forget an agent's live bridge, if any.

        Pops the bridge under the map lock, then closes it OUTSIDE the lock
        (closing talks to the engine). Returns True when a bridge existed.
        """
        agent_id = str(agent_id or DEFAULT_AGENT_ID).strip() or DEFAULT_AGENT_ID
        with self._lock:
            bridge = self._sessions.pop(agent_id, None)
        if bridge is not None:
            bridge.close()  # engine call; never under the map lock
        return bridge is not None

    def live_ids(self) -> list[str]:
        """Agent ids that currently hold a session (primary always included)."""
        with self._lock:
            return sorted(self._sessions)
