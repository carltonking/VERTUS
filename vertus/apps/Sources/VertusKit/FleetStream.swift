import Foundation

/// One SSE connection to GET /api/events (fleet stream: no agent_id filter),
/// with:
///   - cursor resume: every processed event advances the persisted cursor;
///     reconnects send since=<cursor> so the server replays exactly the span
///     that was never delivered (no gap, no duplicate);
///   - `lagged` recovery: the hub drops a subscriber whose queue overflowed
///     but emits a `lagged` marker first; we reconnect immediately, and the
///     since=cursor replay covers the dropped span;
///   - reconnect with exponential backoff on any drop, surfacing the state
///     to the UI.
///
/// Events are delivered on `onEvent` (main-thread hop is the store's job;
/// this class calls it on the URLSession delegate queue via async loop).
public final class FleetStream: NSObject, ObservableObject {
    public enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(String)
    }

    @Published public private(set) var connectionState: ConnectionState = .idle

    /// Current hub config. Mutable only through apply(_:) so a config
    /// adoption always forces the reconnect that makes it effective.
    public private(set) var config: ServerConfig
    public let cursor: StreamCursor
    /// Called for every envelope, in order, exactly once.
    public var onEvent: ((WireEvent) -> Void)?
    /// Called with the agent id when a `lagged` marker was received.
    public var onLagged: ((String?) -> Void)?

    private var task: Task<Void, Never>?
    private var stopped = false
    private let maxBackoffSeconds: UInt64 = 10
    private let baseBackoffMilliseconds: UInt64 = 500

    /// Connection lifecycle is visible to the operator (this surfaced the
    /// phone's reconnect behavior in simulator testing): every state change
    /// and every connect with its since= cursor goes to os_log.
    private func log(_ message: String) {
        NSLog("[vertus-stream] %@", message)
    }

    public init(config: ServerConfig, cursor: StreamCursor) {
        self.config = config
        self.cursor = cursor
        super.init()
    }

    public func start() {
        guard task == nil else { return }
        stopped = false
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .idle
        }
    }

    /// Force an immediate reconnect with the current cursor (lagged recovery,
    /// or a UI-requested retry). The running loop tears down and restarts.
    public func reconnectNow() {
        task?.cancel()
        task = nil
        guard !stopped else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Adopt a new hub config (the launch-time one went stale — e.g. the
    /// app came up pointed at a port the hub no longer serves). Forces an
    /// immediate reconnect so the new URL/token takes effect now; the
    /// cursor carries over, so the since= replay still covers the gap.
    public func apply(_ newConfig: ServerConfig) {
        guard newConfig != config else { return }
        log("config adopted: \(newConfig.baseURL)")
        config = newConfig
        reconnectNow()
    }

    // MARK: - Connection loop

    private func runLoop() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            let state: ConnectionState = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
            await MainActor.run { self.connectionState = state }
            do {
                let terminated = try await connectOnce(attempt: attempt)
                // A clean terminal (run stream end / explicit server close)
                // is still a drop from the fleet client's perspective: the
                // hub closes connections after server restarts.
                if terminated { /* fall through to reconnect */ }
            } catch is CancellationError {
                return
            } catch {
                // Network error → backoff and retry.
            }
            if stopped || Task.isCancelled { return }
            attempt += 1
            let delay = backoff(for: attempt)
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func backoff(for attempt: Int) -> UInt64 {
        let exp = UInt64(1) << min(attempt, 5)          // 2, 4, 8, 16, 32
        return min(baseBackoffMilliseconds * exp * 1_000_000, maxBackoffSeconds * 1_000_000_000)
    }

    /// One connection attempt: build the since=<cursor> request, stream SSE
    /// lines until the connection dies, then return. Never throws on a normal
    /// drop; throws CancellationError when stopped.
    private func connectOnce(attempt: Int) async throws -> Bool {
        var urlComps = URLComponents(string: config.baseURL)!
        urlComps.path = "/api/events"
        // Resume from the persisted cursor. First launch (cursor == 0) sends
        // no since= so the store's whole history is NOT replayed into a fresh
        // client; transcripts rebuild from the messages endpoint instead.
        if cursor.hasSeenEvents {
            urlComps.queryItems = [URLQueryItem(name: "since", value: String(cursor.lastSeq))]
            log("connect since=\(cursor.lastSeq)")
        } else {
            log("connect (first launch, no since)")
        }
        guard let url = urlComps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, resp) = try await URLSession.shared.bytes(for: req)
        } catch {
            if Task.isCancelled || stopped { throw CancellationError() }
            log("connect threw: \(error.localizedDescription)")
            throw error
        }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        log("connected, draining from seq \(cursor.lastSeq)")
        await MainActor.run { self.connectionState = .connected }

        // Process lines until EOF/error/cancel.
        do {
            for try await line in bytes.lines {
                if Task.isCancelled || stopped { throw CancellationError() }
                guard line.hasPrefix("data: ") else { continue }   // : keepalive etc.
                let payload = line.dropFirst(6)
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = WireEvent(json: obj) else { continue }
                handle(event)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Connection dropped (server restart, network). Reconnect with
            // the persisted cursor — the replay covers the gap.
        }
        return true
    }

    private func handle(_ event: WireEvent) {
        if event.type == "lagged" {
            log("lagged marker (seq \(event.seq ?? -1)) — forcing reconnect")

            // The marker's seq is the OVERFLOWED event — never delivered —
            // so the cursor must NOT advance past it. Reconnect immediately
            // with since=<cursor>: the replay covers (cursor, ∞) including
            // the dropped span.
            onLagged?(event.agentId)
            Task { [weak self] in self?.reconnectNow() }
            return
        }
        // Advance the cursor BEFORE the consumer applies the event: if the
        // app dies mid-apply, the replay re-delivers it and the store's
        // run-dedup makes the re-apply idempotent.
        if let seq = event.seq {
            cursor.advance(to: seq)
        }
        onEvent?(event)
    }
}