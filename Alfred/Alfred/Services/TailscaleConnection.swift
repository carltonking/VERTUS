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

    /// Hostnames to try when browsing finds nothing. `alfred.local` is the mDNS
    /// name; `alfred` is the Tailscale MagicDNS short name (both resolve to the
    /// Mac on a tailnet with MagicDNS enabled, which is the default).
    /// Nonisolated: read from the background discovery task.
    nonisolated static let hostCandidates = ["alfred.local", "alfred"]

    /// How long to wait for an mDNS browse round before falling back. mDNS
    /// answers arrive in well under a second when a service is present, so four
    /// seconds is generous — but bounded, because discovery shouldn't block the
    /// UI forever when the Mac is asleep.
    static let browseTimeout: TimeInterval = 4

    // MARK: - Discovery

    /// Find Alfred's Mac and the port its socket listens on.
    ///
    /// Tries Bonjour first (one bounded round), then the hostname candidates.
    /// Returns nil when nothing answers — the caller then falls back to the
    /// manual Settings field. Nonisolated: called from a background discovery task.
    nonisolated func discoverAlfredOnTailscale() async -> (host: String, port: Int)? {
        if let advertised = await browseMDNS() {
            return advertised
        }
        for candidate in Self.hostCandidates {
            if await canConnect(host: candidate, port: AlfredWebSocketClient.defaultPort) {
                return (candidate, AlfredWebSocketClient.defaultPort)
            }
        }
        return nil
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

    /// One bounded Bonjour browse for `_alfred._tcp`. Returns the first service
    /// found, or nil when the timer expires.
    ///
    /// A `.service` result carries the instance name (e.g. "Alfred's Mac") — that
    /// is the hostname, resolvable by the mDNS responder and, on a tailnet, by
    /// MagicDNS. The advertised port stays on the default: this SDK exposes no
    /// way to read a service's SRV record from a browse result (connecting to the
    /// `.service` endpoint to fish it out hangs in `.preparing`), and the Mac
    /// advertises on the default port anyway. A non-default deployment is a
    /// manual-entry case in Settings.
    private func browseMDNS() async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: params)
            // The browser, the timeout and the port resolution can all fire
            // "first" — a mutable Bool captured across those closures trips the
            // concurrency checker, so the once-only claim lives in a box instead.
            let gate = OnceGate()

            @Sendable func finish(_ result: (host: String, port: Int)?) {
                guard gate.claim() else { return }
                browser.cancel()
                continuation.resume(returning: result)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    finish((host: name, port: AlfredWebSocketClient.defaultPort))
                    return
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }

            browser.start(queue: .main)
            // Timeout as a Task, not DispatchQueue.asyncAfter: the latter needs a
            // running run loop to fire, which a plain async context doesn't have,
            // so an unanswered browse would leak its continuation forever. This
            // Task always fires (bounded), so the continuation is guaranteed a
            // resume even if the caller is cancelled meanwhile.
            Task { @Sendable in
                try? await Task.sleep(nanoseconds: UInt64(Self.browseTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                finish(nil)
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

/// A once-only claim flag, safe to hand across closures. Everything here runs on
/// the main queue, so a plain Bool would do — but a *captured* Bool trips the
/// concurrency checker ("mutation of captured var in concurrently-executing
/// code"), while a class reference does not.
/// Nonisolated: claimed from @Sendable NWBrowser/NWConnection callbacks, so it
/// must not inherit the project's default MainActor isolation.
private nonisolated final class OnceGate: @unchecked Sendable {
    private var claimed = false

    /// Returns true the first time, false every call after.
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}
