//
//  QuickCommands.swift
//  Alfred
//
//  Bypasses LLM entirely for basic commands
//

import Foundation
import AppKit

struct QuickCommands {
    
    static func handle(_ query: String) -> String? {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Integration tokens: "set <service> token <token>". Stores in Keychain and bypasses the
        // LLM + conversation history so the secret is never echoed back or persisted to memory.
        if lower.hasPrefix("set "), lower.contains(" token ") {
            return handleSetToken(query)
        }

        // App opening - check if query STARTS WITH "open" or just contains the app name
        if lower.hasPrefix("open ") || lower == "messages" {
            // Extract app name - remove "open " prefix if present
            var appName = lower
            if lower.hasPrefix("open ") {
                appName = String(lower.dropFirst(5))
            }
            
            // Map common names
            let appMappings: [(key: String, bundleId: String)] = [
                ("messages", "Messages"),
                ("safari", "Safari"),
                ("chrome", "Google Chrome"),
                ("mail", "Mail"),
                ("notes", "Notes"),
                ("calendar", "Calendar"),
                ("music", "Music"),
                ("photos", "Photos"),
                ("terminal", "Terminal"),
                ("finder", "Finder")
            ]
            
            // Check if appName matches any key in mappings
            for (key, bundleId) in appMappings {
                if appName == key || appName.contains(key) {
                    openApp(bundleId: bundleId, path: getPath(for: bundleId))
                    return "Opening \(bundleId)..."
                }
            }
            
            // Try to open by name directly
            let capitalized = appName.capitalized
            openApp(bundleId: nil, path: "/Applications/\(capitalized).app")
            return "Opening \(capitalized)..."
        }

        // "What do you know about me?" and close variants — answer from the local Hermes profile
        // (honest when empty), bypassing the LLM so there's no chance to fabricate.
        if lower.contains("what do you know about me")
            || lower.contains("what have you learned about me")
            || lower.contains("tell me about myself")
            || lower.contains("what's my profile") || lower.contains("what is my profile")
            || lower.contains("describe me")
            || lower == "what do you know" {
            return ProfileDigest.whatDoYouKnow()
        }

        // Apple Notes (local AppleScript, zero-auth): create / search / list. Pass the ORIGINAL
        // query so note content keeps its capitalization.
        if let notesAction = NotesCapability.detect(query) {
            return NotesCapability.handle(notesAction)
        }

        // Spotify control (local AppleScript, zero-auth): pause / next / now-playing / volume.
        // Instant + reliable, bypassing the LLM. Search-by-name ("play <song>") needs an async
        // network call, so when credentials exist we fall through to the async handler in
        // AssistantCore; otherwise we answer synchronously here.
        if let spotifyAction = SpotifyCapability.detect(lower) {
            if !(spotifyAction == .searchUnsupported && SpotifyCapability.hasCredentials) {
                return SpotifyCapability.handle(spotifyAction)
            }
        }

        return nil
    }
    
    /// Parses "set <service> token <token>" from the ORIGINAL query (preserving token case),
    /// stores it in the Keychain, and returns a masked confirmation. Returns nil if it can't parse.
    private static func handleSetToken(_ query: String) -> String? {
        // Known integrations → Keychain account name. Add a line here per new paste-key app.
        let accounts: [String: String] = [
            "github": GitHubCapability.keychainAccount,
            "notion": NotionCapability.keychainAccount,
            "spotify": SpotifyCapability.keychainAccount,
            "microsoft": MicrosoftAuth.keychainClientID,
            "google": GoogleAuth.keychainCreds,
        ]

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Words: ["set", "<service>", "token", "<token...>"]
        let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4,
              parts[0].lowercased() == "set",
              parts[2].lowercased() == "token"
        else {
            return "To connect an app: set <service> token <your-token>. Supported: \(accounts.keys.sorted().joined(separator: ", "))."
        }

        let service = parts[1].lowercased()
        // Strip whitespace and any surrounding <angle brackets> the user copied from the placeholder.
        let token = String(parts[3])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = accounts[service] else {
            return "I don't have a \(service) integration yet. Supported: \(accounts.keys.sorted().joined(separator: ", "))."
        }
        guard !token.isEmpty else { return "No token provided." }

        let ok = KeychainHelper.save(service: "com.alfred.app", account: account, value: token)
        guard ok else { return "Couldn't save the \(service) token to the Keychain." }

        let masked = token.count > 8 ? "\(token.prefix(4))…\(token.suffix(4))" : "saved"
        return "\(service.capitalized) connected (token \(masked)). Try: \"what are my open \(service) PRs?\""
    }

    private static func openApp(bundleId: String?, path: String) {
        if let bundleId = bundleId,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
            app.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
    
    private static func getPath(for bundleId: String) -> String {
        switch bundleId {
        case "Messages": return "/System/Applications/Messages.app"
        case "Safari": return "/System/Applications/Safari.app"
        case "Google Chrome": return "/Applications/Google Chrome.app"
        case "Mail": return "/System/Applications/Mail.app"
        case "Notes": return "/System/Applications/Notes.app"
        case "Calendar": return "/System/Applications/Calendar.app"
        case "Music": return "/System/Applications/Music.app"
        case "Photos": return "/System/Applications/Photos.app"
        case "Terminal": return "/System/Applications/Utilities/Terminal.app"
        case "Finder": return "/System/Library/CoreServices/Finder.app"
        default: return "/Applications/\(bundleId).app"
        }
    }
    
}
