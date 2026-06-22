# Alfred

Alfred is a native macOS AI assistant with a Spotlight-style command bar. Press
`Cmd+Shift+J` anywhere on your Mac, ask a question or give a command, and Alfred
streams the answer back in a compact floating window that slides down from the
menu bar notch.

The current app is built as a Swift Package in `AlfredMac/`. It supports multiple
LLM providers, local memory, optional screen context,
web search, optional shell execution, text insertion, app launching, selected
file/folder context, document export, opt-in computer control, onboarding,
settings, a menu bar status item, and Sparkle-based updates.

## Requirements

- macOS 14+
- Swift 5.9+
- API key for at least one provider (free options available — see below)
- Optional: Brave Search API key for web search
- Optional: Ollama for fully local inference

## Free Providers

Alfred works at zero cost with any of these:

| Provider | Model | Notes |
| --- | --- | --- |
| **Local Fine-tuned Alfred** | `alfred` | Local OpenAI-compatible server at `localhost:8080` |
| **Google Gemini** | `gemini-2.0-flash` | Free option with vision support |
| **Groq** | `llama-3.2-90b-vision-preview` | Fast inference |
| **OpenRouter** | `google/gemini-2.0-flash-exp:free` | One key, many hosted models |
| **Ollama** | `phi3:mini` | Fully local inference through Ollama |

Get keys at:
- Gemini: [aistudio.google.com](https://aistudio.google.com)
- Groq: [console.groq.com](https://console.groq.com)
- OpenRouter: [openrouter.ai](https://openrouter.ai)
- Ollama: [ollama.com](https://ollama.com)

The current provider router exposes Local, Gemini, Groq, OpenRouter, and Ollama.

## Quick Start

Build a real macOS app bundle:

```bash
cd AlfredMac
./scripts/build_app.sh --clean
open build/Alfred.app
```

For the best macOS permissions behavior, install into `/Applications`:

```bash
cd AlfredMac
./scripts/build_app.sh --clean --install
open /Applications/Alfred.app
```

On first launch, Alfred opens onboarding so you can set:

1. Your name
2. Preferred AI provider
3. API key (unless using Ollama)
4. Required macOS permissions

API keys are stored in the macOS Keychain. App preferences are stored in
`UserDefaults`.

Do not use `swift run Alfred` for daily use. It launches a command-line
executable, not an app bundle, so macOS Privacy settings may not let you select
Alfred for Accessibility or Screen Recording permissions.

## What Alfred Can Do

- Answer questions through Gemini, Groq, Cerebras, Mistral, Anthropic, OpenAI, OpenRouter, or Ollama
- Stream responses in a scrollable 5-line response area below the prompt bar
- Search the web with Brave Search, falling back to DuckDuckGo HTML results
- Capture screen context when a query asks about the current page, window, or screen
- Choose files and folders through native macOS picker panels
- Keep selected files/folders in short-lived in-memory context
- Optionally remember selected file/folder access with explicit security-scoped bookmarks
- Read explicitly selected plain-text/code files, PDFs, DOCX files, and PPTX files within strict size limits
- List selected folders with bounded, non-recursive-by-default folder inspection
- Create text/code files, PDFs, DOCX files, and PPTX decks only through `NSSavePanel`
- Open, activate, hide, and quit named macOS apps
- Run confirmed, explicit shell commands when shell execution is enabled in Settings
- Run bounded, confirmed Accessibility-based computer-control actions when explicitly requested
- Start opt-in screen monitoring at low frequency, with visible active state and short-lived in-memory context
- Start opt-in focus sessions with gentle local notifications, cooldowns, pause/resume, and easy stop
- Run confirmed multi-step workflows that combine existing safe capabilities
- Send local macOS notifications
- Insert generated text into the focused app using Accessibility or pasteboard fallback
- Save conversation history and extracted facts to local SQLite memory, with Settings controls for retention and deletion
- Check for updates through Sparkle

## Menu Bar

When Alfred is running, an Alfred icon appears in the macOS menu bar. Use it to:

- Show Alfred
- Open Settings
- Reopen the permissions step
- Run Alfred Diagnostics
- Copy Diagnostics Summary
- Choose File...
- Choose Folder...
- Clear Selected Files
- Remember or forget selected file/folder access
- Enable or disable Screen Monitoring
- Start, pause, resume, or end a Focus Session
- Set focus sensitivity
- Stop Computer Control
- Test Notifications
- Quit Alfred

## Keyboard Shortcut

| Key | Action |
| --- | --- |
| `Cmd+Shift+J` | Summon or dismiss the Alfred bar |
| `Enter` | Submit the current query |

The bar slides down from the notch with a spring animation and collapses back
when dismissed. It is implemented in SwiftUI under `AlfredMac/Alfred/Bar/`.

## macOS Permissions

Alfred may need these permissions depending on which features you use:

- **Accessibility**: required for richer app context, app interaction, and text insertion
- **Screen Recording**: required for screen context through ScreenCaptureKit
- **Notifications**: required for local notifications and focus-session nudges
- **Files/Folders**: granted explicitly when you choose files/folders in native picker panels
- **Automation**: may be requested by macOS if an app-control action requires it

Approve permissions in **System Settings -> Privacy & Security**.

The `Cmd+Shift+J` hotkey uses macOS global hotkey registration and does not need
Accessibility just to open the bar.

## Diagnostics

Use **Run Alfred Diagnostics** from the menu bar before manual QA or when a
capability seems unavailable. Diagnostics are local-only and show:

- macOS version and app version/build, when available
- Notification, Screen Recording, and Accessibility permission status
- Screen monitoring, focus session, and proactive suggestion state
- Selected file count and selected folder presence
- Remembered file/folder access counts or stale-access status

Use **Copy Diagnostics Summary** to copy the same status summary. It does not
include full file paths, file contents, extracted document text, screenshots,
screen text, secrets, or provider request data.

Alfred also records recent capability events through local OS logging and a
small in-memory buffer for debugging. Events use high-level labels such as
`file write requested`, `save panel cancelled`, or `workflow failed`; they do
not include document contents, screenshots, or typed sensitive text.

## Manual QA

Manual QA fixtures and step-by-step checks live under `AlfredMac/QA/`.

Generate local document fixtures with:

```bash
cd AlfredMac
./scripts/generate_qa_fixtures.sh
```

Then follow `AlfredMac/QA/MANUAL_QA_CHECKLIST.md`. The generated fixtures are
small, deterministic, local-only, and contain no sensitive content.

## Release QA

Before shipping a build, use:

- `AlfredMac/QA/MANUAL_QA_CHECKLIST.md`
- `AlfredMac/QA/FRESH_INSTALL_TEST.md`
- `AlfredMac/QA/RELEASE_READINESS.md`
- `AlfredMac/QA/QA_RUN_TEMPLATE.md`
- `AlfredMac/RELEASE.md`

## Local Data

Alfred creates local application directories under:

```text
~/.alfred/
```

Current local state includes:

- `~/.alfred/db/memory.db`: SQLite memory and conversation history
- `~/.alfred/wiki/`: reserved for local knowledge/wiki material
- `~/.alfred/logs/`: reserved for app logs

Persistent memory is implemented with GRDB and SQLite in
`AlfredMac/Alfred/Memory/MemoryStore.swift`.

## Project Structure

```text
AlfredMac/
  Package.swift
  RELEASE.md
  Alfred/
    App/            App lifecycle, settings, onboarding, updates
    Bar/            Floating command bar, window, hotkey listener
    Capabilities/   Screen capture, shell, text insertion, web search
    LLM/            Provider protocol, routing, provider implementations
    Memory/         Local SQLite memory store
    Onboarding/     Setup flow and Keychain helpers
  scripts/
    build_dmg.sh    Release packaging helper
    generate_app_icon.sh
                    Generates Alfred/Resources/AppIcon.icns
    package_release.sh
                    ZIP packaging and optional Developer ID signing
    notarize_release.sh
                    Notarization, stapling, and Gatekeeper validation
    generate_qa_fixtures.sh
                    Local manual-QA fixture generator
  QA/
    MANUAL_QA_CHECKLIST.md
    FRESH_INSTALL_TEST.md
    Fixtures/       Safe sample files for manual capability testing
```

The root `index.html` is a static landing page for the project.

## Building a Release

For local development or personal use, build an ad-hoc signed app bundle:

```bash
cd AlfredMac
./scripts/build_app.sh --install
```

This creates `build/Alfred.app` and optionally copies it to
`/Applications/Alfred.app`.

For a notarized release DMG, use the release helper from the Swift app directory:

```bash
cd AlfredMac
./scripts/build_dmg.sh
```

Sparkle metadata lives in `AlfredMac/appcast.xml`, and update handling is wired
through `AlfredMac/Alfred/App/UpdaterManager.swift`.

## Troubleshooting

**The bar does not appear after pressing `Cmd+Shift+J`**

- Make sure `/Applications/Alfred.app` or `build/Alfred.app` is running
- Confirm no other app owns `Cmd+Shift+J`
- Use the menu bar icon -> Show Alfred as a fallback
- Relaunch Alfred after granting permissions

**Alfred does not appear in Accessibility permissions**

- Build a real app bundle with `./scripts/build_app.sh --install`
- Launch `/Applications/Alfred.app`
- Open System Settings -> Privacy & Security -> Accessibility
- Add or enable Alfred, then quit and reopen Alfred

**Screen-related queries fail**

- Grant Screen Recording permission in System Settings
- Relaunch Alfred after granting permissions

**Provider requests fail**

- Reopen Settings and confirm the selected provider
- Confirm the provider API key is present and valid
- For Ollama, confirm the Ollama service is running locally
- Error messages now include the provider's actual response body for easier diagnosis

**Shell commands do not run**

- Enable Shell execution in Alfred Settings
- Use explicit syntax, such as `run: pwd` or `` `pwd` ``
- Natural-language requests no longer execute shell commands automatically

**SwiftPM reports a missing `Sparkle.xcframework`**

If the local `.build` directory has stale absolute paths (common after renaming
or moving the project folder), clear SwiftPM build artifacts and rebuild:

```bash
cd AlfredMac
rm -rf .build
swift build
```

**`swift build` fails with `cannot use bare repository ... (safe.bareRepository is 'explicit')`**

Recent Git refuses to operate on the bare repositories SwiftPM keeps under
`.build` and `~/Library/Caches/org.swift.swiftpm`. Allow them, then rebuild:

```bash
cd AlfredMac
git config --global safe.bareRepository all
rm -rf .build
swift build
```

If a per-repo override still forces `explicit`, prefer scoping it to SwiftPM's
Git subprocesses for a single build instead of changing global config:

```bash
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
swift build
```

**Memory behaves unexpectedly**

Delete the local memory database and relaunch:

```bash
rm ~/.alfred/db/memory.db
```

## Privacy

- API keys are stored locally in the macOS Keychain
- Conversation history and extracted memories are stored locally in SQLite
- Screen captures are only attempted for queries that ask about visible screen context
- Provider calls go directly from the app to the selected provider
- Alfred does not silently write files; all created files go through `NSSavePanel`
- Alfred does not trust paths typed into prompts as write destinations
- Alfred does not silently scan folders; selected folder reads are explicit and bounded
- Selected file/folder context is in memory only unless you explicitly choose to remember access
- Remembered file/folder access uses security-scoped bookmarks and can be forgotten from the menu
- Alfred does not persist file contents, extracted document text, screenshots, or screen observations
- Screen monitoring is off by default on each launch, low frequency when enabled, visible in the menu bar, and cleared when stopped
- Proactive suggestions are off by default and can be enabled from Settings
- Focus sessions are opt-in, have cooldowns between nudges, and do not store browsing or app history
- Computer control and multi-step workflows require explicit user requests and confirmation before side effects
- Shell commands run only through explicit shell syntax and only when shell execution is enabled

## Capability Safety Limits

- Selected text/code files: supported extensions only, with a 1 MB total read limit
- Selected PDFs: bounded by file size, page count, and extracted character count
- Selected DOCX/PPTX files: extracted from OpenXML packages with file and character limits
- Selected folders: immediate children only by default, hidden files skipped, max 200 listed entries
- Folder file reading: max 10 files and 150,000 extracted characters per request
- Recursive folder listing: only when explicitly requested, capped at depth 2
- Computer control: max 20 actions per request, no indefinite loops, no sensitive secret entry
- Workflows: max 8 steps and stop on the first serious error
- File export: text/code, PDF, DOCX, and PPTX only; no macros, binaries, hidden writes, or path persistence

## Known Limitations

- DOCX/PPTX creation uses minimal internal writers, so formatting is basic and not intended for complex Office layouts
- PDF reading extracts embedded text only; image-only PDFs need OCR outside Alfred first
- DOCX/PPTX reading supports standard OpenXML files and may reject encrypted, malformed, or unusual compressed packages

## Manual Test Checklist

- Build and launch `Alfred.app`, then open the bar with `Cmd+Shift+J`
- Run **Run Alfred Diagnostics** and confirm permission/capability status before testing
- Ask a normal question and confirm streaming still works
- Create `.md`: ask `create a markdown file about Alfred` and confirm `NSSavePanel` appears before writing
- Create `.txt`: ask `write this note to a text file` and confirm `NSSavePanel` appears before writing
- Export PDF: ask `export this as PDF` and confirm the saved file opens in Preview
- Export DOCX: ask `save this as a Word document` and confirm the saved file opens in Word or Pages
- Export PPTX: ask `create slides about this as PPTX` and confirm the saved file opens in PowerPoint or Keynote
- Read selected `.txt`, `.md`, and `.swift`: choose each file with **Choose File...**, then ask `summarize selected file`
- Read selected PDF: choose a small text-based PDF, then ask `summarize selected PDF`
- Read selected DOCX: choose a small `.docx`, then ask `summarize selected DOCX`
- Read selected PPTX: choose a small `.pptx`, then ask `summarize selected PPTX`
- Selected folder listing: choose a folder, then ask `summarize selected folder`
- Selected folder bounded read: choose a small folder, then ask `read files in the selected folder`
- Remember/forget file access: choose a file, use **Remember Selected File Access**, relaunch, verify access status, then use **Forget Remembered File Access**
- Remember/forget folder access: choose a folder, use **Remember Selected Folder Access**, relaunch, verify access status, then use **Forget Remembered Folder Access**
- Computer control permission and simple action: ask for a small click/type action, confirm the plan, and verify Accessibility permission handling
- Enable Screen Monitoring and confirm the menu bar shows active state; disable it and confirm context clears
- Start a Focus Session with a goal, pause/resume it, then end it from the menu
- Multi-step workflow: choose a PDF, ask `summarize the selected PDF and save it as Markdown`, confirm the workflow plan, and confirm `NSSavePanel` appears
- Cancel a save panel during a workflow and confirm the workflow stops instead of reporting a completed write
- Try shell syntax with shell execution disabled and confirm Alfred refuses instead of silently skipping the step
- Press Esc or use **Stop Computer Control** during computer-control execution
