//
//  TailscaleConnection.swift
//  Alfred Companion
//
//  Ported from the iOS app (Alfred/Alfred/Services/TailscaleConnection.swift).
//  Finding the Mac without asking the owner to type an IP.
//
//  Discovery is layered, from most to least automatic:
//
//    1. mDNS / Bonjour — browse for `_alfred._tcp` on the local network.
//    2. Hostname fallbacks — `alfred.local` and `alfred`, resolved via a real
//       TCP connect so a name that doesn't exist fails fast.
//    3. Manual entry — the Settings field. Always the last resort.
//

import Foundation
import Network

struct TailscaleConnection {

    /// The Bonjour service type the Mac's ACP socket advertises.
    static let serviceType = "_alfred._tcp"

    /// Hostnames to try when the Bonjour resolve finds nothing. These only work
    /// if the Mac's hostname happens to be set to them — the Bonjour instance
    /// name ("alfred") is *not* a resolvable host — but a machine literally named
    /// "alfred" (or a MagicDNS short name) would answer here.
    static let hostCandidates = ["alfred.local", "alfred"]

    /// How long to wait for the mDNS resolve round before falling back. mDNS
    /// answers arrive in well under a second when a service is present, so four
    /// seconds is generous — but bounded, because discovery shouldn't block the
    /// UI forever when the Mac is asleep.
    static let browseTimeout: TimeInterval = 4

    // MARK: - Discovery

    /// Find Alfred's Mac and the port its socket listens on.
    ///
    /// Resolves the advertised `_alfred._tcp` Bonjour service to the Mac's real
    /// hostname first (bounded), then falls back to the hostname candidates.
    /// Returns nil when nothing answers — the caller then falls back to the
    /// manual Settings field.
    func discoverAlfredOnTailscale() async -> (host: String, port: Int)? {
        if let resolved = await resolveMDNSService() {
            return resolved
        }
        for candidate in Self.hostCandidates {
            if await canConnect(host: candidate, port: AlfredWebSocketClient.defaultPort) {
                return (candidate, AlfredWebSocketClient.defaultPort)
            }
        }
        return nil
    }

    /// Is this host a bare IP address? On iOS, ATS refuses plain `ws://`
    /// connections to IP literals, so the caller resolves an IP pin to the
    /// Mac's Bonjour name instead. Kept for parity with the iOS client — on
    /// macOS the same resolution keeps a pinned IP working over Tailscale.
    static func isIPLiteral(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") { return true }   // IPv6
        let parts = trimmed.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    /// The endpoint the app should actually connect to.
    ///
    /// A hostname is returned unchanged. A bare IP is redirected through
    /// discovery to find the Mac's Bonjour name first; the pinned IP is the
    /// fallback when discovery finds nothing. Loopback is unambiguous, so it is
    /// never redirected.
    func resolveSocketEndpoint(manualHost: String, port: Int) async -> (host: String, port: Int)? {
        let raw = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard !Self.isLoopback(raw) else { return (raw, port) }
        guard Self.isIPLiteral(raw) else { return (raw, port) }
        if let discovered = await discoverAlfredOnTailscale() {
            return discovered
        }
        return (raw, port)
    }

    /// Loopback addresses always mean "this device" — no discovery override
    /// should ever redirect them.
    static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "::1"
            || host == "127.0.0.1"
            || host.hasPrefix("127.")
    }

    // MARK: - Validation

    /// Prove a host:port is really Alfred's Mac, not just something listening.
    /// Opens a socket, sends a JSON-RPC `ping`, and counts *any* reply as a pass
    /// — a live ACP endpoint answers ping with a "method not found" error (-32601)
    /// by design, which is still a reply.
    func validateConnection(host: String, port: Int) async -> Bool {
        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { address = "localhost" }
        guard let url = URL(string: "ws://\(address):\(port)") else { return false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: url)
        socket.resume()

        defer { socket.cancel(with: .goingAway, reason: nil) }

        do {
            let ping: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [:]]
            guard let data = try? JSONSerialization.data(withJSONObject: ping),
                  let text = String(data: data, encoding: .utf8) else { return false }
            try await socket.send(.string(text))
            // Any frame — a result, an error, even a notification — proves the
            // socket speaks our protocol. An empty/closed socket throws instead.
            _ = try await socket.receive()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Persistence

    /// Remember a working host so discovery doesn't have to run every launch.
    func save(host: String, port: Int) {
        AppSettings.persistSocketHost(host, port: port)
    }

    // MARK: - mDNS

    /// Resolve the advertised `_alfred._tcp` service to the Mac's actual
    /// hostname and port, via NetService.
    private func resolveMDNSService() async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let service = NetService(
                domain: "local.",
                type: Self.serviceType + ".",
                name: "alfred")   // the server's fixed instance name
            let gate = OnceGate()
            let resolver = MDNSResolver(service: service) { host, port in
                guard gate.claim() else { return }
                continuation.resume(returning: host.map { ($0, port) })
            }
            resolver.start(timeout: Self.browseTimeout)
            // Hard safety net: whatever happens inside the resolver, the
            // continuation is guaranteed exactly one resume. Discovery must
            // never hang the launch.
            Task { @Sendable in
                try? await Task.sleep(nanoseconds: UInt64((Self.browseTimeout + 1) * 1_000_000_000))
                guard !Task.isCancelled, gate.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - TCP reachability

    /// Can we open a TCP connection to `host:port` within a couple of seconds?
    /// Used to validate hostname candidates without needing the full protocol
    /// handshake. Bounded by a hard deadline so a name that never resolves can't
    /// hang discovery.
    private func canConnect(host: String, port: Int) async -> Bool {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: NWParameters()
        )
        connection.start(queue: .main)

        // `.waiting` (no route yet) is a legal long-lived state, so a plain
        // state-switch continuation could block forever. Resolve on either a
        // terminal state or a 3s deadline — the timeout cancels the connection,
        // which drives the state handler to `.cancelled`.
        let timeout = Task { [weak connection] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let connection, !Task.isCancelled else { return }
            connection.cancel()
        }

        // One-shot claim, only on *terminal* states: the handler fires several
        // times, and claiming on a transient state would swallow the only
        // resume. Resuming twice traps, so the first terminal state claims.
        let gate = OnceGate()
        defer { connection.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    let isTerminal: Bool
                    switch state {
                    case .ready, .failed, .cancelled: isTerminal = true
                    default: isTerminal = false
                    }
                    guard isTerminal, gate.claim() else { return }
                    timeout.cancel()
                    switch state {
                    case .ready:
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: error)
                    case .cancelled:
                        continuation.resume(throwing: URLError(.cancelled))
                    default:
                        break
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }
}

/// Resolves a known Bonjour service to its target hostname via NetService.
///
/// NetService holds its delegate *weakly*, so the resolver self-retains until
/// `finish` runs. The delegate callbacks arrive on the main run loop while the
/// timeout Task fires on a background thread, so the once-only claim is guarded
/// by a lock; the completion is called exactly once.
private final class MDNSResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService
    private let completion: (String?, Int) -> Void
    private let lock = NSLock()
    private var finished = false
    private var timeoutTask: Task<Void, Never>?
    private var selfRetain: MDNSResolver?

    init(service: NetService, completion: @escaping (String?, Int) -> Void) {
        self.service = service
        self.completion = completion
        super.init()
    }

    func start(timeout: TimeInterval) {
        selfRetain = self   // keep alive until finish
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: timeout)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(host: nil)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // The SRV target host, e.g. "Carltons-MacBook-Pro.local." — strip the
        // trailing dot so URL(string:) and the resolver accept it.
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        finish(host: host)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(host: nil)
    }

    private func finish(host: String?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        timeoutTask?.cancel()
        service.stop()
        completion(host, service.port)
        selfRetain = nil   // allow dealloc now that the resolve is done
    }
}

/// A once-only claim flag, safe to hand across closures. Claimed from
/// @Sendable NWConnection/NetService callbacks, so it's explicitly
/// nonisolated and lock-guarded.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true the first time, false every call after.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
