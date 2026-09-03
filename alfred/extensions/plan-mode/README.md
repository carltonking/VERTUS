# Plan Mode

A read-only operating state for ALFRED: it can analyze your codebase, search
files, and reason through a problem, but it cannot modify any files or run
state-changing commands.

## Usage

```
/plan-mode          toggle
/plan-mode on       force ON
/plan-mode off      force OFF
/plan-mode status   show current state
```

`Ctrl+Alt+P` also toggles. New sessions start OFF (pass `--plan-mode` at
launch to start ON). **Nothing is written to the session window or
transcript** — the state shows only in the footer badge underneath the prompt
bar, immediately to the **right of the context percentage**
(`… CH95.4% 95.4%/1.0M (auto) plan-mode: ON …`) — bold warning color while
ON, dimmed while OFF — via a custom footer (`setFooter`) that replicates the
built-in one (usage, cache rate, context %, model/thinking, git branch,
extension statuses). It re-registers on every `session_start` so it survives
`/new`, `/fork`, and `/reload`, and falls back to a minimal badge-only line
if its captured context goes stale mid-session. State persists across
`/reload` and session resume.

## Toggling mid-session (the model always knows)

The mode is enforced in code, not in the model's head — but the model is kept
informed so it never has to guess or probe the filesystem:

- While **ON**, every turn is prefixed with a hidden
  `[plan-mode: ACTIVE — READ-ONLY]` notice describing the restrictions.
- While **OFF**, after a toggle (or resume from an ON-era transcript), the
  next turn carries a hidden `[plan-mode: OFF — FULL WRITE ACCESS]` notice
  that explicitly supersedes any older ACTIVE notices — once, not every turn.
- Before every LLM call, older/duplicate plan-mode notices are stripped so
  exactly one — the newest matching the current state — survives. Legacy
  `[PLAN MODE ACTIVE]` notices from older sessions are recognized and cleaned
  up too.

So toggling ON/OFF mid-session takes effect for the model on its very next
turn, and stale "you are read-only" history can't confuse it after toggling
off.

## What it restricts while ON

1. **Write tools removed** — `edit`, `write`, and `powershell` are dropped
   from the active tool set, along with every write-capable custom tool on
   this install (email send/compose, calendar mutations, all browser
   interaction). `read`, `grep`, `find`, `ls`, web search/fetch, and the
   email/calendar readers stay available.
2. **bash, heavily guarded** — bash stays enabled because analysis often
   needs it, but every command is classified as read-only or not:
   - Allowed: reading/inspecting files (`cat`, `head`, `grep`, `rg`, `find`,
     `ls`, `wc`, `diff`, `jq`, `stat`…), pipes and redirections to
     `/dev/null` and fd dups (`2>/dev/null`, `2>&1`), read-only `git`
     subcommands (`status`, `log`, `diff`, `show`, `branch`, `blame`…),
     read-only `npm`/`gh`/`kubectl`/`docker`/`defaults` queries,
     `sed -n`, plain `curl`, and shell loops/keywords whose bodies are
     themselves read-only.
   - Blocked (examples): writes/redirects to files, `rm`, `mv`, `cp`,
     `mkdir`, `touch`, `tee`, `sed` without `-n`, `sed -i`, `git checkout`
     or any state-changing git subcommand, package installs, `osascript`,
     shells (`bash`/`sh`/`zsh` as commands), process substitution, and
     command substitution whose inner command isn't itself read-only.
   - Blocked commands return a reason and the suggestion to toggle plan
     mode off — nothing is executed.
3. **System reminder each turn** — the hidden ACTIVE notice (above) tells
   the model it is in plan mode so it reasons and proposes instead of
   acting. A `tool_call` hook hard-blocks anything that slips past the tool
   gate (e.g. tools registered after plan mode was enabled).

## State storage

A `plan-mode-state` custom entry (newest wins) records the toggle for
`/reload` and resume; brand-new sessions start OFF unless `--plan-mode` is
passed.
