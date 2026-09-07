---
name: newsletter-subscribe
description: "Subscribe to newsletters via web form submission + email verification — use when asked to subscribe to one or more newsletters at a given email address"
---

# Newsletter Subscription

You can subscribe to newsletters by filling out web signup forms and verifying via email. Use this skill when asked to subscribe to one or more newsletters.

## Tools You Have

- **browser** — Navigate to signup pages, fill forms, click submit, take screenshots, read confirmation text
- **fetch** — Make HTTP requests (GET/POST) for API-based signups or to fetch signup page content
- **email** — Connect to IMAP, list/read/search emails to verify subscription confirmations

## Email Credentials

Your email creds are in `email-creds.json` in your agent home directory. Format:
```json
{
  "host": "imap.gmail.com",
  "port": 993,
  "user": "your-email@gmail.com",
  "password": "your-app-password"
}
```

If creds are missing, ask the user to provide them. Never make up credentials.

## Workflow

### 1. Get the List and Email

When asked to subscribe to newsletters:
- Identify the list of newsletters to subscribe to
- Identify the email address to use (check `email-creds.json` user field, or ask the user)
- For each newsletter, find the official signup URL (search the web if needed, or use a known URL the user provides)

### 2. Subscribe via Browser

For each newsletter:

1. **Navigate** to the signup page: `browser navigate https://newsletter-site.com/signup`
2. **Wait for the page** to load: `browser wait_for input[type="email"], input[type="text"]` (or similar selector)
3. **Find the email input** — look for `input[type="email"]`, `input[name="email"]`, or similar
4. **Fill the email**: `browser fill input[type="email"], your-email@gmail.com`
5. **Find and click the submit button** — look for `button[type="submit"]`, `input[value="Subscribe"]`, or similar
6. **Wait for confirmation**: `browser wait_for .success-message, .confirmation, [role="alert"]` (adjust selector to the site)
7. **Screenshot the result**: `browser screenshot` (helps verify and debug)
8. **Read confirmation text**: `browser read_text .success-message` or similar to confirm what happened

If the site uses a different flow (e.g., OTP, captcha), adapt accordingly. If you hit a CAPTCHA, you cannot solve it — record the blocker and move on.

### 3. Verify via Email

After submitting the signup form:

1. **Connect to email**: `email connect` (uses creds from email-creds.json)
2. **Search for the confirmation email**: `email search query={subject: "confirmed", from: "newsletter-site.com"}` or similar
3. **Read the confirmation**: `email read uid=<UID>` to verify the subscription went through
4. **Record the result**: Note success/failure per newsletter

If no confirmation email arrives within a reasonable time, poll a few times with `email search` using different queries.

### 4. Report Results

After processing all newsletters, report:
- Which subscriptions succeeded (with confirmation details)
- Which failed (with the blocker: captcha, missing form, email error, etc.)
- Any screenshots or relevant URLs

## Tips

- **Rate limiting**: Don't hammer signup endpoints. Add small delays between submissions if doing many at once.
- **Multiple workers**: If subscribing to many newsletters, you can work in parallel — open multiple browser contexts or use separate turns.
- **Unattended mode**: When running as a routine, you're in unattended mode. If you hit a blocker you can't work around (CAPTCHA, 2FA, etc.), record it and continue rather than waiting for user input.
- **Site diversity**: Different sites have different form structures. Use `browser eval document.querySelectorAll('input')` to inspect the page if you can't find the form elements with CSS selectors.

## Example Prompts

- "Subscribe to these newsletters: Stratechery, The Browser Company, Anthropic updates — use vertusaiassistant@gmail.com"
- "Sign me up for the daily AI newsletters: The Batch, Import AI, AlphaSignal"
- "Check if I'm subscribed to the GitHub blog and subscribe if not"
