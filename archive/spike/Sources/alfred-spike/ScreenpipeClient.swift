import Foundation

/// Thin client for the local Screenpipe REST API (default http://localhost:3030).
/// Phase 0 goal: prove we can pull real OCR/transcript memory out of Screenpipe.
struct ScreenpipeClient {
    var baseURL = URL(string: "http://localhost:3030")!

    struct Memory {
        let type: String        // "OCR" | "Audio"
        let text: String
        let app: String?
        let timestamp: String?
    }

    /// Search recent captured content. `contentType` is "ocr", "audio", or "all".
    func search(query: String = "", contentType: String = "all", limit: Int = 5) async throws -> [Memory] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "content_type", value: contentType),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let data = try await HTTP.get(comps.url!, timeout: 15)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = (json?["data"] as? [[String: Any]]) ?? []

        return items.compactMap { item in
            let type = (item["type"] as? String) ?? "?"
            let content = item["content"] as? [String: Any]
            // OCR rows carry `text`; audio rows carry `transcription`.
            let text = (content?["text"] as? String)
                ?? (content?["transcription"] as? String)
                ?? ""
            let app = content?["app_name"] as? String
            let ts = content?["timestamp"] as? String
            return Memory(type: type, text: text, app: app, timestamp: ts)
        }
    }

    func status() async -> (up: Bool, detail: String) {
        let url = baseURL.appendingPathComponent("health")
        do {
            _ = try await HTTP.get(url, timeout: 5)
            return (true, "reachable")
        } catch {
            return (false, "screenpipe unreachable on \(baseURL.absoluteString): \(error)")
        }
    }
}
