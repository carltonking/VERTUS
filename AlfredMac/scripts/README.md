# Alfred — Build & Distribution Scripts

## `build_dmg.sh`

Builds a signed, notarized, stapled DMG ready for distribution.

### What it does

| Step | Action |
|------|--------|
| 1 | `swift build -c release` |
| 2 | Assembles `Alfred.app` bundle with `Info.plist` |
| 3 | Code-signs the `.app` with hardened runtime |
| 4 | Creates a compressed DMG with an Applications symlink |
| 5 | Signs the DMG |
| 6 | Submits to Apple notarytool and waits for approval |
| 7 | Staples the notarization ticket |

### Required environment variables

| Variable | Description | How to get it |
|----------|-------------|---------------|
| `VERSION` | App version string | Choose it — e.g. `1.0.0` |
| `DEVELOPER_ID` | Your Developer ID name (not email) | Keychain Access → search "Developer ID Application" → copy the name after the colon, before the `(XXXXXXXXXX)` |
| `APPLE_ID` | Your Apple ID email | The email you use to sign in to developer.apple.com |
| `APP_PASSWORD` | App-specific password | [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → Generate |
| `TEAM_ID` | 10-character Apple Team ID | [developer.apple.com/account](https://developer.apple.com/account) → Membership → Team ID |

### Example usage

```bash
export VERSION="1.0.0"
export DEVELOPER_ID="Jane Smith"
export APPLE_ID="jane@example.com"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export TEAM_ID="AB12CD34EF"

bash scripts/build_dmg.sh
```

Or as a one-liner:

```bash
VERSION=1.0.0 \
DEVELOPER_ID="Jane Smith" \
APPLE_ID="jane@example.com" \
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
TEAM_ID="AB12CD34EF" \
bash scripts/build_dmg.sh
```

Output is written to `AlfredMac/build/Alfred-$VERSION.dmg`.

### Prerequisites

- Xcode command line tools installed (`xcode-select --install`)
- Active Apple Developer Program membership
- "Developer ID Application" certificate in your login keychain
- `notarytool` available (Xcode 13+)

### Troubleshooting

**`codesign` can't find certificate** — Open Keychain Access, confirm "Developer ID Application: Your Name (TEAM_ID)" exists and is trusted. If it shows as expired or untrusted, re-download from [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates).

**Notarization rejected** — Run `xcrun notarytool log <submission-id> --apple-id ... --password ... --team-id ...` to fetch the full rejection report.

**`APP_PASSWORD` invalid** — App-specific passwords are separate from your Apple ID password. Generate one at [appleid.apple.com](https://appleid.apple.com) → App-Specific Passwords.

---

## Publishing an Update

Alfred uses [Sparkle 2](https://sparkle-project.org) for automatic updates. The flow is:
build DMG → sign it → upload it → sign the update → publish appcast.xml.

### Step 1 — Generate your EdDSA key pair (once only)

Sparkle ships a key generator. Run it from your Sparkle checkout or the SPM cache:

```bash
# Find the tool in your SPM build cache after first swift build
find ~/.build -name "generate_keys" -type f 2>/dev/null | head -1 | xargs -I{} {}
```

This prints a **private key** (save it in 1Password — never commit it) and a
**public key** to paste into `Info.plist` as `SUPublicEDKey`. The script in
`build_dmg.sh` already has a placeholder for it.

### Step 2 — Sign the DMG

After `build_dmg.sh` produces a notarized DMG, sign it with Sparkle's tool:

```bash
SIGN_UPDATE=$(find ~/.build -name "sign_update" -type f 2>/dev/null | head -1)
"$SIGN_UPDATE" build/Alfred-1.0.0.dmg
# Output: edDSA signature string
```

Copy the signature string — you need it in the next step.

### Step 3 — Update appcast.xml

Edit `appcast.xml` at the repo root and add a new `<item>` block (keep old
items for users on older macOS):

```xml
<item>
  <title>Version 1.0.0</title>
  <sparkle:version>1</sparkle:version>
  <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
  <pubDate>Mon, 16 Jun 2025 12:00:00 +0000</pubDate>
  <enclosure
    url="https://YOUR_DOMAIN/releases/Alfred-1.0.0.dmg"
    sparkle:edDSASignature="PASTE_SIGNATURE_HERE"
    length="BYTE_SIZE_OF_DMG"
    type="application/octet-stream" />
</item>
```

Get the byte size with: `stat -f%z build/Alfred-1.0.0.dmg`

### Step 4 — Host the appcast and DMG

**GitHub Pages (recommended):**

1. Push `appcast.xml` to the `gh-pages` branch (or `docs/` folder) of a public repo.
2. Upload the DMG to a GitHub Release so it gets a stable CDN URL.
3. Your appcast URL will be: `https://YOUR_ORG.github.io/alfred/appcast.xml`

Update `SUFeedURL` in `build_dmg.sh` to match this URL before building the
next release.

### Step 5 — Verify end-to-end

```bash
# Check the feed is reachable and valid XML
curl -s https://YOUR_DOMAIN/alfred/appcast.xml | xmllint --noout -
```

Sparkle will poll `SUFeedURL` at launch and when the user clicks
**Alfred → Check for Updates…**.
