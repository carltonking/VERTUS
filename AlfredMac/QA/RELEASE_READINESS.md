# Alfred Release Readiness

Use this checklist before shipping a local build, release candidate, or packaged build.

## Required Release Gates

| Gate | Status | Notes |
| --- | --- | --- |
| Clean build passes with `./scripts/build_app.sh --clean`. | Pending | |
| Agent bridge smoke test passes with `python3 agent-bridge/smoke_test_servers.py --concurrency 4`. | Pending | Every MCP server must launch and answer `tools/list`; any nonzero exit holds the release. Run bare (no pipe — piping masks the exit code). See `agent-bridge/README.md`. |
| Alfred launches as a real `.app` bundle. | Pending | |
| `AppIcon.icns` exists and `CFBundleIconFile` is set to `AppIcon`. | Pending | Generate with `scripts/generate_app_icon.sh`. |
| Bundle identifier is correct for the release channel. | Pending | Default: `com.alfred.app`. |
| `CFBundleShortVersionString` and `CFBundleVersion` match release metadata. | Pending | |
| Release ZIP is created with `scripts/package_release.sh`. | Pending | |
| App is signed with Developer ID Application for public distribution. | Pending | |
| Hardened runtime is enabled for release signing. | Pending | |
| `codesign --verify --deep --strict` passes. | Pending | |
| App notarization is accepted by Apple. | Pending | |
| Staple validation passes with `xcrun stapler validate`. | Pending | |
| Gatekeeper assessment passes with `spctl --assess`. | Pending | |
| Fresh install launches without Gatekeeper blocking. | Pending | |
| Fresh install test completed. | Pending | See `QA/FRESH_INSTALL_TEST.md`. |
| Upgrade path works if Sparkle is enabled. | Pending | |
| **Run Alfred Diagnostics** completes successfully. | Pending | |
| **Copy Diagnostics Summary** omits full paths, contents, screenshots, screen text, and secrets. | Pending | |
| Manual QA checklist completed. | Pending | See `QA/MANUAL_QA_CHECKLIST.md`. |
| PDF export file opens in Preview. | Pending | |
| DOCX export file opens in Word or Pages. | Pending | |
| PPTX export file opens in PowerPoint or Keynote. | Pending | |
| Selected PDF reading works with `QA/Fixtures/Generated/sample-text.pdf`. | Pending | |
| Selected DOCX reading works with `QA/Fixtures/Generated/sample-document.docx`. | Pending | |
| Selected PPTX reading works with `QA/Fixtures/Generated/sample-deck.pptx`. | Pending | |
| Unsupported selected-file failure is clean and actionable. | Pending | |
| Oversized selected-file failure is clean and actionable. | Pending | |
| Malformed DOCX/PPTX failures are clean and actionable. | Pending | |
| No hidden writes occur. | Pending | All created files must use `NSSavePanel`. |
| No prompt-provided path is trusted as a write destination. | Pending | |
| No automatic folder scanning occurs. | Pending | Folder listing/reading must be explicit. |
| No extracted file or document contents are persisted. | Pending | |
| No screenshots, video, screen text, or screen observations are persisted. | Pending | |
| Screen monitoring defaults off on launch. | Pending | |
| Focus mode defaults off on launch. | Pending | |
| Focus notifications respect cooldown. | Pending | |
| Computer control requires Accessibility permission. | Pending | |
| Computer control requires explicit user request and confirmation. | Pending | |
| Computer control refuses passwords, payment info, and sensitive secrets. | Pending | |
| Multi-step workflows show a plan before execution. | Pending | |
| Workflows with multiple side effects require confirmation. | Pending | |
| Workflow failure/cancel path stops and summarizes partial completion. | Pending | |
| Shell execution does not run unless explicitly requested and enabled. | Pending | |
| README capability list is current. | Pending | |
| Known limitations are documented. | Pending | |
| `RELEASE.md` signing/notarization instructions are current. | Pending | |
| Sparkle appcast URL, public key, release notes, and EdDSA signature are configured if updates are enabled. | Pending | |

## Ship/Hold Rule

- **Ship** only if every required gate is passing or explicitly accepted as a documented limitation.
- **Hold** if any privacy, permission, hidden-write, hidden-scan, background-monitoring, or computer-control gate fails.
- **Hold** if the agent bridge smoke test fails: `smoke_test_servers.py` exits nonzero when any registered MCP server can't boot or answer `tools/list` (e.g. a renamed script the config still points at, a missing backing binary, or a wedged npx wrapper). Run it bare — a pipe (e.g. `| tail`) hides the exit code and can make a failure look green. Fix the server or the config, re-run, and only then ship.

## Release Notes Inputs

Capture these from the completed QA run:

- Build commit/hash
- macOS version
- Alfred app version/build
- Signing identity used
- Notarization submission result
- Release artifact path
- Fixture generation result
- Any accepted limitations
- Any known regressions
