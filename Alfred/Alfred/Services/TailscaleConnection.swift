//
//  TailscaleConnection.swift
//  Alfred
//
//  Finding the Mac without asking the owner to type an IP.
//
//  Discovery is layered, from most to least automatic:
//
//    1. mDNS / Bonjour — browse for `_alfred._tcp` on the local network. This is
//       what finds the Mac when both devices are on the same Wi-Fi, and also when
//       they're joined through Tailscale (the tailnet carries mDNS to every node,
//       so the advertised service shows up either way).
//    2. Hostname fallbacks — `alfred.local` (the classic mDNS name) and `alfred`
//       (Tailscale MagicDNS short name). Resolved via a real TCP connect, so a
//       name that doesn't exist fails fast instead of hanging.
//    3. Manual entry — the Settings field. Always the last resort, always
//       available.
//
//  Nothing here requires the `tailscale` CLI on the phone: Tailscale's magic is
//  that the Mac's addresses are just reachable IPs once the phone is on the
//  tailnet. The phone only needs local-network permission to *browse* for it.
//

import Foundation
import Network

struct TailscaleConnection {

    /// The Bonjour service type the Mac's ACP socket advertises.
    static let serviceType = "_alfred._tcp"

    /// Hostnames to try when the Bonjour resolve finds nothing. These only work
    /// if the Mac's hostname happens to be set to them — the Bonjour instance
    /// name ("alfred") is *not* a resolvable host — but a machine literally named
    /// "alfred" (or a MagicDNS short name) would answer here. The real discovery
    /// path resolves the service's SRV target, which is the Mac's LocalHostName.
    /// Nonisolated: read from the background discovery task.
    nonisolated static let hostCandidates = ["alfred.local", "alfred"]

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
    /// manual Settings field. Nonisolated: called from a background discovery task.
    nonisolated func discoverAlfredOnTailscale() async -> (host: String, port: Int)? {
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

    /// Is this host a bare IP address? ATS on current iOS refuses plain `ws://`
    /// connections to IP literals no matter which plist exception is set, while
    /// hostname forms (`.local`, unqualified MagicDNS names) are allowed — so
    /// the caller resolves an IP pin to the Mac's Bonjour name instead.
    nonisolated static func isIPLiteral(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") { return true }   // IPv6
        let parts = trimmed.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }

    /// The endpoint the phone should actually connect to.
    ///
    /// A hostname is returned unchanged — it is already ATS-legal. A bare IP is
    /// ATS-blocked for `ws://`, so discovery runs to find the Mac's Bonjour name
    /// and that name is preferred; the pinned IP is the fallback when discovery
    /// finds nothing (the reconnect loop keeps trying either way). Loopback is
    /// ATS-exempt and unambiguous, so it is never redirected.
    nonisolated func resolveSocketEndpoint(manualHost: String, port: Int) async -> (host: String, port: Int)? {
        let raw = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard !Self.isLoopback(raw) else { return (raw, port) }
        guard Self.isIPLiteral(raw) else { return (raw, port) }
        if let discovered = await discoverAlfredOnTailscale() {
            return discovered
        }
        return (raw, port)
    }

    /// Loopback addresses are ATS-exempt and always mean "this device" — no
    /// discovery override should ever redirect them.
    nonisolated static func isLoopback(_ host: String) -> Bool {
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
    nonisolated func validateConnection(host: String, port: Int) async -> Bool {
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
    /// Mirrors how the relay host is kept; the socket host is plain UserDefaults
    /// (no secret to protect). Nonisolated because discovery runs off the main actor.
    nonisolated func save(host: String, port: Int) {
        AppSettings.persistSocketHost(host, port: port)
    }

    // MARK: - mDNS

    /// Resolve the advertised `_alfred._tcp` service to the Mac's actual
    /// hostname and port, via NetService.
    ///
    /// The service's *instance* name ("alfred") is not a resolvable hostname —
    /// `alfred.local` does not exist on the network. The resolvable name is the
    /// service's SRV *target*, the Mac's LocalHostName (e.g.
    /// `Carltons-MacBook-Pro.local`), which only a resolve() reveals. Both the
    /// LAN path and Tailscale's mDNS proxy answer this.
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
            // Hard safety net: whatever happens inside the resolver (delegate
            // callbacks never arriving, an edge in NetService), the continuation
            // is guaranteed exactly one resume — the gate above makes a second
            // resume impossible. Discovery must never hang the launch.
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
    /// handshake.
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
        // times (`.preparing`, possibly `.waiting`, then `.ready`/`.failed`/
        // `.cancelled`), and claiming on a transient state would swallow the
        // only resume. Resuming twice traps, so the first terminal state claims
        // and every later delivery (e.g. our own cancel after `.ready`) returns.
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
/// `finish` runs — without that it would deallocate the moment the creating
/// closure returned, and neither the delegate callback nor the timeout could
/// ever fire. The delegate callbacks arrive on the main run loop while the
/// timeout Task fires on a background thread, so the once-only claim is guarded
/// by a lock; the completion is called exactly once.
/// `@unchecked Sendable`: the instance crosses a Task boundary, and the only
/// shared mutable state is lock-guarded.
private nonisolated final class MDNSResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
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

/// A once-only claim flag, safe to hand across closures. Everything here runs on
/// the main queue, so a plain Bool would do — but a *captured* Bool trips the
/// concurrency checker ("mutation of captured var in concurrently-executing
/// code"), while a class reference does not.
/// Nonisolated: claimed from @Sendable NWBrowser/NWConnection callbacks, so it
/// must not inherit the project's default MainActor isolation.
private nonisolated final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Returns true the first time, false every call after. Lock-guarded: claimed
    /// from the mDNS resolve completion and the safety-net Task on different
    /// threads.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
