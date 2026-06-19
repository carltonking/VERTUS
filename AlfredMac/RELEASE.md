# Alfred Release Guide

This guide covers packaging, signing, notarization, and distribution readiness for the native macOS Alfred app.

## Current Packaging Status

- App bundle name: `Alfred.app`
- Bundle identifier: `com.alfred.app`
- Minimum macOS: `14.0`
- Build system: Swift Package Manager
- Local app build script: `scripts/build_app.sh`
- Release artifact: ZIP, created by `scripts/package_release.sh`
- Sparkle framework: linked and embedded in `Alfred.app`
- Sparkle feed: `appcast.xml` exists, but production feed URL and EdDSA public key must be configured before enabling public updates
- App icon: `Alfred/Resources/AppIcon.icns`, generated from local logo assets and copied into `Contents/Resources/AppIcon.icns`

`build_app.sh` assembles the app bundle manually from the SwiftPM release binary, embeds `Sparkle.framework`, copies SwiftPM resource bundles, writes `Contents/Info.plist`, and signs ad hoc for local development.

## Build Command

Local development build:

```bash
cd AlfredMac
./scripts/build_app.sh --clean
open build/Alfred.app
```

Release metadata can be supplied through environment variables:

```bash
cd AlfredMac
VERSION=1.0.0 \
BUILD_NUMBER=100 \
BUNDLE_ID="com.alfred.app" \
SU_FEED_URL="https://example.com/alfred/appcast.xml" \
SPARKLE_PUBLIC_KEY="YOUR_SPARKLE_EDDSA_PUBLIC_KEY" \
./scripts/build_app.sh --clean
```

If `SU_FEED_URL` or `SPARKLE_PUBLIC_KEY` are omitted, the corresponding Sparkle keys are omitted from `Info.plist`.

## App Icon

The production app icon location is:

```text
Alfred/Resources/AppIcon.icns
```

`build_app.sh` copies it to:

```text
build/Alfred.app/Contents/Resources/AppIcon.icns
```

and writes:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

Generate the icon from the bundled logo assets with:

```bash
cd AlfredMac
./scripts/generate_app_icon.sh
```

The script uses macOS tools only, writes `AppIcon.icns`, and does not overwrite source PNG/logo assets.

## Bundle Identifier

The default bundle identifier is:

```text
com.alfred.app
```

Override it only for intentional separate distributions:

```bash
BUNDLE_ID="com.example.alfred.beta" ./scripts/build_app.sh --clean
```

`package_release.sh` passes the same environment through to `build_app.sh`, so `BUNDLE_ID` flows consistently into `Info.plist`.

## Fixture And QA Commands

Generate deterministic local QA fixtures:

```bash
cd AlfredMac
./scripts/generate_qa_fixtures.sh
```

Run manual QA using:

```text
QA/MANUAL_QA_CHECKLIST.md
QA/RELEASE_READINESS.md
QA/QA_RUN_TEMPLATE.md
```

The manual QA gate must pass before notarizing a public release.

## Version Bump Process

1. Choose `VERSION`, for example `1.0.0`.
2. Choose a monotonically increasing `BUILD_NUMBER`, for example `100`.
3. Build with those values:

   ```bash
   VERSION=1.0.0 BUILD_NUMBER=100 ./scripts/build_app.sh --clean
   ```

4. Confirm `CFBundleShortVersionString` and `CFBundleVersion`:

   ```bash
   plutil -p build/Alfred.app/Contents/Info.plist
   ```

5. Update release notes and Sparkle appcast metadata if Sparkle updates are enabled.

## Code Signing Requirements

Public distribution requires an Apple Developer Program account and a Developer ID Application certificate.

Expected environment variable:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
```

The release packaging script signs with:

```bash
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" build/Alfred.app
```

There is currently no custom entitlements file. Alfred is distributed as a non-sandboxed Developer ID app and relies on user-approved macOS privacy permissions rather than broad sandbox entitlements. Hardened runtime is enabled for Developer ID release signing.

## Entitlements Review

No explicit entitlements are currently required for the release build:

- Notifications: uses UserNotifications permission prompts; no entitlement required for a Developer ID app.
- ScreenCaptureKit / Screen Recording: controlled by macOS Screen Recording privacy permission and usage description.
- File picker access: uses `NSOpenPanel`/`NSSavePanel`; no broad file entitlement is required outside the App Sandbox.
- Security-scoped bookmarks: used for user-selected files/folders; no sandbox entitlement is currently needed because the app is not sandboxed.
- Accessibility: controlled by macOS Accessibility privacy permission and usage description.
- Network client access: provider/web requests work in a non-sandboxed Developer ID app without a network entitlement.
- Sparkle updates: Sparkle is embedded and signed with the app; no additional app entitlement is currently configured.

If the app is sandboxed in the future, revisit entitlements deliberately and keep them narrow.

Verify signing:

```bash
codesign --verify --deep --strict build/Alfred.app
codesign --display --verbose=4 build/Alfred.app
spctl --assess --type execute --verbose=4 build/Alfred.app
```

## Package ZIP Artifact

Dry run:

```bash
cd AlfredMac
VERSION=1.0.0 ./scripts/package_release.sh --dry-run
```

Internal unsigned/ad-hoc testing ZIP:

```bash
cd AlfredMac
VERSION=1.0.0 BUILD_NUMBER=100 ./scripts/package_release.sh --skip-sign
```

Signed release ZIP:

```bash
cd AlfredMac
VERSION=1.0.0 \
BUILD_NUMBER=100 \
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
SU_FEED_URL="https://example.com/alfred/appcast.xml" \
SPARKLE_PUBLIC_KEY="YOUR_SPARKLE_EDDSA_PUBLIC_KEY" \
./scripts/package_release.sh
```

Output:

```text
dist/Alfred-1.0.0.zip
```

## Notarization Process

Preferred authentication uses a notarytool keychain profile:

```bash
xcrun notarytool store-credentials "alfred-notary"
```

Then notarize:

```bash
cd AlfredMac
ALFRED_RELEASE_ZIP="dist/Alfred-1.0.0.zip" \
NOTARYTOOL_PROFILE="alfred-notary" \
./scripts/notarize_release.sh
```

Alternative Apple ID authentication:

```bash
cd AlfredMac
ALFRED_RELEASE_ZIP="dist/Alfred-1.0.0.zip" \
APPLE_ID="you@example.com" \
APP_PASSWORD="app-specific-password-or-keychain-ref" \
TEAM_ID="TEAMID" \
./scripts/notarize_release.sh
```

The script submits the ZIP, extracts `Alfred.app`, staples the app, validates stapling, assesses Gatekeeper, and creates:

```text
dist/Alfred-1.0.0-stapled.zip
```

## Stapling And Verification Commands

Manual commands if needed:

```bash
xcrun stapler staple build/Alfred.app
xcrun stapler validate build/Alfred.app
spctl --assess --type execute --verbose=4 build/Alfred.app
```

For a ZIP artifact, unzip it first, staple/validate the app, then re-create the ZIP with `ditto --keepParent`.

## DMG Notes

`scripts/build_dmg.sh` exists as an older DMG-oriented flow, but the recommended release artifact is currently ZIP. Prefer ZIP until the DMG script is reconciled with `build_app.sh` metadata, Sparkle settings, resource copying, and signing behavior.

## Sparkle Update Notes

Sparkle is linked through SwiftPM and embedded in the app bundle. Before enabling public updates:

1. Replace the placeholder `SU_FEED_URL`.
2. Generate Sparkle EdDSA keys with Sparkle tooling, typically:

   ```bash
   ./AlfredMac/.build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   If the exact path differs after dependency resolution, locate it with:

   ```bash
   find .build -name generate_keys -type f
   ```

3. Set `SPARKLE_PUBLIC_KEY` at build/package time.
4. Sign the ZIP update artifact with Sparkle's `sign_update`.
5. Update `appcast.xml` with the final URL, length, version/build, release notes URL, publication date, and EdDSA signature.
6. Host the appcast and ZIP over HTTPS.
7. Verify **Check for Updates...** from a signed/notarized installed build.

Do not ship a public Sparkle update feed with placeholder URLs or placeholder public keys.

## Rollback Notes

If a release must be rolled back:

1. Remove or replace the bad ZIP from the public download location.
2. Update the Sparkle appcast to point to the previous known-good version.
3. Keep the previous notarized artifact available.
4. Publish a short note describing the rollback.
5. Verify a fresh install and update check from the previous version.

## Release Checklist

Before publishing:

1. Run `./scripts/generate_qa_fixtures.sh`.
2. Run `./scripts/build_app.sh --clean`.
3. Complete `QA/MANUAL_QA_CHECKLIST.md`.
4. Complete `QA/RELEASE_READINESS.md`.
5. Fill out `QA/QA_RUN_TEMPLATE.md`.
6. Run `QA/FRESH_INSTALL_TEST.md`.
7. Package with `scripts/package_release.sh`.
8. Notarize with `scripts/notarize_release.sh`.
9. Validate Gatekeeper on a fresh download or clean machine.
