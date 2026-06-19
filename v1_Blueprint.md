# ALFRED — Ultimate Blueprint (synthesized v1)

## Context

This is a synthesis of four LLM-authored blueprints (ChatGPT, DeepSeek, KIMI, Perplexity)
for **ALFRED**, a privacy-first personal automation assistant for macOS. The goal was not
to merge all four but to keep the strongest ideas, resolve conflicts, and cut weak or
fantasy-scope material into a single implementation-ready plan.

**Decisions locked with the user:**
- **Stack:** Swift / SwiftUI native (macOS 14+). Not Python.
- **Local model:** A small on-device dispatcher model (Phi-2 / ~1–3B) whose job is to
  *analyze a task and route it* to local vs cloud — plus a "control the computer" capability.
- **v1 automations:** Files & folders, Text/document generation, Calendar, **and Email**.
- **Distribution:** Personal use only (sign locally, no App Store, no notarization).

The personal-use answer is load-bearing: it removes sandbox/notarization constraints,
makes AppleScript-to-Mail.app acceptable (KIMI deferred email only because of multi-user
breakage risk, which doesn't apply to one machine you can fix), and lets us use launchd,
global hotkeys, and full file access freely.

---

## 1. Product overview

ALFRED is an always-resident macOS **menu-bar assistant** (no Dock icon) with three surfaces:

- **AlfredBar** — a fast, dark, bottom-anchored command lane (`⌘⇧A`) for one-shot tasks.
- **Dashboard** — a full window for Routines, History/Logs, and Settings.
- **Background runner** — executes scheduled routines silently and notifies on completion.

Its defining qualities (kept from ChatGPT + Perplexity):
1. **Automation over chat** — the unit of value is a completed task, not a conversation.
2. **Transparency** — every action records *what ran, which model, why, and what data left the device.*
3. **Safe by default** — a policy engine classifies every command and gates anything destructive,
   sending, or cloud-bound.
4. **Local-first** — cloud is used only when the dispatcher decides it's needed and policy allows.

---

## 2. Core user flows

**A. One-shot command (AlfredBar)**
1. User hits `⌘⇧A` → bar slides up, focused.
2. Types natural language (e.g. "organize my Downloads by file type").
3. Local dispatcher model classifies → command class + route (local/cloud) + tool.
4. Policy engine checks: allowed? confirmation needed? cloud-sensitive?
5. If a write/send/destructive action → inline confirmation card. Read-only → runs immediately.
6. Result renders in the output area with a **Copy** button and a one-line routing explanation
   ("✓ Local — file operation, no sensitive content"). Input clears, ready for next command.

**B. Create a routine (Dashboard)**
1. Routines → "+" → modal: Title, Schedule (time + frequency), Action (NL prompt), Policy class.
2. Save → persisted to SQLite; scheduler picks it up.

**C. Scheduled routine fires (background)**
1. Scheduler detects a due, enabled routine.
2. Executes the prompt silently through the same engine as AlfredBar.
3. Writes a run record to the log; sends a typed notification (success / failure / permission-blocked).
4. Clicking the notification deep-links to that run's log entry.

**D. First-run onboarding** (from Perplexity)
Name → set/confirm hotkey → grant permissions (with explanations) → choose default mode
(local / cloud / ask) → create one sample routine → run a test command.

---

## 3. UI / UX specification

### Menu bar
- `NSStatusItem` with stylized "A" SF Symbol, dark/light adaptive.
- Click opens Dashboard (or brings to front via `NSApp.activate`).
- `LSUIElement = true` (no Dock icon). Launch at login via `SMAppService` (built-in, macOS 13+).

### AlfredBar
- **Window:** borderless `NSPanel`, `.floating` level, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` (works over full-screen apps).
- **Size:** width = 30% of screen, **max 800 px / min 400 px**; height auto-expands with output.
  (Resolves the 30%-vs-80% conflict — 80% is a chat window, not a command lane.)
- **Position:** horizontally centered, 20 px above the bottom edge.
- **Theme:** `#1E1E1E` bg, 12 px radius, subtle shadow; input white text, placeholder
  "Ask Alfred anything…"; trailing native `ProgressView()` spinner while working.
- **Show/hide:** slide 0.15 s; becomes key + first responder on show. Hide on `Esc`,
  click-outside (`windowDidResignKey`), or "close" command; restores prior app focus.
- **Output:** `ScrollView`, `#E0E0E0` text, ~120 px (≈5 lines) before scrolling. Each output
  block has a Copy button (`NSPasteboard` + transient "Copied!" overlay). Errors in `#FF453A`
  with a one-line suggestion and a "View Logs" button.
- **Routing line:** below each result — `✓ Local` / `☁ Gemini` + short reason (ChatGPT's
  transparency idea, kept).

### Dashboard
- `NSWindow`, title "Alfred", default 1000×700, min 900×650. Theme: `#1E1E1E` / `#FFFFFF`
  text / `#0A84FF` accent. Close = hide (does not quit); `⌘W`.
- **Sidebar (200 px):** Home · Routines · History · Settings. **No "Plugins"/placeholder
  sections** (Perplexity's discipline — only ship sections that exist).
- **Home:** rotating greeting ("Good morning, [Name]"), stats card ("Today: N routines, 0 errors"),
  recent actions list.
- **Routines:** list rows (title, next-run time, last-run status ✅/❌/⏳, enable toggle);
  "+" to create; click to edit via `.sheet` modal.
- **History/Logs:** table (timestamp, title, mode, status, output summary); filter by routine/status;
  click to expand full output + routing explanation + error text; export to `.txt`.
  Also reachable via AlfredBar command "show last routine results" (Perplexity).
- **Settings:** see §7.

---

## 4. Architecture

```text
            ┌────────────┐      ┌────────────┐
  ⌘⇧A ───▶  │ AlfredBar  │      │ launchd    │  RunAtLoad + KeepAlive
            └─────┬──────┘      │ (keep-alive│  keeps ALFRED resident
 menu bar ─▶ Dashboard          │  agent)    │
            └─────┬──────┘      └─────┬──────┘
                  │  same engine      │ relaunch
                  ▼                   ▼
        ┌───────────────────────────────────┐
        │        Execution Engine           │
        │  ┌──────────────┐  ┌────────────┐ │
        │  │ Dispatcher   │  │ Policy     │ │
        │  │ (local 1-3B) │─▶│ Engine     │ │  ← classify + route, THEN gate
        │  └──────────────┘  └─────┬──────┘ │
        │            ┌─────────────┴──────┐ │
        │            ▼                    ▼ │
        │      Local model           Cloud (Gemini)
        │            └──────┬─────────────┘ │
        │                   ▼               │
        │            Tool / Capability layer│
        │  Files · Calendar · Email · TextGen · (Computer-control, gated)
        └───────────────┬───────────────────┘
                        ▼
        Redaction → SQLite log → Notifications
```

### Two-stage brain (synthesis of the user's dispatcher idea + Perplexity's policy split)

This is the key architectural decision. **The dispatcher proposes; the policy engine disposes.**
Safety must NOT depend on a 1–3B model being correct.

- **Stage 1 — Dispatcher (local, Phi-2 / ~1–3B via Ollama on localhost for v1; MLX-Swift later):**
  Classifies the command into (a) a **command class**, (b) a **route** (handle locally / escalate
  to cloud), (c) the **tool** to use, and (d) flags likely sensitive content. Fast, always on-device.
- **Stage 2 — Policy engine (deterministic rules, NOT the model):** Takes the dispatcher's proposal
  and applies a fixed rule table per command class. Deterministic regex/keyword checks for
  cloud-sensitive content run here, independent of the model, so a wrong dispatcher call can't leak data.

**Command classes (Perplexity, kept verbatim as the safety backbone):**

| Class | Examples | Default behavior |
|---|---|---|
| Read-only | summarize emails, list events | Run immediately |
| Low-risk write | create file, add calendar event | Run (optional confirm setting) |
| High-risk write | delete files, send email, modify many items | **Always confirm** |
| Cloud-sensitive | content matching redaction patterns | Redact, or block if privacy mode |
| Unattended-safe | routine-eligible subset | Allowed to run headless |

### Why this matters for "control the computer completely"
The user wants ALFRED to be able to control the Mac. **A 1–3B model cannot safely plan and
drive multi-step computer control** — it's competent at classification/routing, not autonomous
agency. Therefore:
- The small model is scoped to **routing + intent classification + redaction-flagging only.**
- Actual multi-step planning for computer-control tasks is done by the **cloud model**, and every
  proposed step passes through the policy engine. Read-only steps may auto-run; any write/destructive
  step requires confirmation (or is pre-approved per session for trusted task types).
- **Full unrestricted computer control (arbitrary shell / arbitrary AppleScript) is a gated Phase 2
  capability**, off by default, behind an explicit permission. v1 ships the 4 concrete automations
  plus the foundation (policy engine, confirmations, audit log) that makes Phase 2 safe.

### Stack
- Swift 5.9+/SwiftUI, macOS 14+ target. AppKit only where SwiftUI is insufficient (`NSPanel`, `NSStatusItem`).
- **SPM dependencies** (from KIMI, trimmed):
  - `sindresorhus/KeyboardShortcuts` — global hotkey (Carbon `RegisterEventHotKey`; no Accessibility permission needed).
  - `groue/GRDB.swift` — SQLite.
  - `kishikawakatsumi/KeychainAccess` — secrets.
  - Native `URLSession` for Gemini + localhost Ollama (drop Alamofire — unnecessary).
  - Native `ServiceManagement` (`SMAppService`) for launch-at-login (drop LaunchAtLoginModern — built-in now).

---

## 5. Data model

Single SQLite DB at `~/Library/Application Support/Alfred/alfred.sqlite` (GRDB).
Secrets in **Keychain only** (service `com.alfred.apikey`). Settings in `settings.json` (non-sensitive)
or a `settings` table — pick one; recommend the table for queryability.

**routines** (expanded per Perplexity for migration-safety):
```json
{
  "id": "uuid",
  "version": 1,
  "title": "Morning Email Summary",
  "prompt_text": "Summarize unread emails from the last 24h",
  "schedule_cron": "0 6 * * *",
  "timezone": "America/New_York",
  "enabled": true,
  "policy_class": "unattended-safe",
  "last_run_at": "ISO8601",
  "next_run_at": "ISO8601",
  "last_status": "success | failed | blocked",
  "last_output_summary": "…"
}
```

**runs** (the log; SQLite, not JSON — ChatGPT's correct call over DeepSeek's JSON):
`id, routine_id (nullable for AlfredBar runs), source (bar|routine), prompt, started_at,
finished_at, model_used (local|gemini), route_reason, command_class, status, output_full,
output_summary, error_text, data_sent_to_cloud (bool/redaction summary)`.

**settings:** `user_name, default_mode (local|cloud|ask), privacy_mode, cloud_provider,
global_hotkey, launch_at_login, redact_patterns[], confirm_high_risk (always-on), …`

**suggestions** (for the deferred learning system — table reserved, not populated in v1):
`id, pattern, frequency, suggested_prompt, status (new|accepted|dismissed)`.

---

## 6. Scheduling / background behavior

**Resolution of the in-app-timer vs launchd conflict (the most important reliability decision):**

- **One launchd LaunchAgent** (`~/Library/LaunchAgents/com.alfred.agent.plist`) with
  `RunAtLoad=true` + `KeepAlive=true`. Its only job is to **keep ALFRED resident** — it relaunches
  ALFRED after reboot (RunAtLoad) and after a crash (KeepAlive). This gives reboot + crash survival
  with a single plist.
- **ALFRED's internal scheduler** (60 s tick) does the actual cron evaluation against the `routines`
  table and executes due routines. Precise, simple, all logic in Swift.
- "Quit ALFRED" unloads the agent (otherwise KeepAlive would relaunch it); relaunching from menu
  bar reloads it.

This is cleaner than KIMI's one-plist-per-routine (which gets noisy and requires
`launchctl load/unload` per edit) while keeping its reboot-survival guarantee. KIMI's per-routine
approach remains the fallback if you ever want routines to fire while ALFRED is fully quit.

**Execution rules:**
- Routines run silently in a background `Task`; never steal focus or open UI.
- Serialize concurrent routine execution on one queue to avoid file/Calendar races (KIMI).
- A routine firing while AlfredBar is open runs anyway, in the background (DeepSeek's choice B).
- **Failure handling (simplified from KIMI):** retry once after ~10 s for network errors; on final
  failure mark `status=failed`, store error, send failure notification, allow manual re-run from
  History. (Drop the formal "dead-letter queue" — over-engineered for a single-user tool.)
- Only `unattended-safe` routines may run headless. A routine whose action resolves to a high-risk
  write notifies "permission-blocked, open to confirm" rather than executing unattended.

---

## 7. Safety and permissions

**Permissions strategy (Perplexity, kept):** first-run checklist that detects missing permissions,
explains *why* each is needed, links straight to the relevant System Settings pane, and lets ALFRED
run in **reduced mode** if denied.

macOS permissions needed:
- **Notifications** — routine alerts.
- **Calendar (EventKit)** — `EKEventStore` request; handle `denied` gracefully.
- **Automation/AppleScript** — for Mail.app control (email), prompted on first use.
- **Files** — security-scoped bookmarks via `NSOpenPanel` for folders outside the app container;
  store bookmark data, don't assume full-disk access. (KIMI.)
- **Global hotkey** — via KeyboardShortcuts; does NOT need Accessibility. Must fail gracefully and
  warn if another app owns the shortcut (Perplexity). Configurable from day one.

**Privacy / redaction (KIMI + Perplexity):**
- Redaction is **mandatory and lives in the policy layer**, not in individual tools. Default patterns
  (`password.*`, `ssn`, `credit.?card`) are non-removable; users may add more. Matches → `[REDACTED]`
  in Swift, in-process, before any network call.
- **Privacy mode** = cloud fully disabled; any command the dispatcher would route to cloud must run
  local or prompt the user to change settings (never silently send).
- Every cloud request logs exactly what (redacted) payload left the device.

**Confirmation model:** high-risk writes (delete, send email, bulk modify) always confirm. Email
**send** specifically requires confirmation; drafting does not. Calendar add can be configured to
skip confirmation.

---

## 8. Logging and observability

- Every AlfredBar command and every routine run writes a `runs` record (full audit trail — ChatGPT).
- Each record captures the **transparency triple**: model used, route reason, command class — surfaced
  both inline (AlfredBar) and in History.
- **Standardized notifications (Perplexity):** distinct formats for success / failure / permission-blocked;
  success click deep-links to the exact run entry.
- History is filterable by routine and status; full output expandable; export to `.txt`.

---

## 9. MVP scope (v1)

**In:**
- Menu-bar app, no Dock icon, launch at login.
- AlfredBar (slide animation, input, output, copy, inline routing line, error display).
- Dashboard: Home, Routines (CRUD + enable), History/Logs, Settings.
- launchd keep-alive agent + internal 60 s scheduler; silent execution; typed notifications.
- **Two-stage brain:** local dispatcher (Ollama + Phi-2/1–3B) → deterministic policy engine →
  local or Gemini cloud.
- **4 automations:** Files & folders (security-scoped bookmarks), Calendar (EventKit, no AppleScript),
  Text/document generation (LLM → file), Email (Mail.app AppleScript bridge — read/summarize/draft;
  **send gated**).
- Keychain for the Gemini key; SQLite for everything else; mandatory redaction; privacy mode.
- First-run onboarding (6 steps).
- Reboot test as an explicit acceptance criterion.

**Explicitly cut from v1 (and why):**
- **Learning/suggestions system** (ChatGPT) → best product idea, hardest to do well. Reserve the
  `suggestions` table; build after the core loop is proven (Phase 2/3).
- **Embedding-based "smart router"** (ChatGPT/DeepSeek) → the local dispatcher model + policy engine
  covers v1. Defer until there's evidence the explicit approach is insufficient.
- **Full/unrestricted computer control** (arbitrary shell/AppleScript) → gated Phase 2 capability.
- **Spreadsheets, slide decks, iMessage** (ChatGPT/DeepSeek) → fragile/heavy; later.
- **Multi-provider cloud** (OpenAI/Anthropic), Markdown rendering, advanced cron UI → later.
- **App Store sandboxing / notarization** → not needed (personal use).

---

## 10. Future phases

- **Phase 2 — Polish + capability:** Markdown rendering in AlfredBar; History export/filter polish;
  gated computer-control capability (cloud-planned, policy-gated, per-step confirmation);
  begin populating the learning/suggestions system.
- **Phase 3 — More automations:** spreadsheets, slide decks, iMessage; richer email (IMAP/Gmail API
  as a robustness upgrade over AppleScript if needed).
- **Phase 4 — Smarter routing + providers:** embedding router (Core ML/MLX), multi-provider cloud,
  conversation memory.
- **Phase 5 (optional):** integrated on-device capable model (MLX-Swift) replacing the Ollama
  dependency; broader distribution (would require revisiting sandbox/notarization).

---

## 11. Open risks and assumptions

**Risks:**
1. **Small dispatcher model reliability.** Phi-2/1B routing decisions will be imperfect. Mitigated by
   the deterministic policy engine + regex redaction (safety never depends on the model). Still, expect
   misroutes; build a quick manual override (`local:` / `cloud:` prefixes from KIMI) as an escape hatch.
2. **"Control the computer" expectations vs reality.** Autonomous multi-step control needs the cloud
   model and is genuinely risky on a live machine. Scoped to gated Phase 2; v1 builds the guardrails first.
3. **Mail.app AppleScript fragility.** Acceptable for personal use (you can fix breakage), but it *will*
   break across macOS updates. IMAP/Gmail-API is the Phase 3 hardening path.
4. **Ollama dependency.** Requires Ollama installed/running for the local dispatcher in v1. Onboarding
   must check for it and guide install, or fall back to cloud-only with a clear message.
5. **launchd KeepAlive UX.** "Always resident" means Quit must explicitly unload the agent or the app
   appears un-quittable.

**Assumptions:**
- Apple Silicon Mac (for reasonable local-model latency).
- macOS 14+ (Sonoma) for modern SwiftUI/SMAppService APIs.
- Email provider works through Mail.app (account already configured there).
- Single user, single machine — security bar is "protect against accidents + cloud leakage," not
  multi-tenant hardening.

---

## 12. Final recommendation

**Honest assessment.** ALFRED is a strong, coherent product idea once the fantasy scope is cut. KIMI's
engineering + Perplexity's policy/safety model + ChatGPT's transparency UX, on Swift, for one user, is
very buildable. The two things that can sink it are (a) over-trusting a 1–3B model to "control the
computer," and (b) the email/AppleScript fragility — both are managed above by scoping and gating.

**Build first (in order):**
1. Menu-bar shell + AlfredBar + Dashboard skeleton (no automation yet) — prove the surfaces.
2. Execution engine with the **two-stage brain** wired to Gemini + Ollama, plus the policy engine and
   `runs` logging — prove routing + transparency + audit.
3. The **safest two automations first: Files and Text-generation** (self-contained, low blast radius).
4. **Calendar (EventKit)**, then **Email (read/summarize/draft, send gated)**.
5. **Routines + launchd keep-alive + notifications**, validated by a **reboot test**.
6. Onboarding last, once the happy path works.

**Cut (don't build in v1):** learning/suggestions, embedding smart router, unrestricted computer
control, spreadsheets/slides/iMessage, multi-provider cloud, sandboxing.

**Biggest risks, ranked:** (1) dispatcher misrouting → mitigated by deterministic policy + manual
prefixes; (2) computer-control safety → gated to Phase 2; (3) Mail AppleScript breakage → personal-use
acceptable, IMAP later; (4) Ollama setup friction → onboarding check + cloud fallback.

---

## Verification

- **Build/run:** menu-bar icon appears, no Dock icon, `⌘⇧A` toggles AlfredBar over any space
  including full-screen apps.
- **Engine:** a read-only command runs immediately; a high-risk command (delete/send) shows a
  confirmation; a cloud-sensitive command redacts before send (inspect the logged `data_sent_to_cloud`).
- **Each automation:** create/move a file via bookmarks; create a Calendar event via EventKit;
  generate + save a document; summarize email via Mail.app (and confirm send is gated).
- **Routine + reboot test:** create a routine for ~2 min out, confirm silent execution + typed
  notification + deep-link to its log; then **reboot and confirm a scheduled routine still fires**.
- **Secrets:** confirm the Gemini key is in Keychain and never written to `alfred.sqlite`/`settings.json`.
- **Privacy mode:** enable it, issue a cloud-bound command, confirm it stays local or prompts (never silently sends).
