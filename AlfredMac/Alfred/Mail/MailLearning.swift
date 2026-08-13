//
//  MailLearning.swift
//  Alfred
//
//  The sent-mail learning loop: every message the owner actually sends folds
//  into the writing-style profile (the same exponential moving average the bar
//  uses), so drafts keep matching what they really write — not what a generic
//  model thinks they write. Also counts learned messages for the "Revisions
//  available" badge in settings.
//
//  Wired from the socket server's mail.send / mail.reply success paths.
//

import Foundation

final class MailLearningService {

    static let shared = MailLearningService()

    private init() {}

    /// Fold a sent message into the style profile. Gated on the auto-learn
    /// setting; never throws, never blocks — profile updates are lightweight.
    func observeSent(subject: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let settings = MailSettingsStore.shared.current
        guard settings.autoLearnSent else { return }

        // The style service EMA-blends the message; a wordless or all-emoji
        // body yields an empty analysis and is skipped internally.
        WritingStyleService.shared.saveProfileFromQuery(trimmed)
        MailSettingsStore.shared.update { $0.learnedPhraseCount += 1 }
        NSLog("[mail-learning] learned from a sent message (%@)", subject)
    }
}
