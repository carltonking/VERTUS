//
//  ChatStore.swift
//  Alfred
//
//  The conversation, and the one job of getting a message to Alfred and back.
//
//  The transcript is kept on disk so closing the app doesn't lose the thread. It is *only* on disk:
//  api/app.ts is stateless and takes a single `text` per call, so the phone's history is a record of
//  what was said, not context Alfred is reasoning over. Worth knowing before wondering why he
//  doesn't remember three messages ago.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [Message] = []
    private(set) var isThinking = false

    /// What the user is typing. Lives here so it survives the composer being torn down.
    var draft: String = ""

    private let client = AlfredClient()
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("conversation.json")
        load()
    }

    // MARK: - Sending

    func send(_ text: String, settings: AppSettings) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        append(Message(role: .user, text: trimmed))
        await deliver(trimmed, settings: settings)
    }

    /// Re-send the prompt behind a failed turn, replacing the error in place so a flaky network
    /// doesn't litter the transcript with dead ends.
    func retry(_ message: Message, settings: AppSettings) async {
        guard let prompt = message.failedPrompt, !isThinking else { return }
        messages.removeAll { $0.id == message.id }
        save()
        await deliver(prompt, settings: settings)
    }

    private func deliver(_ prompt: String, settings: AppSettings) async {
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await client.send(prompt, to: settings.endpoint, token: settings.token)
            append(Message(role: .alfred, text: reply))
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            append(Message(role: .error, text: description, failedPrompt: prompt))
        }
    }

    // MARK: - Transcript

    func clear() {
        messages.removeAll()
        save()
    }

    private func append(_ message: Message) {
        messages.append(message)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        messages = (try? JSONDecoder().decode([Message].self, from: data)) ?? []
    }

    private func save() {
        // A transcript that fails to save is not worth interrupting the user over — the conversation
        // on screen is still correct, and the next successful write heals it.
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
