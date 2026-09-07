"""Automatic turn-end memory capture for the VERTUS hub (qm-style).

qm's memory design is core-driven: the engine extracts durable facts at turn
end (never trusting the model to remember to write notes) and recalls a capped
digest into context. This module ports the capture half into vertus' hub-owned
file store:

    run done (worker thread)
      └─ on_run_done → burst buffer (per agent/thread, quiet window, turn cap)
           └─ flush (background thread, never blocks the run worker)
                ├─ fetch the run's folded user/assistant messages from the store
                ├─ one-shot extraction completion through the fork's own venv
                │  (fork_probe.py — the same provider machinery the doctor probes)
                └─ fold facts into canonical facts.md via MemoryStore.capture_facts
                   (agent scope; "SHARED:"-prefixed facts → shared scope)

Best-effort by design: extraction failure, a dead provider, a missing store —
all log-and-skip. Capture never touches the run's event stream, never fails a
run, and never blocks a worker (flush runs on its own daemon thread).

Policy: per-agent ``memory_capture`` profile field ("automatic" default, "off"
disables) plus a hub-wide ``VERTUS_MEMORY_CAPTURE=0`` kill switch. Autonomous
turns (bot messages, handoffs, routines) use the autonomous extraction
addendum: operational facts only, never preferences about a person.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path

try:
    import vertus_paths  # type: ignore
    from fleet_memory import parse_facts_text  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore
    from .fleet_memory import parse_facts_text  # type: ignore

# A fact that should apply fleet-wide (a preference or instruction about the
# user that every VERTUS agent should honor) is marked with this prefix by the
# extractor and routed to the SHARED scope; the prefix is stripped on write.
SHARED_PREFIX = "SHARED:"

# qm's per-turn defaults: gather consecutive exchanges, flush 3 minutes after
# the last one (or sooner when the burst reaches the turn cap).
DEFAULT_CAPTURE_QUIET_MS = 180_000
DEFAULT_CAPTURE_MAX_TURNS = 10

# Bounded inputs so the extraction call can never balloon.
TRANSCRIPT_MAX_CHARS = 12_000
EXTRACTION_MAX_TOKENS = 600
EXTRACTION_TIMEOUT_S = 30.0

EXTRACTION_SYSTEM_PROMPT = (
    "You extract durable facts worth remembering about the user across FUTURE conversations.\n"
    "Given one or more consecutive exchanges (user message + assistant reply), output ONLY a "
    "markdown bullet list (`- fact`), one concise standalone fact per line, written in the third "
    "person (e.g. `- Prefers terse replies`, `- Owns the billing service`, `- Working on the Q3 "
    "launch`). Include preferences, identifiers, ongoing projects, and how they like to work.\n"
    "PROVENANCE: a preference, intent, or instruction is a valid fact ONLY when the user's own "
    "message in these exchanges states it. Never derive one from the assistant's reply — an "
    "assistant saying \"per X's preference\" or describing its own strategy is NOT evidence that "
    "anyone holds that preference. Likewise EXCLUDE second-hand claims about a person who did not "
    "speak in these exchanges.\n"
    "EXCLUDE secrets/credentials, one-off trivia, and anything already obvious.\n"
    "EXCLUDE system mechanics you can look up when needed: API endpoints/headers, credential or "
    "broker plumbing, state-file paths, tool invocation details, schemas.\n"
    "SCOPE ROUTING: a fact that should apply FLEET-WIDE — a preference or instruction about the "
    "user that every VERTUS agent should honor (\"always use pnpm\", the user's timezone) — must "
    "start with `SHARED: ` before the fact text. Everything else stays private to this agent.\n"
    "If nothing is worth remembering, output exactly: NONE"
)

AUTONOMOUS_EXTRACTION_ADDENDUM = (
    "\n\nThese exchanges are AUTONOMOUS turns: no human spoke. The \"User said\" content is a "
    "system or bot trigger and the reply is the assistant working alone. Record only operational "
    "facts (state, blockers, queues, outcomes). Output NO preference/intent/instruction facts "
    "about any person; when only such facts appear, output exactly: NONE"
)


def classify_fact(fact: str) -> tuple[str, bool]:
    """(fact_text, shared?) — a leading SHARED: marker routes to the shared
    scope and is stripped from what is stored."""
    text = str(fact).strip()
    if text.upper().startswith(SHARED_PREFIX):
        return text[len(SHARED_PREFIX):].strip(), True
    return text, False


def _read_home_model(home: Path) -> tuple[str | None, str | None]:
    """model.default/provider from ONE engine home's config.yaml, or None.
    Mirrors vertus_doctor._read_home_model (the materialized per-agent home
    config carries the effective model/provider, fleet default included)."""
    cfg_path = home / "config.yaml"
    if not cfg_path.is_file():
        return None, None
    try:
        from agent_registry import _yaml_load  # type: ignore
        cfg = _yaml_load(cfg_path.read_text(encoding="utf-8"))
        if not isinstance(cfg, dict):
            return None, None
        model_section = cfg.get("model") or {}
        if not isinstance(model_section, dict):
            return None, None
        return (
            str(model_section["default"]) if model_section.get("default") else None,
            str(model_section["provider"]) if model_section.get("provider") else None,
        )
    except Exception:
        return None, None


def fork_extract_facts(agent_home: Path, transcript: str,
                       autonomous: bool) -> list[str]:
    """One-shot fact extraction through the fork's venv (fork_probe.py): the
    agent's own model/provider/key, retry-free, bounded. Any failure → []."""
    try:
        from fork_probe import run_completion  # type: ignore
    except ImportError:  # pragma: no cover - only hit under package invocation
        from .fork_probe import run_completion  # type: ignore
    model, provider = _read_home_model(agent_home)
    if not model or not provider:
        return []
    system = EXTRACTION_SYSTEM_PROMPT + (
        AUTONOMOUS_EXTRACTION_ADDENDUM if autonomous else "")
    res = run_completion(
        {"provider": provider, "model": model, "home": agent_home},
        EXTRACTION_TIMEOUT_S,
        system=system,
        user=transcript[:TRANSCRIPT_MAX_CHARS],
        max_tokens=EXTRACTION_MAX_TOKENS,
    )
    if not res.get("ok"):
        return []
    return parse_facts_text(res.get("text") or "")


class MemoryCapturer:
    """Burst-buffered, best-effort capture of durable facts at run end.

    ``store_provider`` / ``memory_provider`` are callables resolving the
    RunStore / MemoryStore at FLUSH time (construction order in serve() makes
    direct references impossible). ``extract(agent_id, transcript,
    autonomous) -> list[str]`` defaults to fork_extract_facts via the agent's
    home; tests inject fakes so no subprocess ever spawns.
    """

    def __init__(self, store_provider, memory_provider, registry,
                 extract=None, quiet_ms: float = DEFAULT_CAPTURE_QUIET_MS,
                 max_turns: int = DEFAULT_CAPTURE_MAX_TURNS,
                 log=print):
        self._store = store_provider
        self._memory = memory_provider
        self._registry = registry
        self._extract = extract
        self._quiet_ms = float(quiet_ms)
        self._max_turns = max(1, int(max_turns))
        self._log = log
        self._lock = threading.Lock()
        self._bursts: dict[str, dict] = {}
        self._timers: dict[str, threading.Timer] = {}

    # -- policy ------------------------------------------------------------

    def enabled(self, agent_id: str) -> bool:
        """Per-agent profile field (default automatic) + global kill switch."""
        if os.environ.get("VERTUS_MEMORY_CAPTURE") == "0":
            return False
        try:
            agent = self._registry.get_agent(agent_id)
        except (KeyError, TypeError, ValueError):
            return False
        return (agent.get("memory_capture") or "automatic") != "off"

    # -- run-terminal hook (worker thread; must never block) ---------------

    def on_run_done(self, run_id: str, agent_id: str,
                    from_agent: str | None, thread_id: str | None,
                    run_kind: str, state: str) -> None:
        """Called by AgentBridge._end_run for every terminal run. Only
        completed turns capture; everything after this point runs on a
        background thread."""
        if state != "done":
            return
        if not self.enabled(agent_id):
            return
        key = f"{agent_id}\0{from_agent or ''}\0{thread_id or ''}"
        flush_now = False
        with self._lock:
            burst = self._bursts.get(key)
            if burst is None:
                burst = {
                    "agent_id": agent_id,
                    "from_agent": from_agent,
                    "thread_id": thread_id,
                    "run_kind": run_kind,
                    "runs": [],
                }
                self._bursts[key] = burst
            burst["runs"].append(run_id)
            if len(burst["runs"]) >= self._max_turns:
                self._bursts.pop(key, None)
                self._cancel_timer_locked(key)
                flush_now = True
            else:
                self._reset_timer_locked(key, burst)
        if flush_now:
            threading.Thread(target=self._flush, args=(burst,),
                             daemon=True).start()

    # -- burst buffer --------------------------------------------------------

    def _cancel_timer_locked(self, key: str) -> None:
        timer = self._timers.pop(key, None)
        if timer is not None:
            timer.cancel()

    def _reset_timer_locked(self, key: str, burst: dict) -> None:
        self._cancel_timer_locked(key)
        timer = threading.Timer(self._quiet_ms / 1000.0,
                                self._flush, args=(burst,))
        timer.daemon = True
        self._timers[key] = timer
        timer.start()

    def _flush(self, burst: dict) -> None:
        """One burst: fetch folded messages, extract, fold into facts.md.
        Best-effort — any failure logs and skips; never raises into a
        timer/worker thread."""
        try:
            with self._lock:
                self._timers.pop(self._burst_key(burst), None)
            pairs = self._message_pairs(burst["runs"])
            if not pairs:
                return
            transcript = "\n\n---\n\n".join(
                f"User said:\n{u}\n\nAssistant replied:\n{a}"
                for u, a in pairs
            )
            autonomous = bool(burst["from_agent"]) or burst["run_kind"] in (
                "routine", "message", "handoff")
            extract = self._extract or self._default_extract
            facts = extract(burst["agent_id"], transcript, autonomous)
            if not facts:
                return
            memory = self._memory()
            if memory is None:
                return
            at = time.time()
            private: list[str] = []
            shared: list[str] = []
            for fact in facts:
                text, is_shared = classify_fact(fact)
                if text:
                    (shared if is_shared else private).append(text)
            added = 0
            if private:
                added += memory.capture_facts(
                    "agent", burst["agent_id"], private,
                    writer=burst["agent_id"], at=at)
            if shared:
                added += memory.capture_facts(
                    "shared", None, shared, writer=burst["agent_id"], at=at)
            if added:
                self._log(f"[vertus] captured {added} fact(s) for agent "
                          f"{burst['agent_id']}")
        except Exception as exc:  # noqa: BLE001 — capture is best-effort
            try:
                self._log(f"[vertus] memory capture failed: {exc}",
                          file=sys.stderr)
            except Exception:
                pass

    @staticmethod
    def _burst_key(burst: dict) -> str:
        return f"{burst['agent_id']}\0{burst.get('from_agent') or ''}\0" \
               f"{burst.get('thread_id') or ''}"

    def _message_pairs(self, run_ids: list[str]) -> list[tuple[str, str]]:
        """(user, assistant) folded text per run, in run order. A run with
        neither message (or a store that vanished) contributes nothing."""
        store = self._store()
        if store is None:
            return []
        pairs: list[tuple[str, str]] = []
        for run_id in run_ids:
            try:
                msgs = store.run_messages(run_id)
            except Exception:
                continue
            user = next((str(m.get("text") or "") for m in msgs
                         if m.get("role") == "user"), "")
            assistant = next((str(m.get("text") or "") for m in reversed(msgs)
                              if m.get("role") == "assistant"), "")
            if user or assistant:
                pairs.append((user, assistant))
        return pairs

    # -- default extractor ---------------------------------------------------

    def _default_extract(self, agent_id: str, transcript: str,
                         autonomous: bool) -> list[str]:
        """fork_extract_facts with the agent's own engine home (its resolved
        model/provider + .env keys)."""
        try:
            agent = self._registry.get_agent(agent_id)
        except (KeyError, TypeError, ValueError):
            return []
        home = agent.get("home_path")
        if not home:
            return []
        return fork_extract_facts(Path(home), transcript, autonomous)