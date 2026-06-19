# Alfred Fresh Install Release Test

Use this test for a signed and notarized release candidate, preferably on a clean Mac user account or a machine that has not previously run the build.

## Prerequisites

- Release ZIP created with `scripts/package_release.sh`.
- Release ZIP notarized/stapled with `scripts/notarize_release.sh`.
- QA fixtures generated with `scripts/generate_qa_fixtures.sh`.
- `QA/MANUAL_QA_CHECKLIST.md` and `QA/RELEASE_READINESS.md` completed or in progress.

## Steps

1. Build and package a signed release:

   ```bash
   cd AlfredMac
   VERSION=1.0.0 \
   BUILD_NUMBER=100 \
   DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
   ./scripts/package_release.sh
   ```

2. Notarize, staple, and create the stapled ZIP:

   ```bash
   ALFRED_RELEASE_ZIP="dist/Alfred-1.0.0.zip" \
   NOTARYTOOL_PROFILE="alfred-notary" \
   ./scripts/notarize_release.sh
   ```

3. Copy `dist/Alfred-1.0.0-stapled.zip` to a clean location outside the repo, such as `~/Downloads/Alfred-release-test/`.

4. Unzip the archive outside the repo.

5. Move `Alfred.app` to `/Applications`.

6. Launch Alfred from Finder, not Terminal.

Expected:

- Gatekeeper does not block launch.
- Alfred launches as a menu bar app.
- If macOS shows a standard first-launch prompt, it identifies Alfred and allows opening the notarized app.

7. Run **Run Alfred Diagnostics** from the menu bar.

Expected:

- Diagnostics show local-only permission and runtime status.
- No full paths, file contents, screenshots, screen text, or secrets appear.

8. Press `Cmd+Shift+J`.

Expected:

- Alfred's command bar opens and closes reliably.

9. Choose **Test Notification**.

Expected:

- macOS notification permission flow appears if not already decided.
- Alfred reports disabled notifications if permission is denied.

10. Use **Choose File...** and select `QA/Fixtures/sample-note.txt`.

11. Ask `summarize selected file`.

Expected:

- Alfred reads the selected file only after the explicit request.

12. Ask `create a markdown file about fresh install QA`.

Expected:

- `NSSavePanel` appears.
- No file is written until a destination is chosen.

13. Ask about visible screen context, or enable **Screen Monitoring**.

Expected:

- macOS Screen Recording permission flow appears if permission is missing.
- Disabling screen monitoring clears in-memory screen context.

14. Ask a simple computer-control action, such as `click 100 100`.

Expected:

- macOS Accessibility permission flow appears if permission is missing.
- Alfred does not perform actions until Accessibility is granted and the action plan is confirmed.

15. If Sparkle is configured, choose **Check for Updates...**.

Expected:

- Sparkle update UI can reach the configured appcast.
- The appcast points to a signed/notarized artifact and has a valid EdDSA signature.

16. Quit Alfred and delete `/Applications/Alfred.app`.

17. Review expected local data:

Expected:

- No extracted file text, document text, screenshots, screen observations, or generated exports remain unless the tester explicitly saved output.
- Intentional preferences, Keychain entries, remembered security-scoped bookmarks, and local SQLite memory may remain until manually cleared.

Optional cleanup:

```bash
rm -rf ~/.alfred
```

Remove Alfred API keys and remembered access from Keychain only if this is a disposable test account.
