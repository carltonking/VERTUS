//
//  MailAITests.swift
//  AlfredTests
//
//  The mail copilot's iOS payload decoders (MailAI.swift) — these mirror the
//  Mac's wire shapes, so a decode that silently returns nil would show up as
//  missing chips and blank panels long before anyone notices the parser.
//

import Foundation
import Testing
@testable import Alfred

@Suite("Mail AI payloads")
struct MailAITests {

    @Test("Classification decodes the wire shape")
    func classification() {
        let payload = MailClassificationPayload.fromJSON([
            "label": "needs_reply",
            "tone": "Friendly, Urgent",
            "summary": "wants the Q3 numbers by Friday",
        ])
        #expect(payload?.label == "needs_reply")
        #expect(payload?.tone == "Friendly, Urgent")
        #expect(payload?.summary == "wants the Q3 numbers by Friday")
        #expect(payload?.chipKind == .needsReply)
    }

    @Test("Only actionable labels produce a chip")
    func chipKinds() {
        // `.none` must be spelled MailChipKind.none here: in an optional
        // comparison, a bare `.none` binds to Optional.none (nil) and would
        // compare against nothing.
        #expect(MailClassificationPayload.fromJSON(["label": "action_item"])?.chipKind == .actionItem)
        #expect(MailClassificationPayload.fromJSON(["label": "fyi"])?.chipKind == MailChipKind.none)
        #expect(MailClassificationPayload.fromJSON(["label": "low_priority"])?.chipKind == MailChipKind.none)
        #expect(MailClassificationPayload.fromJSON(["label": "garbage"])?.chipKind == MailChipKind.none)
    }

    @Test("Classification without a label is not parseable")
    func classificationRequiresLabel() {
        #expect(MailClassificationPayload.fromJSON(["tone": "Friendly"]) == nil)
    }

    @Test("Summary decodes bullets and tone")
    func summary() {
        let payload = MailSummaryPayload.fromJSON([
            "bullets": ["Sarah wants the budget by Friday", "Numbers attached"],
            "tone": "Urgent",
        ])
        #expect(payload?.bullets == ["Sarah wants the budget by Friday", "Numbers attached"])
        #expect(payload?.tone == "Urgent")
    }

    @Test("Empty bullet list is not parseable")
    func summaryRequiresBullets() {
        #expect(MailSummaryPayload.fromJSON(["bullets": [], "tone": "Friendly"]) == nil)
    }

    @Test("Task decodes title and detail")
    func task() {
        let payload = MailTaskPayload.fromJSON([
            "title": "Reply with the numbers",
            "detail": "by Friday, to Sarah",
        ])
        #expect(payload?.title == "Reply with the numbers")
        #expect(payload?.detail == "by Friday, to Sarah")
    }

    @Test("Task without a title is dropped")
    func taskRequiresTitle() {
        #expect(MailTaskPayload.fromJSON(["detail": "by Friday"]) == nil)
    }

    @Test("Draft decodes subject and body")
    func draft() {
        let payload = MailDraftPayload.fromJSON([
            "subject": "Re: Budget",
            "body": "Thanks Sarah — sending the numbers over shortly.",
        ])
        #expect(payload?.subject == "Re: Budget")
        #expect(payload?.body == "Thanks Sarah — sending the numbers over shortly.")
    }

    @Test("Empty draft body is not parseable")
    func draftRequiresBody() {
        #expect(MailDraftPayload.fromJSON(["subject": "Re: Budget", "body": ""]) == nil)
    }

    // MARK: - Scan summary

    @Test("Folder stat decodes the wire shape")
    func folderStat() {
        let payload = MailFolderStatPayload.fromJSON([
            "account_id": "icloud",
            "id": "inbox",
            "name": "Inbox",
            "role": "inbox",
            "total": 12,
            "unseen": 3,
            "flagged": 1,
        ])
        #expect(payload?.accountID == "icloud")
        #expect(payload?.folderID == "inbox")
        #expect(payload?.name == "Inbox")
        #expect(payload?.role == "inbox")
        #expect(payload?.total == 12)
        #expect(payload?.unseen == 3)
        #expect(payload?.flagged == 1)
        #expect(payload?.id == "icloud|inbox")
    }

    @Test("Scan item decodes a spam_miss finding")
    func scanItem() {
        let payload = MailScanItemPayload.fromJSON([
            "account_id": "icloud",
            "mailbox": "Junk",
            "uid": "42",
            "from": "Prof. Wu",
            "from_address": "wu@nyu.edu",
            "subject": "Q2 deadline",
            "date": 1_700_000_000.0,
            "snippet": "",
            "importance": 5,
            "category": "academic",
            "confidence": 0.87,
            "reason": "deadline today",
        ])
        #expect(payload?.mailbox == "Junk")
        #expect(payload?.uid == "42")
        #expect(payload?.displayName == "Prof. Wu")
        #expect(payload?.importance == 5)
        #expect(payload?.category == "academic")
        #expect(payload?.confidencePercent == 87)
        #expect(payload?.reason == "deadline today")
        #expect(payload?.id == "icloud|Junk|42")
    }

    @Test("Scan item falls back to address when name is empty")
    func scanItemFallsBackToAddress() {
        let payload = MailScanItemPayload.fromJSON([
            "uid": "1",
            "from": "",
            "from_address": "no-reply@bank.com",
        ])
        #expect(payload?.displayName == "no-reply@bank.com")
    }

    @Test("Scan item without a uid is dropped")
    func scanItemRequiresUid() {
        #expect(MailScanItemPayload.fromJSON(["subject": "Hi"]) == nil)
    }

    @Test("Scan summary decodes totals and both finding lists")
    func scanSummary() {
        let payload = MailScanSummaryPayload.fromJSON([
            "folders": [[
                "account_id": "icloud", "id": "inbox", "name": "Inbox",
                "role": "inbox", "total": 12, "unseen": 3, "flagged": 1,
            ]],
            "unread_total": 3,
            "flagged_total": 4,
            "important": [["uid": "9", "from": "Sarah", "confidence": 0.9]],
            "spam_miss": [["uid": "42", "from": "Prof. Wu", "mailbox": "Junk"]],
            "scanned_at": 1_700_000_000.0,
        ])
        #expect(payload?.folders.count == 1)
        #expect(payload?.unreadTotal == 3)
        #expect(payload?.flaggedTotal == 4)
        #expect(payload?.important.count == 1)
        #expect(payload?.spamMiss.count == 1)
        #expect(payload?.scannedAt == 1_700_000_000)
    }

    @Test("Scan summary without folders is not parseable")
    func scanSummaryRequiresFolders() {
        #expect(MailScanSummaryPayload.fromJSON(["unread_total": 3]) == nil)
    }

    // MARK: - Settings

    @Test("Settings decode the wire shape")
    func settings() {
        let payload = MailSettingsPayload.fromJSON([
            "scan_frequency_minutes": 30,
            "signatures": ["icloud": "— Carlton"],
            "draft_tone": "casual",
            "auto_learn_sent": false,
            "excluded_folders": ["archive"],
            "notify_on_important": true,
            "learned_phrase_count": 7,
        ])
        #expect(payload?.scanFrequencyMinutes == 30)
        #expect(payload?.signatures["icloud"] == "— Carlton")
        #expect(payload?.draftTone == "casual")
        #expect(payload?.autoLearnSent == false)
        #expect(payload?.excludedFolders == ["archive"])
        #expect(payload?.learnedPhraseCount == 7)
    }

    @Test("Settings without a frequency is not parseable")
    func settingsRequireFrequency() {
        #expect(MailSettingsPayload.fromJSON(["draft_tone": "casual"]) == nil)
    }

    @Test("Settings params only carry the edited fields")
    func settingsParamsEditOnly() {
        var settings = MailSettingsPayload()
        settings.scanFrequencyMinutes = 60
        settings.draftTone = "formal"
        let params = settings.params(editing: ["frequency"])
        #expect(params["scan_frequency_minutes"] as? Int == 60)
        #expect(params["draft_tone"] == nil)
    }

    @Test("Settings params carry the signature for the first account")
    func settingsParamsSignature() {
        var settings = MailSettingsPayload()
        settings.signatures = ["icloud": "— Carlton"]
        let params = settings.params(editing: ["signature"])
        #expect(params["signature_account"] as? String == "icloud")
        #expect(params["signature"] as? String == "— Carlton")
    }
}
