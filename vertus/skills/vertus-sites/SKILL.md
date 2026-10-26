---
name: vertus-sites
description: Build a small web page (a plan, a comparison, a dashboard, a mockup) and send the user a link to open it on their phone.
---

# Websites for the user to view

When the user asks for something better seen than read — a trip plan, a
comparison table, a landing-page draft, a chart — build a self-contained page
and send them the link.

1. Pick a folder name: a short slug plus 8 random characters, e.g.
   `lisbon-trip-k3f9q2xa` (`python3 -c` is not allowed; get the random part with
   `openssl rand -hex 4`). The random part keeps links unguessable.
2. Write the files into `{{SITES_DIR}}/<folder>/` with the file tools —
   `index.html` at minimum. One file with inline CSS/JS is best; images go in
   the same folder. Make it look good on a phone (responsive, readable fonts,
   dark-mode friendly). Use only data you actually have; no external trackers.
3. Reply with the link: `{{SITES_URL}}<folder>/` and one line saying what it is.

The link opens on the user's phone through their Tailscale network. To change a
page, rewrite its files and send the same link again. Never put secrets,
passwords or private messages on a page — anyone with the link can open it.
