import Foundation

// alfred-mcp — the MCP stdio shim Hermes spawns.
//
// This binary deliberately does NO privileged work. It is a byte relay between
// Hermes' stdio pipes and a Unix domain socket owned by the running Alfred.app:
//
//     hermes  ──stdio──▶  alfred-mcp  ──unix socket──▶  Alfred.app
//
// Why a relay instead of implementing the tools here: macOS TCC grants attach to
// a code signature. Alfred.app already holds Accessibility, Screen Recording and
// Automation. If this binary called AX APIs itself it would need its OWN grants,
// and — because the app is self-signed — every rebuild would re-prompt for all of
// them. Keeping the privileged work inside Alfred.app means one grant, granted
// once, and this shim can be rebuilt freely.
//
// All MCP protocol handling lives in AlfredToolServer.swift, on the other end of
// the socket, next to the capabilities it exposes.

// Keep in sync with AlfredToolServer.socketPath.
let socketPath: String = {
    let base = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Alfred", isDirectory: true)
    return base.appendingPathComponent("mcp.sock").path
}()

/// Fail loudly on stdout-as-protocol: everything diagnostic goes to stderr, or it
/// would be parsed as a JSON-RPC frame by the client.
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("alfred-mcp: \(message)\n".utf8))
    exit(1)
}

/// Connect to Alfred.app, retrying briefly.
///
/// Hermes may spawn us while Alfred is still launching (or during a relaunch), so
/// a single failed connect would surface as "MCP server crashed" for what is
/// really a startup race.
func connectWithRetry(attempts: Int = 20, delay: useconds_t = 250_000) -> Int32 {
    guard socketPath.utf8.count < 104 else {
        die("socket path too long for sockaddr_un: \(socketPath)")
    }
    for attempt in 1...attempts {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { die("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Capacity read before taking exclusive access to sun_path, or the two
        // overlap and Swift's exclusivity checking rejects it.
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, pathCapacity)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        if ok == 0 { return fd }

        close(fd)
        if attempt == attempts {
            die("""
                could not reach Alfred at \(socketPath) after \(attempts) attempts. \
                Is Alfred.app running? Its macOS tools are only available while it is.
                """)
        }
        usleep(delay)
    }
    die("unreachable")
}

let sock = connectWithRetry()

// Bidirectional pump. Two threads rather than async/await so this stays a tiny
// dependency-free binary with no runtime to spin up.
let group = DispatchGroup()

// stdin (Hermes) → socket (Alfred)
group.enter()
Thread {
    let input = FileHandle.standardInput
    while true {
        let chunk = input.availableData
        if chunk.isEmpty { break }               // Hermes closed the pipe
        var sent = 0
        chunk.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < chunk.count {
                let n = write(sock, base + sent, chunk.count - sent)
                if n <= 0 { sent = chunk.count; break }   // socket gone
                sent += n
            }
        }
    }
    shutdown(sock, SHUT_WR)
    group.leave()
}.start()

// socket (Alfred) → stdout (Hermes)
group.enter()
Thread {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(sock, &buffer, buffer.count)
        if n <= 0 { break }                      // Alfred closed or died
        FileHandle.standardOutput.write(Data(buffer[0..<n]))
    }
    group.leave()
}.start()

group.wait()
close(sock)
