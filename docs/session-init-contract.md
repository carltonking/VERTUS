# Session Init Contract — Alfred ↔ engine handshake

Defines the single JSON `init` record the Alfred client passes when starting an
engine session, so every session mode is explicit, versioned, and measurable.
This is engine-agnostic in spirit (Hermes via `hermes acp`, ACP RPC) and is
shipped together with the vendored engine so the two can never drift.

## 1. Current state (the baseline this contract formalizes)

Today the app starts **one** kind of session (HermesSession.swift):
`hermes acp` — a JSON-RPC 2.0 process over stdio — with no explicit mode
record. It inherits the default `config.yaml`: model `qwen3:4b`, provider
custom local endpoint (`127.0.0.1:11434`), all default tool sets
(`agent.disabled_toolsets` trims). That single session type is what this
contract names **BOT**.

The handshake is enriched, not replaced: the client sends one JSON line on
session start; the engine's `--dev`/`acp` path reads `ALFRED_INIT` (env) or
the `init` field of the first request. Behavior for missing/malformed init =
behave as BOT (backwards compatible).

## 2. Init record

```jsonc
{
  "schema": 1,
  "mode": "BOT",                 // one of: BOT (default), obs, norm, helm
  "engine": "hermes",            // engine id: hermes | opencode …
  "model": "qwen3:4b",           // resolves against config; "" = default
  "toolsets": [],                // override tool set list; [] = config default
  "session_id": "",              // pass-through for session continuity
  "readonly": false,             // hard guarantee when true (client enforces)
  "initiated_at": "ISO8601"      // metrics + staleness
}
```

## 3. Modes

| mode | purpose | model / tools | latency target (calm turn) | notes |
|------|---------|---------------|----------------------------|-------|
| **BOT** | today's session; full agent, does things | `qwen3:4b` + full tool set | ~90s (measured, after prompt trims) | default; backwards compatible; only mode used today |
| **obs** | observation / monitoring / watchers; reports, never mutates | `qwen3:4b` + read-only tools (file read, web read, memory recall) | same model, shorter turns | `readonly: true` hard-enforced by client; no write/browser-action tools exposed |
| **norm** | a plain interactive turn (alias of BOT minus the long-lived loop) | same as BOT | ~90s | for one-shot `hermes -z` invocations |
| **helm** | steering commander: routes mid-turn steer/override messages, tiny non-blocking jobs | small/fast model (see §4) + minimal tool set | < 30s | the only mode that may run a 1B-class model — never a full tool schema |

## 4. Measured latency physics (2026-08-10, this Mac, qwen3:4b @ 100% GPU)

Prefill dominates calm-turn latency; it is model-bound, not engine-bound.

| model | prefill (6k tokens) | ~full 14k-token prompt turn |
|-------|--------------------|------------------------------|
| `qwen3:4b` (default) | 162 tok/s | ~90–130 s |
| `llama3.2:1b` | 529 tok/s | ~25 s (but drifts on tool schemas) |
| `qwen2.5-coder:1.5b` | 601 tok/s | fast (drifts on tool schemas) |
| `alfred-coder:latest` | 753 tok/s | fast (see caveat) |

Caveats that keep small models OUT of BOT/norm for now:
- 1B / 1.5B coders emit malformed tool calls against the full/trimmed tool
  schemas ("Say ok." → fictional `write_file`/fenced JSON), even with a single
  tool set (`-t file`). Do not route presence/calm turns through them with
  tools enabled.
- `alfred-coder:latest` reports a 4,096-token window via hermes' model lookup
  despite Ollama advertising 32,768 (add `model.context_length: 32768` under
  its provider entry to fix) — currently REJECTED by hermes (<32K guard).

## 5. Rules / invariants

1. A session with `mode: BOT|norm` must never select a sub-32K-context or
   tool-drift-prone model. `helm` and `obs` may, with `readonly: true` set.
2. `readonly: true` is enforced client-side (tools not offered), never
   trusted to the model's good behavior.
3. Config toggles live in `config.yaml`; the contract only carries the
   per-session override.
4. The engine MUST behave identically with no init record (legacy callers
   degrade to BOT).
5. Latency targets are advisory; the authoritative numbers come from the
   calm test (see project memory).

## 6. Status / open items

Validated 2026-08-10 (direct Ollama, 6k-token context, temperature 0.1):

| route | result | latency |
|-------|--------|---------|
| zero tools + strict "speech-only, never call tools/JSON" system prompt | clean "ok" on ALL of llama3.2:1b / qwen2.5-coder:1.5b / alfred-coder-32k | 3.9s / 4.0s / <1s |
| one tool offered (same strict system) | llama3.2:1b breaks (empty/garbage); qwen2.5-coder:1.5b & alfred-coder-32k stay clean | same |

- `alfred-coder-32k:latest` — derived tag of `alfred-coder:latest` (same
  weights, `num_ctx 32768` instead of the Modelfile's 4096), passes Hermes'
  32K guard; root cause of 4096 was the repo Modelfile (`PARAMETER num_ctx
  4096`, deliberate VRAM pin — raise there if the original tag is ever
  repointed).
- Consequence: obs/helm act on a **tool-less** hermes session (no tool
  schemas present) with a speech-only system; small models are clean and fast
  there. llama3.2:1b must NEVER see a tool schema.

- [x] Validate small-model + zero-tool route produces clean, fast turns.
- [x] Provide a guard-passing fast model: `alfred-coder-32k` (derived tag).
- [x] Wire `ALFRED_INIT` emission from HermesSession (BOT) with
      `mode`, `session_id`, `initiated_at` — `childEnvironment()` in
      HermesSession.swift injects it for hermes/prime-agent (task→BOT,
      readonly→obs); compiles, inert today.
- [x] Add a smoke assert in `build_hermes_engine.sh` — init-present vs
      init-absent runs are byte-identical (BOT degradation enforced); the
      full "honor" assert is gated on engine-side ALFRED_INIT support.
- [ ] Engine-side work (deferred): honor `ALFRED_INIT` in the fork's acp
      path, and a zero-tool toolset/flag (`-t speech` → no schemas) so a
      tool-less session is expressible through hermes itself.
