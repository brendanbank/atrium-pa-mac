import Foundation

/// A one-shot HTTP listener on the loopback interface, to catch the
/// redirect at the end of a browser login.
///
/// This is the piece that makes "log in to Atrium PA" possible without
/// anyone pasting a client ID and secret.
///
/// **Nothing connects to this machine from outside it.** That is worth
/// stating plainly, because "the server redirects to a port on my
/// laptop" sounds like it needs an inbound connection, a public address
/// or a hole in a firewall, and it needs none of them. The server's
/// redirect is an HTTP 302 sent to the *browser*, which is already
/// running here; the browser then navigates itself to
/// `http://127.0.0.1:<port>/callback?code=…`. That request never leaves
/// the machine — it goes from the browser to the loopback interface and
/// straight back into this process.
///
/// So it works on a laptop, behind NAT, on hotel wifi, on a train. This
/// is the standard shape for native-app OAuth (RFC 8252) for exactly
/// that reason. The only thing the *server* needs is a willingness to
/// emit a redirect pointing at 127.0.0.1, which Atrium PA has by
/// default — loopback is in its redirect allowlist, and plain HTTP is
/// permitted for loopback hosts specifically.
///
/// Three details that are not decoration:
///
/// * **Loopback only.** The socket is bound to 127.0.0.1 explicitly, so
///   nothing on the network can reach it even briefly. Atrium PA's
///   redirect allowlist permits plain HTTP for loopback hosts and only
///   for loopback hosts, which is the same reasoning from the other side.
/// * **The port is chosen by the kernel**, then read back. It has to be,
///   because the redirect URI containing it is registered with the server
///   *before* the browser opens — so the listener binds first and the
///   registration follows.
/// * **One request and done.** It answers the redirect, hands the query
///   back, and closes. A listener that outlived the login would be a
///   permanent open port for no reason.
public final class CallbackListener {

    public enum ListenerError: Error, CustomStringConvertible {
        case couldNotBind(String)
        case timedOut

        public var description: String {
            switch self {
            case .couldNotBind(let why): return "could not open a loopback port — \(why)"
            case .timedOut: return "the browser never came back"
            }
        }
    }

    private let socketHandle: Int32
    private let lock = NSLock()
    private var finished = false

    /// The port the kernel assigned. Valid once `init` returns.
    public let port: UInt16

    public init() throws {
        // BSD sockets rather than Network.framework.
        //
        // `NWListener` fails to bind here at all: every configuration —
        // plain `.tcp`, `on: .any`, `requiredLocalEndpoint`,
        // `requiredInterfaceType` — returns EINVAL on this system, inside
        // and outside a sandbox. Rather than keep guessing at a framework
        // that will not say what it wants, this is forty lines of
        // socket calls that do exactly one thing and report exactly what
        // went wrong. The same reasoning that put `MicCapture` on the
        // CoreAudio HAL.
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw ListenerError.couldNotBind("socket() failed: \(errno)")
        }

        var reuse: Int32 = 1
        setsockopt(
            handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 127.0.0.1 explicitly, and port 0 so the kernel picks one. The
        // loopback address is the security boundary: nothing off this
        // machine can reach the socket at all.
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw ListenerError.couldNotBind("bind() failed: \(errno)")
        }
        guard listen(handle, 1) == 0 else {
            close(handle)
            throw ListenerError.couldNotBind("listen() failed: \(errno)")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else {
            close(handle)
            throw ListenerError.couldNotBind("getsockname() failed: \(errno)")
        }

        socketHandle = handle
        port = UInt16(bigEndian: assigned.sin_port)
    }

    /// Wait for the browser to arrive, and return the redirect's query
    /// parameters.
    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let handle = socketHandle
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let query = try Self.awaitRequest(on: handle, timeout: timeout)
                    continuation.resume(returning: query)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        close(socketHandle)
    }

    // MARK: - Private

    private static func awaitRequest(on handle: Int32, timeout: TimeInterval) throws
        -> [String: String]
    {
        // `poll` rather than a blocking accept, so a login nobody
        // completes releases the port instead of holding a thread for
        // ever.
        var descriptor = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(timeout, 0) * 1000)
        let ready = poll(&descriptor, 1, milliseconds)
        guard ready > 0 else { throw ListenerError.timedOut }

        let client = Darwin.accept(handle, nil, nil)
        guard client >= 0 else {
            throw ListenerError.couldNotBind("accept() failed: \(errno)")
        }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(client, &buffer, buffer.count)
        let request =
            count > 0
            ? (String(bytes: buffer[0..<count], encoding: .utf8) ?? "") : ""
        let query = parseQuery(fromRequestLine: request)

        let body = page(granted: query["code"] != nil)
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        _ = Array(response.utf8).withUnsafeBufferPointer {
            write(client, $0.baseAddress, $0.count)
        }
        return query
    }

    /// Pull the query out of `GET /callback?code=…&state=… HTTP/1.1`.
    public static func parseQuery(fromRequestLine request: String) -> [String: String] {
        guard
            let line = request.split(separator: "\r\n").first
                ?? request.split(separator: "\n").first,
            let path = line.split(separator: " ").dropFirst().first,
            let components = URLComponents(string: "http://127.0.0.1\(path)"),
            let items = components.queryItems
        else { return [:] }

        var query: [String: String] = [:]
        for item in items where item.value != nil {
            query[item.name] = item.value
        }
        return query
    }

    /// What the browser shows once it is done. Deliberately plain: the
    /// app is where the result actually gets reported, and a page that
    /// tried to look like an app would be another thing to maintain.
    private static func page(granted: Bool) -> String {
        let heading = granted ? "Connected" : "Not connected"
        let detail =
            granted
            ? "Atrium PA Capture is signed in. You can close this tab."
            : "Nothing was authorised. You can close this tab and try again."
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <title>\(heading)</title><style>
            body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;
            max-width:28rem;margin:5rem auto;padding:0 1rem;color:#1a1a1a}
            h1{font-size:1.2rem;margin-bottom:.4rem}p{color:#555}
            </style></head><body><h1>\(heading)</h1><p>\(detail)</p></body></html>
            """
    }

    deinit { stop() }
}
