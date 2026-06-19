# Alfred QA Run

## Run Metadata

| Field | Value |
| --- | --- |
| Date | |
| Build commit/hash | |
| macOS version | |
| Machine type | |
| Alfred app version/build | |
| Bundle identifier | |
| Signing identity | |
| Release artifact path | |
| Tester | |

## Setup Results

| Item | Result | Notes |
| --- | --- | --- |
| Fixture generation result | Pending | `./scripts/generate_qa_fixtures.sh` |
| App icon generation result | Pending | `./scripts/generate_app_icon.sh` |
| Clean build result | Pending | `./scripts/build_app.sh --clean` |
| App launch result | Pending | `open build/Alfred.app` |
| Info.plist version/build/bundle ID result | Pending | `plutil -p build/Alfred.app/Contents/Info.plist` |
| Release ZIP result | Pending | `scripts/package_release.sh` |
| Codesign verification result | Pending | `codesign --verify --deep --strict` |
| Notarization result | Pending | `scripts/notarize_release.sh` |
| Staple validation result | Pending | `xcrun stapler validate` |
| Gatekeeper assessment result | Pending | `spctl --assess --type execute` |
| Fresh install launch result | Pending | |
| Fresh install test result | Pending | `QA/FRESH_INSTALL_TEST.md` |
| Sparkle upgrade result | Pending | Required only if Sparkle feed is enabled. |
| Diagnostics result | Pending | Run from menu bar. |
| Copy Diagnostics Summary result | Pending | Confirm no full paths, contents, screenshots, screen text, or secrets. |

## Checklist Results

| Test Area | Pass/Fail | Notes |
| --- | --- | --- |
| Run Alfred Diagnostics | Pending | |
| Copy Diagnostics Summary | Pending | |
| Read selected TXT | Pending | |
| Read selected MD | Pending | |
| Read selected Swift | Pending | |
| Read selected JSON | Pending | |
| Read selected CSV | Pending | |
| Read selected log | Pending | |
| Read selected PDF | Pending | |
| Read selected DOCX | Pending | |
| Read selected PPTX | Pending | |
| Unsupported selected file | Pending | |
| Oversized selected file | Pending | |
| Malformed DOCX | Pending | |
| Malformed PPTX | Pending | |
| Selected folder listing | Pending | |
| Selected folder bounded read | Pending | |
| Create MD | Pending | |
| Create TXT | Pending | |
| Export PDF | Pending | |
| Export DOCX | Pending | |
| Export PPTX | Pending | |
| Save cancel flow | Pending | |
| Remember/forget file access | Pending | |
| Remember/forget folder access | Pending | |
| Screen monitoring enable/disable | Pending | |
| Focus session start/pause/resume/end | Pending | |
| Off-task notification cooldown | Pending | |
| Computer control permission check | Pending | |
| Simple computer control action | Pending | |
| Multi-step workflow: summarize selected PDF and save as Markdown | Pending | |
| Multi-step workflow failure/cancel path | Pending | |

## Privacy And Safety Assertions

| Assertion | Pass/Fail | Notes |
| --- | --- | --- |
| No hidden writes | Pending | |
| No automatic folder scan | Pending | |
| No persisted extracted text | Pending | |
| No persisted screenshots or screen observations | Pending | |
| No full paths in diagnostics copy | Pending | |
| No shell execution unless explicitly requested and enabled | Pending | |
| No computer control unless explicitly requested and confirmed | Pending | |

## Bugs Found

| ID | Severity | Description | Repro Steps | Owner | Status |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

## Fix Verification

| Bug ID | Fix Commit/Build | Verification Steps | Result | Notes |
| --- | --- | --- | --- | --- |
| | | | | |

## Release Decision

Decision: `ship` / `hold`

Reason:

## Notes

- 
Alfred Diagnostics

macOS: Version 26.4.1 (Build 25E253)
App: 0.1.0 (0.1.0)

Permissions
Notifications: Granted
Screen Recording: Not granted
Accessibility: Not granted

Runtime
Screen monitoring: Off
Focus session: Off
Proactive suggestions: Enabled

Selected Context
Selected files: 0
Selected folder: None
Remembered file access: None
Remembered folder access: None
