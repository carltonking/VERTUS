import Foundation

/// Wire events from the VERTUS hub (vertus/server/vertus_server.py).
enum VertusEvent: Equatable {
    case text(String)
    case activity(String)
    case done
    case error(String)
}

/// Thin client for the VERTUS hub: POST /api/prompt + GET /api/events (SSE).
final class VertusClient {
    var baseURL: URL
    var token: String
    private var streamTask: Task<Void, Never>?

    init(baseURL: URL = URL(string: "http://100.84.144.109:8787")!, token: String = "") {
        self.baseURL = baseURL
        self.token = token
    }

    var isConfigured: Bool { !token.isEmpty }

    /// True when the hub answers /api/health.
    func checkHealth() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Open the SSE stream (kept alive per hub request; the hub closes it
    /// after the turn ends), then submit the prompt.
    /// Events are delivered on the supplied callback (main-thread-safe).
    func send(_ text: String, onEvent: @escaping (VertusEvent) -> Void) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.openEventStream(onEvent: onEvent)
            guard let events else {
                onEvent(.error("Could not reach the VERTUS hub"))
                return
            }
            do {
                let accepted = try await self.postPrompt(text)
                if !accepted {
                    onEvent(.error("Hub did not accept the prompt"))
                    return
                }
                var done = false
                for try await event in events {
                    if Task.isCancelled { break }
                    onEvent(event)
                    if case .done = event { done = true; break }
                    if case .error = event { done = true; break }
                }
                if !done { onEvent(.error("Stream ended unexpectedly")) }
            } catch {
                onEvent(.error(error.localizedDescription))
            }
        }
    }

    func cancel() { streamTask?.cancel(); streamTask = nil }

    private func postPrompt(_ text: String) async throws -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("phone", forHTTPHeaderField: "X-Vertus-Client")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 202
    }

    private func openEventStream(
        onEvent: @escaping (VertusEvent) -> Void
    ) async -> AsyncThrowingStream<VertusEvent, Error>? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/events"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        guard let (bytes, resp) = try? await URLSession.shared.bytes(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        switch obj["type"] as? String {
                        case "text":
                            if let t = obj["text"] as? String { continuation.yield(.text(t)) }
                        case "activity":
                            if let t = obj["text"] as? String { continuation.yield(.activity(t)) }
                        case "done":
                            continuation.yield(.done)
                            continuation.finish()
                        case "error":
                            let m = obj["message"] as? String ?? "hub error"
                            continuation.yield(.error(m))
                            continuation.finish()
                        default:
                            break
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
