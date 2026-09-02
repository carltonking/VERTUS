# ALFRED iCloud Extension — Calendar + Email

Gives ALFRED access to the calendars and email already configured on this Mac
(your iCloud account plus any others — school Exchange, Gmail, …). No passwords
or tokens are stored; macOS handles authorization per account.

## What it provides

| Tool | What it does |
|---|---|
| `list_calendars` | List all calendars (iCloud, Exchange, …) — read-only |
| `read_calendar_events` | Events in a date range with id/title/start/end/location/notes |
| `create_calendar_event` | Create an event **only** in the dedicated `ALFRED` calendar (+ default 10 min reminder) |
| `cancel_calendar_event` | Cancel an event **only** from the `ALFRED` calendar (by id) |
| `list_emails` | Recent email from a mailbox (default INBOX) — read-only |
| `search_emails` | Search subject/sender/body — read-only |
| `read_email` | Full plain-text body of one message by id — read-only |
| `compose_email` | Create a draft (never sends) — lets you review before sending |
| `send_draft` | Send a composed draft by id (only on your explicit confirmation) |
| `send_email` | Send immediately (only when you explicitly ask to send now) |

## Safety model

- **Calendar mutations are sandboxed in native code** (`src/alfred-events.swift`):
  create/cancel hard-refuse any calendar other than the dedicated **ALFRED**
  calendar, which is auto-created on first use. The agent can read your real
  calendars but can never write to them.
- **Email sending requires your confirmation** — ALFRED is instructed to use
  `compose_email` by default; `send_draft`/`send_email` only with explicit
  consent. Nothing is sent automatically.

## First-time setup (one time, ~30 seconds)

1. Restart ALFRED (or run `/reload`) so the extension loads.
2. Ask ALFRED to use your calendar — macOS will show a **Calendar access**
   prompt. Click **Allow**.
   - Missed it? System Settings → Privacy & Security → Calendar → enable the
     app that runs your terminal.
3. Ask ALFRED to read your mail — macOS will show a **Mail automation** prompt.
   Click **OK** (control Mail).
   - Missed it? System Settings → Privacy & Security → Automation → enable
     control of Mail for the app that runs your terminal.
4. Run `/icloud-status` to verify everything (helper build, calendar access,
   mail access).

## Configuration

`~/.pi/agent/icloud.json`:

```json
{ "calendarName": "ALFRED" }
```

Rename the value to any calendar you're happy to hand ALFRED — it is
auto-created and is the only calendar ALFRED can write to.

## How it works

- **Calendar**: a small [EventKit](https://developer.apple.com/documentation/eventkit)
  CLI compiled once on first use (`swiftc -O -o ~/.pi/agent/bin/alfred-events …`);
  it sees everything Calendar.app sees, including both your iCloud and school
  Exchange accounts.
- **Email**: Apple Mail automation via `osascript -l JavaScript`. Mail must be
  usable on this Mac (it can run in the background; the script opens it if needed).

## Rebuild / update

- Recompile the helper: `rm ~/.pi/agent/bin/alfred-events` (it rebuilds on next
  use from this package's `src/alfred-events.swift`).
- Update the extension: copy this directory to `~/.pi/agent/extensions/icloud`
  and `/reload`.