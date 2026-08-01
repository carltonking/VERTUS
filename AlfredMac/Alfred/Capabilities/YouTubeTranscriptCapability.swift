import Foundation

struct YouTubeTranscriptCapability {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)
    }

    func transcript(forVideoURL rawURL: String) async throws -> String? {
        guard let videoID = videoID(from: rawURL) else { return nil }
        let watchURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!

        var request = URLRequest(url: watchURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)

        guard let html = String(data: data, encoding: .utf8),
              let captionURL = captionTrackURL(from: html)
        else { return nil }

        let (captionData, _) = try await session.data(from: captionURL)
        let captionXML = String(data: captionData, encoding: .utf8) ?? ""
        let transcript = decodeTranscriptXML(captionXML)

        return transcript.isEmpty ? nil : transcript
    }

    func videoID(from text: String) -> String? {
        let patterns = [
            #"youtu\.be/([A-Za-z0-9_-]{6,})"#,
            #"[?&]v=([A-Za-z0-9_-]{6,})"#,
            #"/shorts/([A-Za-z0-9_-]{6,})"#,
            #"/embed/([A-Za-z0-9_-]{6,})"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }

        return nil
    }

    private func captionTrackURL(from html: String) -> URL? {
        guard let tracksRange = html.range(of: #""captionTracks":"#) else { return nil }
        let tail = String(html[tracksRange.upperBound...])
        guard let endRange = tail.range(of: #"]"#) else { return nil }
        let tracksJSON = String(tail[..<endRange.upperBound])

        let baseURLMatches = matches(
            pattern: #""baseUrl":"((?:\\.|[^"\\])+)""#,
            in: tracksJSON
        )
        guard !baseURLMatches.isEmpty else { return nil }

        let languageMatches = matches(
            pattern: #""languageCode":"((?:\\.|[^"\\])+)""#,
            in: tracksJSON
        )

        let preferredIndex = languageMatches.firstIndex { raw in
            let language = unescapeJavaScriptString(raw)
            return language.hasPrefix("en")
        } ?? 0

        let rawURL = unescapeJavaScriptString(baseURLMatches[min(preferredIndex, baseURLMatches.count - 1)])
            .replacingOccurrences(of: "\\u0026", with: "&")

        return URL(string: rawURL)
    }

    private func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func decodeTranscriptXML(_ xml: String) -> String {
        let snippets = matches(pattern: #"<text[^>]*>(.*?)</text>"#, in: xml)
        return snippets
            .map(decodeHTMLEntities)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func unescapeJavaScriptString(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\""#, with: #"""#)
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\u0026"#, with: "&")

        let unicodePattern = #"\\u([0-9a-fA-F]{4})"#
        guard let regex = try? NSRegularExpression(pattern: unicodePattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let hexRange = Range(match.range(at: 1), in: result),
                  let scalar = UnicodeScalar(Int(result[hexRange], radix: 16) ?? 0)
            else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        // YouTube timedtext uses only the basic named entities plus numeric escapes, so decode them
        // directly instead of spinning up an NSAttributedString HTML (WebKit) importer per caption
        // line — that was multi-second and main-thread-affined over hundreds of segments. (Non-ASCII
        // arrives as numeric &#NNN;, so arbitrary named entities like &eacute; don't appear.)
        var result = text
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        // Numeric entities: &#NNN; (decimal) and &#xNN; (hex).
        if result.contains("&#"), let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let flagRange = Range(match.range(at: 1), in: result),
                      let numRange = Range(match.range(at: 2), in: result)
                else { continue }
                let isHex = !result[flagRange].isEmpty
                guard let code = Int(result[numRange], radix: isHex ? 16 : 10),
                      let scalar = UnicodeScalar(code) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Decode &amp; LAST so an entity like "&amp;lt;" resolves to "&lt;" rather than "<".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
