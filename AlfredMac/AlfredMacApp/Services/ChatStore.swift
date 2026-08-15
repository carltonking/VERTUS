//
//  ChatStore.swift
//  AlfredMacApp
//
//  Ported from the iOS app (Alfred/Alfred/Services/ChatStore.swift), with one
//  deliberate difference: on the Mac the conversation goes over the live
//  socket (`chat.send` on the Mac's BriefingSocketServer) instead of the cloud
//  relay — the companion talks to Alfred on the same machine.
//
//  The transcript is kept on disk so closing the app doesn't lose the thread.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {

    /// The single conversation — Home, Chat and the shell share it.
    static let shared = ChatStore()

    private(set) var messages: [Message] = []
    private(set) var isThinking = false

    /// What the user is typing. Lives here so it survives the composer being torn down.
    var draft: String = ""

    private var socket: AlfredWebSocketClient { .shared }
    private let fileURL: URL

    init() {
        // Scoped to an "Alfred Companion" folder so the transcript never lands
        // next to the Mac brain's own files in the shared Application Support.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Alfred Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("conversation.json")
        load()
    }

    // MARK: - Sending

    func send(_ text: String, settings: AppSettings) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        append(Message(role: .user, text: trimmed))
        await deliver(trimmed)
    }

    /// Re-send the prompt behind a failed turn, replacing the error in place so a flaky link
    /// doesn't litter the transcript with dead ends.
    func retry(_ message: Message, settings: AppSettings) async {
        guard let prompt = message.failedPrompt, !isThinking else { return }
        messages.removeAll { $0.id == message.id }
        save()
        await deliver(prompt)
    }

    private func deliver(_ prompt: String) async {
        isThinking = true
        defer { isThinking = false }

        do {
            // The Mac's server answers `chat.send` with `{ "reply": "..." }`.
            // Long timeout: a real turn reads the calendar and runs a model.
            let result = try await socket.sendCommand(
                name: "chat.send",
                params: ["text": prompt],
                timeout: 180)
            let reply = result["reply"] as? String ?? ""
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HermesSocketError.server("Alfred didn't answer.")
            }
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
