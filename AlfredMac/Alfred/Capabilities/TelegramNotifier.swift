import Foundation

/// Proactive push to the owner's Telegram chat — "Alfred texting first" (departure nudges, routine
/// outputs). Reads config straight from Keychain + UserDefaults so any component can call it without
/// holding the bot instance. No-op if the Telegram bot isn't enabled or configured.
enum TelegramNotifier {
    static func send(_ text: String) async {
        guard UserDefaults.standard.bool(forKey: "telegramBotEnabled") else { return }
        guard let token = KeychainHelper.load(service: "com.alfred.app", account: "telegram")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        let chatID = (UserDefaults.standard.string(forKey: "telegramOwnerChatID") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !chatID.isEmpty, let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }

        for chunk in chunked(text) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": chatID, "text": chunk])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Splits into ≤`max`-char chunks (Telegram's 4096 limit), preferring newline/space breaks.
    private static func chunked(_ text: String, max: Int = 4000) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.count > max else { return [text] }
        var out: [String] = []
        var remaining = Substring(text)
        while remaining.count > max {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: max)
            let slice = remaining[..<hardEnd]
            let cut = slice.lastIndex(of: "\n") ?? slice.lastIndex(of: " ") ?? hardEnd
            let piece = String(remaining[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            remaining = remaining[cut...].drop(while: { $0 == "\n" || $0 == " " })
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
