import Foundation
import os

/// Real unified-logging (os_log) channels for the provider request/response
/// path.
///
/// NSLog funnels through stderr and only surfaces in Console.app while the app
/// is attached to a debugger. `os.Logger` writes structured, filterable entries
/// into the unified log under a stable subsystem, so a provider outage can be
/// isolated without a debugger:
///
///     log stream --predicate 'subsystem == "com.alfred.app"'
///
/// or in Console.app by filtering on subsystem `com.alfred.app`.
enum AlfredLog {
    /// The bundle id Alfred ships under (scripts/build_app.sh BUNDLE_ID).
    static let subsystem = "com.alfred.app"

    /// Provider request/response errors: quota/rate-limit hits, HTTP and
    /// transport failures, and Hermes turn failures that originate at the
    /// model provider (401/402/429, upstream timeouts, model errors).
    static let provider = Logger(subsystem: subsystem, category: "provider")

    /// Agent session lifecycle: spawn, handshake, teardown, keepalive and
    /// protocol faults — the machinery around the provider calls, not the
    /// calls themselves.
    static let session = Logger(subsystem: subsystem, category: "session")
}
