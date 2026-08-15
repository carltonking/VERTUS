import CryptoKit
import Foundation

// MARK: - Image finder
//
// Finds a relevant image for a slide using the Wikipedia pageimages API:
// search the topic phrase → take the top article → fetch its lead thumbnail.
// Keyless, reliable for the academic/business topics a deck covers, and the
// thumbnails are small (800px). When nothing is found the slide simply goes
// image-free — the designers already lay out gracefully without one.
//
// The pure URL/parse helpers are static so the test suite exercises them
// without touching the network.

struct FoundImage: Sendable {
    let data: Data
    let ext: String
    let mime: String
}

struct ImageFinder {

    /// Wikipedia API base for pageimage lookups.
    static let apiBase = "https://en.wikipedia.org/w/api.php"

    /// Search URL for the topic phrase (top article).
    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: apiBase)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// Thumbnail URL for a known article title.
    static func thumbnailURL(for title: String, size: Int = 800) -> URL? {
        var components = URLComponents(string: apiBase)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "pithumbsize", value: String(size)),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// Pull `query.search[0].title` out of a search response.
    static func topSearchResult(from json: [String: Any]) -> String? {
        guard let query = json["query"] as? [String: Any],
              let results = query["search"] as? [[String: Any]],
              let first = results.first,
              let title = first["title"] as? String,
              !title.isEmpty
        else { return nil }
        return title
    }

    /// Pull `query.pages.<page>.thumbnail.source` out of a pageimages response.
    /// The page key is a stringified numeric id in JSON.
    static func thumbnailSource(from json: [String: Any]) -> String? {
        guard let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any]
        else { return nil }
        for (_, pageValue) in pages {
            guard let page = pageValue as? [String: Any],
                  let thumbnail = page["thumbnail"] as? [String: Any],
                  let source = thumbnail["source"] as? String,
                  !source.isEmpty
            else { continue }
            return source
        }
        return nil
    }

    /// Classify a thumbnail URL into a usable (ext, mime), or nil for
    /// formats we can't embed (SVG, WebP).
    static func imageKind(for urlString: String) -> (ext: String, mime: String)? {
        let lower = urlString.lowercased()
        if lower.contains(".jpg") || lower.contains(".jpeg") {
            return ("jpg", "image/jpeg")
        }
        if lower.contains(".png") {
            return ("png", "image/png")
        }
        return nil
    }

    /// Find + download an image for a topic phrase. Cached on disk by query
    /// hash so repeat decks don't re-fetch. Returns nil on any failure — the
    /// deck proceeds image-free.
    static func find(query: String) async -> FoundImage? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Disk cache.
        if let cached = cachedImage(for: trimmed) { return cached }

        guard let searchURL = searchURL(for: trimmed) else { return nil }
        guard let searchJSON = await fetchJSON(searchURL) else { return nil }
        guard let title = topSearchResult(from: searchJSON),
              let thumbURL = thumbnailURL(for: title),
              let thumbJSON = await fetchJSON(thumbURL)
        else { return nil }
        guard let source = thumbnailSource(from: thumbJSON),
              let kind = imageKind(for: source),
              let url = URL(string: source)
        else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty
        else { return nil }

        let image = FoundImage(data: data, ext: kind.ext, mime: kind.mime)
        store(image: image, for: trimmed)
        return image
    }

    // MARK: - Plumbing

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Alfred/1.0 (presentation generator)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Cache

    private static func cacheDirectory() -> String {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred/presentation_images")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir as String
    }

    private static func cacheURL(for query: String) -> URL? {
        guard let data = query.data(using: .utf8) else { return nil }
        let digest = Insecure.SHA1.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: (cacheDirectory() as NSString).appendingPathComponent("\(hex).img"))
    }

    private static func cachedImage(for query: String) -> FoundImage? {
        guard let url = cacheURL(for: query), let data = try? Data(contentsOf: url),
              let kind = imageKind(for: url.lastPathComponent)
        else { return nil }
        // Detect ext from the stored payload's first bytes is overkill; the
        // cache file stores the ext in its name via a marker. Simplest: the
        // cached file is a PNG unless named .jpg.
        let ext = url.lastPathComponent.hasSuffix(".jpg") ? "jpg" : "png"
        let mime = ext == "jpg" ? "image/jpeg" : "image/png"
        _ = kind
        return FoundImage(data: data, ext: ext, mime: mime)
    }

    private static func store(image: FoundImage, for query: String) {
        guard let url = cacheURL(for: query) else { return }
        // Encode the ext in the filename so the cache knows what it holds.
        let base = (url.path as NSString).deletingPathExtension
        let target = URL(fileURLWithPath: base + "." + image.ext)
        try? image.data.write(to: target)
        try? FileManager.default.removeItem(at: url)
    }
}
