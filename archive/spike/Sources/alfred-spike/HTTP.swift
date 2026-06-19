import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal async HTTP helper built on URLSession — no third-party deps.
enum HTTP {
    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
    }

    static func get(_ url: URL, timeout: TimeInterval = 30) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        return try await send(req)
    }

    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval = 120) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Error(description: "no HTTP response from \(req.url?.absoluteString ?? "?")")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw Error(description: "HTTP \(http.statusCode) from \(req.url?.absoluteString ?? "?"): \(snippet)")
        }
        return data
    }
}
