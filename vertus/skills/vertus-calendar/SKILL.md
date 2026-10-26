---
name: vertus-calendar
description: Read the user's calendars and add or cancel events with the vertus-events tool.
---

# Calendar

Use the **terminal** tool with `~/.vertus/agent/bin/vertus-events`. Dates are
`YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` (local time) — never words like "today":
work out the date first (`date +%F`).

```
~/.vertus/agent/bin/vertus-events list-calendars
~/.vertus/agent/bin/vertus-events events --from 2026-10-26 --to 2026-10-27
~/.vertus/agent/bin/vertus-events create-event --title "Dinner with Sam" --start 2026-10-27T19:00 --end 2026-10-27T21:00 [--location "…"] [--notes "…"] [--calendar VERTUS]
~/.vertus/agent/bin/vertus-events cancel-event --id <event id from events>
```

- Read every calendar freely. Create events in the `VERTUS` calendar unless the
  user names another (`ensure-calendar --name VERTUS` creates it once).
- Before creating, check that day's events and say so if it clashes.
- Cancelling an event asks the user first (the guard handles that); creating
  one does not, but always confirm what you created: title, day, time.
- In a text conversation keep replies short: one line per event.
