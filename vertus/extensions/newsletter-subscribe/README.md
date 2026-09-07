# Newsletter Subscription Skill

This skill enables VERTUS to subscribe to newsletters autonomously using browser automation and email verification.

## Setup

### 1. Add Email Credentials

Create `email-creds.json` in your fleet home directory (`~/.vertus/agent/`):

```json
{
  "host": "imap.gmail.com",
  "port": 993,
  "user": "your-newsletter-address@gmail.com",
  "password": "your-app-password"
}
```

For Gmail, use an App Password (not your regular password). Enable 2FA first, then create an app password at https://myaccount.google.com/apppasswords.

For other providers:
- **Proton Mail**: Use IMAP with app password
- **Fastmail**: Use IMAP with app password
- **Outlook/Hotmail**: Use IMAP with app password

### 2. The Skill is Auto-Loaded

Skills in `vertus/extensions/` are automatically available to the agent. The `newsletter-subscribe` skill provides the workflow for subscribing to newsletters.

## Usage

Tell VERTUS to subscribe to newsletters:

```
Subscribe to these newsletters: Stratechery, The Browser Company, Anthropic updates
```

Or for a daily routine:

```
Create a routine called "daily-newsletter-check" that runs every 24 hours and checks for new newsletters to subscribe to
```

## What Happens

1. VERTUS navigates to each newsletter's signup page
2. Fills in the email address
3. Submits the form
4. Takes a screenshot of the confirmation
5. Checks the email inbox for confirmation messages
6. Reports back which subscriptions succeeded

## Limitations

- **CAPTCHAs**: VERTUS cannot solve CAPTCHAs. If a site has a CAPTCHA, the subscription will be recorded as blocked.
- **2FA**: If a site requires 2FA during signup, VERTUS cannot complete it.
- **Rate limiting**: Some sites may block automated signups. If you get rate-limited, try again later.
