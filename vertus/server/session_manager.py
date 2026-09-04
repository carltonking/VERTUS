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
                bridge = self._factory(agent_id)
                self._sessions[agent_id] = bridge
            return bridge

    def has_session(self, agent_id: str) -> bool:
        """True when a bridge already exists for this agent (no creation)."""
        with self._lock:
            return agent_id in self._sessions

    def live_ids(self) -> list[str]:
        """Agent ids that currently hold a session (primary always included)."""
        with self._lock:
            return sorted(self._sessions)
