"""Fleet-wide per-target screen ownership (per-window computer-use policy).

Step 0C of the per-agent computer-use audit measured the fork's cua-driver
concurrency empirically: two gateway processes driving DIFFERENT windows
succeed in parallel with zero interference (the real cursor never moves and
the frontmost app is undisturbed), while the driver itself refuses
background keyboard input when a target pid owns several top-level windows.
The justified policy is therefore PER-WINDOW OWNERSHIP, not a fleet-wide
GUI lease: agents never contend on distinct windows, so only the SAME
target must be exclusive.

Enforcement granularity — stated plainly: the hub cannot observe which
window an agent drives mid-turn (gateway ``tool.start`` events carry the
tool NAME only, never args) and cannot inject into a running turn, so
ownership is enforced at the only point the hub controls: the boundary
between a queued turn and its start. Each agent declares the app bundle
ids / window titles it works in via ``profile.cua_targets``; a run whose
declared targets OVERLAP another RUNNING agent's declaration WAITS (FIFO)
until that run reaches a terminal state, its gateway dies, or the agent is
deleted. Disjoint or null declarations run immediately, fully parallel.
Text-only agents and unrestricted CUA agents (``cua_targets`` null) never
claim and never contend.

Coarse by necessity: a turn is assumed GUI-bound when its agent declares
targets, so a pure-text prompt to a target-declared agent will queue behind
a co-tenant of the same target. That is the documented cost of enforcing
without a fork change (the declaration IS the GUI intent).

ENFORCEMENT HONESTY: ``cua_targets`` is a DECLARATION, not a sandbox. An
agent can drive a window it never declared and the hub cannot see it —
this registry only prevents the predictable collision of two declared
co-tenants. It provides no isolation.

Caveat surfaced verbatim in GET /api/fleet/screens and the UI.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field

# Shown in /api/fleet/screens and the fleet UI. The declaration gates only
# declared-target collisions; it is not a sandbox and not per-action consent.
SCREEN_POLICY_CAVEAT = (
    "cua_targets is a DECLARATION, not a sandbox: it only prevents two "
    "agents from running turns that declare the same app/window at once. "
    "The hub cannot see which window an agent actually drives mid-turn, and "
    "an agent can target something it never declared. This policy provides "
    "no isolation — real isolation needs a VM or headless display per agent."
)


@dataclass
class _Waiter:
    agent_id: str
    run_id: str
    targets: tuple[str, ...]
    granted: threading.Event = field(default_factory=threading.Event)
    _granted_flag: bool = False

    def grant(self) -> None:
        self._granted_flag = True
        self.granted.set()


class ScreenLeaseManager:
    """Per-target lease registry with FIFO waiters.

    Thread-safe. ``acquire``/``release`` are called from each agent's bridge
    worker thread (one turn at a time per agent); grants happen only while
    holding the manager lock, so two workers can never both own one target.
    All state is in-memory: a hub restart clears every lease (any running
    gateway died with it), which is correct — there is nothing to inherit.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        # target -> (agent_id, run_id, since_epoch)
        self._leases: dict[str, tuple[str, str, float]] = {}
        # FIFO waiters awaiting targets (insertion order = fairness order).
        self._waiters: list[_Waiter] = []

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def acquire(self, agent_id: str, run_id: str, targets: list[str] | None) -> bool:
        """Try to claim every declared target for this run.

        Returns True immediately when the agent declares no targets (or all
        are free) — the run may start. Returns False when any target is held
        by another agent's run; the caller must then block on
        ``wait_for_grant`` and retry, so no partial claim ever sticks.
        """
        clean = self._clean_targets(targets)
        if not clean:
            return True
        with self._lock:
            if all(t not in self._leases for t in clean):
                now = time.time()
                for t in clean:
                    self._leases[t] = (agent_id, run_id, now)
                return True
            return False

    def wait_for_grant(self, agent_id: str, run_id: str, targets: list[str] | None,
                       timeout: float = 0.5) -> list[str] | None:
        """Block until every declared target is owned by this agent/run.

        Registers a FIFO waiter (once) and sleeps on its grant event. Returns
        the owned targets on grant, or None on timeout — the caller re-loops
        so it can notice bridge close without blocking forever. The grant
        loop only ever leases to waiters whose events it sets, so a returned
        non-None always means ownership was actually transferred.
        """
        clean = self._clean_targets(targets)
        if not clean:
            return []
        with self._lock:
            if not any(w.agent_id == agent_id and w.run_id == run_id for w in self._waiters):
                self._waiters.append(_Waiter(agent_id, run_id, tuple(clean)))
            waiter = next(w for w in self._waiters if w.agent_id == agent_id and w.run_id == run_id)
            # Someone may have freed everything between the failed acquire and
            # this registration — grant in FIFO position right now.
            self._try_grant_in_order()
            if waiter._granted_flag:
                return list(clean)
        waiter.granted.wait(timeout)
        return list(clean) if waiter._granted_flag else None

    def cancel_wait(self, agent_id: str, run_id: str) -> bool:
        """Drop this run's waiter entry (bridge closed while waiting).

        Returns True when an entry was removed; False when the run was
        already granted (then the caller owns the leases and must release
        them itself).
        """
        with self._lock:
            before = len(self._waiters)
            self._waiters = [
                w for w in self._waiters if not (w.agent_id == agent_id and w.run_id == run_id)
            ]
            removed = len(self._waiters) < before
            if removed:
                self._try_grant_in_order()
            return removed

    def release(self, agent_id: str, run_id: str, targets: list[str] | None) -> None:
        """Drop this run's leases on its declared targets, then grant FIFO waiters."""
        clean = self._clean_targets(targets)
        if not clean:
            return
        with self._lock:
            for t in clean:
                holder = self._leases.get(t)
                if holder is not None and holder[0] == agent_id and holder[1] == run_id:
                    del self._leases[t]
            self._try_grant_in_order()

    def release_agent(self, agent_id: str) -> None:
        """Drop every lease held by one agent (run ended / agent deleted)."""
        with self._lock:
            for t in [t for t, (a, _r, _s) in self._leases.items() if a == agent_id]:
                del self._leases[t]
            # Waiters for a deleted agent can never be granted — drop them.
            self._waiters = [w for w in self._waiters if w.agent_id != agent_id]
            self._try_grant_in_order()

    def owners(self) -> dict[str, tuple[str, str, float]]:
        """Live leases: target -> (agent_id, run_id, since_epoch)."""
        with self._lock:
            return dict(self._leases)

    def blocked_by(self, agent_id: str) -> list[dict]:
        """For a waiting agent, the target → holder pairs it is blocked on.

        Each entry: ``{target, holder_agent, holder_run}``. Empty when the
        agent is not currently a waiter (or nothing it wants is leased).
        """
        with self._lock:
            for w in self._waiters:
                if w.agent_id != agent_id:
                    continue
                out: list[dict] = []
                for t in w.targets:
                    holder = self._leases.get(t)
                    if holder is not None and holder[0] != agent_id:
                        out.append({
                            "target": t,
                            "holder_agent": holder[0],
                            "holder_run": holder[1],
                        })
                return out
            return []

    def blocked(self) -> list[dict]:
        """Every waiter with the target/holder pair it is blocked on."""
        with self._lock:
            out: list[dict] = []
            for w in self._waiters:
                for t in w.targets:
                    holder = self._leases.get(t)
                    if holder is not None and holder[0] != w.agent_id:
                        out.append({
                            "agent_id": w.agent_id,
                            "run_id": w.run_id,
                            "target": t,
                            "holder_agent": holder[0],
                            "holder_run": holder[1],
                        })
            return out

    def is_waiting(self, agent_id: str) -> bool:
        with self._lock:
            return any(w.agent_id == agent_id for w in self._waiters)

    # ------------------------------------------------------------------
    # Internals (callers hold self._lock)
    # ------------------------------------------------------------------

    @staticmethod
    def _clean_targets(targets: list[str] | None) -> list[str]:
        if not targets:
            return []
        seen: dict[str, None] = {}
        for t in targets:
            if isinstance(t, str) and t.strip():
                seen[t.strip()] = None
        return list(seen)

    def _try_grant_in_order(self) -> None:
        """Grant the oldest waiters whose targets are ALL free (FIFO).

        Called after every release/registration. A waiter is granted only
        when every target it declared is simultaneously unleased — this is
        the ordered-allocation rule that makes partial-claim deadlock
        impossible (a head-of-line waiter holding one target of a set while
        waiting for another can starve behind it, which is the documented
        cost of all-or-nothing allocation).
        """
        remaining: list[_Waiter] = []
        for waiter in self._waiters:
            if all(t not in self._leases for t in waiter.targets):
                now = time.time()
                for t in waiter.targets:
                    self._leases[t] = (waiter.agent_id, waiter.run_id, now)
                waiter.grant()
            else:
                remaining.append(waiter)
        self._waiters = remaining
