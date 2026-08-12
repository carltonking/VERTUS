# Alfred Manual QA Checklist

Use this checklist after building and launching `Alfred.app`.

Recommended setup:

```bash
cd AlfredMac
./scripts/generate_qa_fixtures.sh
./scripts/build_app.sh --clean
open build/Alfred.app
```

Generated fixtures are written to `AlfredMac/QA/Fixtures/Generated/`.

## General Rules To Verify Throughout

- Alfred should not read a selected file until the user explicitly asks.
- Alfred should not scan a selected folder automatically.
- Alfred should not write files without showing `NSSavePanel`.
- Alfred should not trust prompt-provided paths as write destinations.
- Alfred should not persist extracted file text, extracted document text, screenshots, or screen observations.
- Alfred should not include full file paths in copied diagnostics.
- Alfred should not execute shell commands unless the user explicitly uses shell syntax and shell execution is enabled.
- Alfred should not control the computer unless the user explicitly asks (the ask is the approval).

## Diagnostics

### Run Alfred Diagnostics

Steps:

1. Open the menu bar Alfred icon.
2. Choose **Run Alfred Diagnostics**.

Expected:

- A native diagnostics panel appears.
- It shows macOS version, app version/build if available, permission status, runtime status, selected file count, selected folder presence, and remembered access counts/stale state.

Privacy assertions:

- No file contents, document text, screenshots, screen text, secrets, provider data, or full paths are shown.
- No LLM request is made.

### Copy Diagnostics Summary

Steps:

1. Open the menu bar Alfred icon.
2. Choose **Copy Diagnostics Summary**.
3. Paste into a local scratch document.

Expected:

- The pasted text contains status only.
- Selected files are represented by count, and selected folder is represented by presence.

Privacy assertions:

- No full paths, contents, screenshots, screen text, or secrets are copied.

## Selected File Reading

For each file below, use **Choose File...**, select the fixture, then ask `summarize selected file`.

Fixtures:

- `QA/Fixtures/sample-note.txt`
- `QA/Fixtures/sample-markdown.md`
- `QA/Fixtures/sample-code.swift`
- `QA/Fixtures/sample-data.json`
- `QA/Fixtures/sample-table.csv`
- `QA/Fixtures/sample-log.log`

Expected:

- Alfred summarizes the selected file content.
- Unsupported or unrelated capabilities do not run.

Privacy assertions:

- No hidden writes occur.
- Extracted text is used only for the current request and is not persisted.

### Read Selected PDF

Steps:

1. Run `./scripts/generate_qa_fixtures.sh`.
2. Use **Choose File...** and select `QA/Fixtures/Generated/sample-text.pdf`.
3. Ask `summarize selected PDF`.

Expected:

- Alfred extracts and summarizes embedded PDF text.

Privacy assertions:

- No screenshot or OCR is performed.
- Extracted PDF text is not persisted.

### Read Selected DOCX

Steps:

1. Use **Choose File...** and select `QA/Fixtures/Generated/sample-document.docx`.
2. Ask `summarize selected DOCX`.

Expected:

- Alfred extracts and summarizes the simple DOCX text.

Privacy assertions:

- Extracted DOCX text is not persisted.

### Read Selected PPTX

Steps:

1. Use **Choose File...** and select `QA/Fixtures/Generated/sample-deck.pptx`.
2. Ask `summarize selected PPTX`.

Expected:

- Alfred extracts and summarizes text from the small deck.

Privacy assertions:

- Extracted slide text is not persisted.

### Unsupported Selected File

Steps:

1. Use **Choose File...** and select `QA/Fixtures/sample-folder/unsupported.bin`.
2. Ask `summarize selected file`.

Expected:

- Alfred refuses with a clear supported-type message.

Privacy assertions:

- No file contents are sent to the model.

### Oversized Selected File

Steps:

1. Run `./scripts/generate_qa_fixtures.sh`.
2. Use **Choose File...** and select `QA/Fixtures/Generated/sample-oversized.txt`.
3. Ask `summarize selected file`.

Expected:

- Alfred refuses because the file is over the selected text/code read limit.

Privacy assertions:

- No oversized content is sent to the model or persisted.

### Malformed DOCX/PPTX

Steps:

1. Select `QA/Fixtures/Generated/sample-malformed.docx` and ask `summarize selected DOCX`.
2. Select `QA/Fixtures/Generated/sample-malformed.pptx` and ask `summarize selected PPTX`.

Expected:

- Alfred refuses with an actionable malformed-document message.

Privacy assertions:

- No hidden repair or upload occurs.

## Selected Folder

### Selected Folder Listing

Steps:

1. Use **Choose Folder...** and select `QA/Fixtures/sample-folder`.
2. Ask `summarize selected folder`.

Expected:

- Alfred lists immediate visible children with filename, type, size, and modified date.
- The unsupported `.bin` file may appear in the listing.

Privacy assertions:

- No file contents are read.
- No recursion occurs by default.

### Selected Folder Bounded Read

Steps:

1. Use **Choose Folder...** and select `QA/Fixtures/sample-folder`.
2. Ask `read files in the selected folder`.

Expected:

- Alfred reads supported immediate files only.
- Alfred skips unsupported files.

Privacy assertions:

- No hidden recursion.
- No unsupported file contents are sent to the model.
- Extracted folder file text is not persisted.

## File Writing And Export

### Create MD

Steps:

1. Ask `create a markdown file about Alfred QA`.
2. Confirm `NSSavePanel` appears.
3. Choose a temporary destination.

Expected:

- Alfred writes a `.md` file only after the save panel is accepted.

Privacy assertions:

- Prompt-provided paths are not trusted.

### Create TXT

Steps:

1. Ask `write this note to a text file: Alfred QA text export`.
2. Confirm `NSSavePanel` appears.
3. Choose a temporary destination.

Expected:

- Alfred writes a `.txt` file only after the save panel is accepted.

Privacy assertions:

- No hidden writes occur.

### Export PDF

Steps:

1. Ask `export a short Alfred QA report as PDF`.
2. Save through `NSSavePanel`.
3. Open the result in Preview.

Expected:

- A readable PDF opens successfully.

Privacy assertions:

- No external service is used for PDF creation.

### Export DOCX

Steps:

1. Ask `save a short Alfred QA report as a Word document`.
2. Save through `NSSavePanel`.
3. Open the result in Word or Pages.

Expected:

- A basic DOCX opens successfully.

Privacy assertions:

- No macros or hidden writes are created.

### Export PPTX

Steps:

1. Ask `create slides about Alfred QA as PPTX`.
2. Save through `NSSavePanel`.
3. Open the result in PowerPoint or Keynote.

Expected:

- A basic deck opens successfully.

Privacy assertions:

- No macros or external services are used.

### Save Cancel Flow

Steps:

1. Ask `create a markdown file about save cancellation`.
2. Cancel the `NSSavePanel`.

Expected:

- Alfred reports that no file was written and asks you to run the request again to save.

Privacy assertions:

- No file is created after cancellation.

## Remembered Access

### Remember/Forget File Access

Steps:

1. Select `QA/Fixtures/sample-note.txt`.
2. Choose **Remember Selected File Access**.
3. Relaunch Alfred.
4. Run diagnostics and confirm remembered file access count is present.
5. Choose **Forget Remembered File Access**.
6. Run diagnostics again.

Expected:

- Remembered access is opt-in and can be forgotten.

Privacy assertions:

- File contents are not persisted.
- Remembering access does not trigger reading.

### Remember/Forget Folder Access

Steps:

1. Select `QA/Fixtures/sample-folder`.
2. Choose **Remember Selected Folder Access**.
3. Relaunch Alfred.
4. Run diagnostics and confirm remembered folder access count is present.
5. Choose **Forget Remembered Folder Access**.
6. Run diagnostics again.

Expected:

- Remembered folder access is opt-in and can be forgotten.

Privacy assertions:

- Remembering access does not scan the folder.

## Screen Monitoring And Focus

### Screen Monitoring Enable/Disable

Steps:

1. Choose **Enable Screen Monitoring**.
2. Confirm menu bar active state appears.
3. Choose **Disable Screen Monitoring**.

Expected:

- Active state is visible while enabled.
- Disabling clears in-memory screen context.

Privacy assertions:

- No screenshots or observations are persisted.
- Screen content is not sent to the model automatically.

### Focus Session Start/Pause/Resume/End

Steps:

1. Choose **Start Focus Session**.
2. Enter `manual QA for Alfred`.
3. Pause, resume, then end the session from the menu.

Expected:

- Status updates reflect each state.
- Focus session ends cleanly.

Privacy assertions:

- No browsing or app history is persisted.

### Off-Task Notification Cooldown

Steps:

1. Start a focus session with sensitivity set to High.
2. Switch to an obvious distractor app/site.
3. Wait for a nudge.
4. Continue off-task for less than 10 minutes.

Expected:

- Alfred sends at most one nudge during the cooldown window.

Privacy assertions:

- Nudges are local notifications only.
- No screenshots or app history are persisted.

## Computer Control

### Permission Check

Steps:

1. If Accessibility is not granted, ask `click 100 100`.

Expected:

- Alfred asks for Accessibility permission and does not perform the action.

Privacy assertions:

- No computer-control action occurs without permission.

### Simple Computer-Control Action

Steps:

1. Ask `click 100 100`.

Expected:

- Alfred performs the single click without a bar confirmation (the ask is the permission).
- Esc or **Stop Computer Control** can cancel active execution.

Privacy assertions:

- Alfred still refuses destructive requests and never types secrets or payment information.

## Calendar And Reminders

### Permission Check

Steps:

1. If Calendar permission is not granted, ask `add a calendar event tomorrow at 3pm called Standup`.

Expected:

- Alfred asks for Calendar access before reading or writing any event.

Privacy assertions:

- No event is created before the user grants Calendar access.

### Create Calendar Event

Steps:

1. Ask `add a calendar event called Lunch with Sam on Monday at 12:30pm`.

Expected:

- An event appears in Apple Calendar (and iCloud/iPhone) titled "Lunch with Sam" without any bar confirmation.
- Alfred's reply includes the event id.

Privacy assertions:

- Alfred only writes events the user asked about.

### List And Edit Event

Steps:

1. Ask `what's on my calendar this week`.
2. Ask `edit the event for <id> and move it to 4pm`.

Expected:

- The list includes an `id=` per event.
- The chosen event's start time is updated in Apple Calendar.

### Delete Event

Steps:

1. Ask `delete the event <id>`.
2. Confirm the delete action plan, which notes it is not reversible.

Expected:

- The event is removed from Apple Calendar.

### Create And Complete Reminder

Steps:

1. Ask `remind me to water the plants tomorrow`.
2. Ask `mark the reminder <id> complete`.

Expected:

- A reminder appears in Reminders (and iCloud/iPhone) with no bar confirmation.
- Marking it complete reflects in the Reminders app.

### Delete Reminder

Steps:

1. Ask `delete the reminder <id>`.
2. Confirm.

Expected:

- The reminder disappears from Reminders.

## Terminal

### Disabled Gate

Steps:

1. Ensure **Terminal** is off in Alfred Settings.
2. Ask `run: ls -la`.

Expected:

- Alfred explains Terminal is off and points to Settings; it does not run the command.

Privacy assertions:

- No shell command runs while the setting is off.

### Run A Command

Steps:

1. Enable **Terminal** in Alfred Settings.
2. Ask `run pwd`.

Expected:

- Alfred runs a fresh `zsh` without any bar confirmation and returns the home-directory path plus Exit code 0.

### Destructive Command Refused

Steps:

1. Ask `run: rm -rf ~/Library`.

Expected:

- Alfred refuses outright (no bar approval prompt) and tells the user it won't run the command.

Privacy assertions:

- No destructive command is ever offered for approval, let alone run.

## Workflows

### Summarize Selected PDF And Save As Markdown

Steps:

1. Select `QA/Fixtures/Generated/sample-text.pdf`.
2. Ask `summarize the selected PDF and save it as Markdown`.
3. Confirm the workflow plan.
4. Accept the `NSSavePanel`.

Expected:

- Alfred reads the selected PDF, generates a summary, and saves Markdown only after save-panel approval.

Privacy assertions:

- No hidden writes.
- No extracted PDF text is persisted.
- No shell or computer control runs.

### Workflow Failure/Cancel Path

Steps:

1. Select `QA/Fixtures/Generated/sample-text.pdf`.
2. Ask `summarize the selected PDF and save it as Markdown`.
3. Confirm the workflow plan.
4. Cancel the `NSSavePanel`.

Expected:

- Alfred stops the workflow and reports that no file was written.

Privacy assertions:

- No output file is created after cancellation.
