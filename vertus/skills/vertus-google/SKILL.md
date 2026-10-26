---
name: vertus-google
description: USE THIS whenever the user wants to connect, link or sign in to Google, Gmail, Google Calendar or Drive. Sends them a one-tap sign-in link. Do not use google-workspace setup.py or any "connector" for connecting.
---

# Connect a Google account (one tap)

The hub runs the whole Google sign-in. You only fetch a link and text it.

1. Run with the terminal tool:
   `curl -s -H "Authorization: Bearer $(cat ~/.vertus/token)" http://127.0.0.1:8787/api/connect/google`
2. It prints `{"url": "https://…"}`. Reply with exactly:
   "Tap to connect your Google account: <url>" — nothing else is needed from
   the user; they pick the account on their phone and approve.
3. If it prints `{"error": …}`, tell the user that message in one line.

The link works once and expires in 15 minutes; send a fresh one if asked again.
To connect another account, send another link. After connecting, use the
google-workspace skill's `google_api.py` commands to read Gmail and manage
Google Calendar and Drive.
