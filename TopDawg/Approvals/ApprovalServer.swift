import Foundation
import Network
import OSLog

/// Tiny local HTTP server that receives `PermissionRequest` and `Notification` hook
/// POSTs from Claude Code CLI and routes them into TopDawg's approval queue.
///
/// Design notes
/// - Uses `Network.framework` (no external deps). HTTP parsing is hand-rolled because
///   the payloads are small and we only need two routes.
/// - Binds `127.0.0.1` on a random free port each launch. The port is exposed via
///   `actualPort` after `start()` resolves.
/// - Auth: every hook URL we install carries a `?token=<uuid>` query param. Requests
///   without the matching token get 401. The token is regenerated on every launch.
/// - Timeout: requests that aren't resolved within `requestTimeout` auto-deny with a
///   message, so a crashed/closed notch never hangs Claude Code.
final class ApprovalServer {

    // MARK: - Public

    let token: String
    private(set) var actualPort: UInt16 = 0

    /// Resolved approval URL that HookInstaller should install, e.g.
    /// "http://127.0.0.1:54321/permission-request?token=abc".
    var permissionURL: String {
        "http://127.0.0.1:\(actualPort)/permission-request?token=\(token)&source=topdawg"
    }
    var notificationURL: String {
        "http://127.0.0.1:\(actualPort)/notification?token=\(token)&source=topdawg"
    }

    var onNotification: ((String) -> Void)?   // free-form message text

    // MARK: - Private

    private let pending: PendingApprovals
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.topdawg.approval.server")
    private let log = Logger(subsystem: "com.topdawg.app", category: "ApprovalServer")
    private let requestTimeout: TimeInterval = 120  // 2 min — generous, user might be elsewhere

    init(pending: PendingApprovals) {
        self.pending = pending
        self.token = UUID().uuidString
    }

    // MARK: - Lifecycle

    /// Start the listener. Returns when the port is known (or throws if bind fails).
    func start() async throws {
        let params = NWParameters.tcp
        // Force IPv4 loopback only.
        if let opts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            opts.version = .v4
        }
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .init("127.0.0.1"),
            port: .any
        )

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }

        // Wait for .ready so we can read the assigned port.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        self.actualPort = p
                    }
                    self.log.info("ApprovalServer listening on 127.0.0.1:\(self.actualPort, privacy: .public)")
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let err):
                    self.log.error("ApprovalServer failed: \(String(describing: err), privacy: .public)")
                    if !resumed { resumed = true; cont.resume(throwing: err) }
                case .cancelled:
                    self.log.info("ApprovalServer cancelled")
                default: break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readFull(conn: conn, buffer: Data())
    }

    /// Read until we see CRLFCRLF, parse headers, keep reading until we have Content-Length bytes.
    private func readFull(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { conn.cancel(); return }
            if let err {
                self.log.error("recv error: \(String(describing: err), privacy: .public)")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            // Find end of headers.
            guard let headerEnd = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                if isComplete { conn.cancel(); return }
                self.readFull(conn: conn, buffer: buf)
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.respond(conn: conn, status: 400, body: "bad headers"); return
            }

            // Use components(separatedBy:) to reliably strip \r\n pairs.
            let lines = headerString
                .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                .filter { !$0.isEmpty }
            guard let requestLine = lines.first else {
                self.respond(conn: conn, status: 400, body: "no request line"); return
            }
            let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else {
                self.respond(conn: conn, status: 400, body: "bad request line"); return
            }
            let method = parts[0]
            let target = parts[1]

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let name = String(line[..<colon]).lowercased()
                    let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[name] = val
                }
            }

            let bodyStart = headerEnd.upperBound

            // If the sender declares a Content-Length, honor it and wait for that many bytes.
            // Otherwise (chunked / no header) drain the connection until it closes.
            if let clStr = headers["content-length"], let contentLength = Int(clStr), contentLength > 0 {
                let needed = bodyStart + contentLength
                if buf.count < needed {
                    if isComplete {
                        self.respond(conn: conn, status: 400, body: "body truncated"); return
                    }
                    self.readFull(conn: conn, buffer: buf)
                    return
                }
                let body = buf.subdata(in: bodyStart..<needed)
                self.log.debug("route \(method, privacy: .public) \(target, privacy: .public) body=\(body.count, privacy: .public)B (content-length)")
                self.route(conn: conn, method: method, target: target, body: body)
            } else {
                // No / zero Content-Length — accumulate until connection closes.
                if isComplete {
                    let body = buf.subdata(in: bodyStart..<buf.count)
                    self.log.debug("route \(method, privacy: .public) \(target, privacy: .public) body=\(body.count, privacy: .public)B (drained)")
                    self.route(conn: conn, method: method, target: target, body: body)
                } else {
                    self.readFull(conn: conn, buffer: buf)
                }
            }
        }
    }

    // MARK: - Routing

    private func route(conn: NWConnection, method: String, target: String, body: Data) {
        // Split path + query.
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        // Auth gate on everything except /health.
        if path != "/health" {
            guard query["token"] == token else {
                respond(conn: conn, status: 401, body: "unauthorized")
                return
            }
        }

        switch (method, path) {
        case ("GET", "/health"):
            respond(conn: conn, status: 200, body: #"{"ok":true}"#, contentType: "application/json")

        case ("POST", "/permission-request"):
            handlePermissionRequest(conn: conn, body: body)

        case ("POST", "/notification"):
            handleNotification(conn: conn, body: body)

        default:
            respond(conn: conn, status: 404, body: "not found")
        }
    }

    // MARK: - Permission

    private func handlePermissionRequest(conn: NWConnection, body: Data) {
        log.info("PermissionRequest body=\(body.count, privacy: .public)B preview='\(String(data: body.prefix(120), encoding: .utf8) ?? "<binary>", privacy: .public)'")
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            log.error("PermissionRequest JSON parse failed for body='\(String(data: body, encoding: .utf8) ?? "<binary>", privacy: .public)'")
            respondHookDecision(conn: conn, behavior: "ask")  // fall back to terminal
            return
        }

        // Claude Code hook payload shape (best-effort; fields vary by version):
        //   tool_name, tool_input (object), session_id, cwd, transcript_path
        let toolName = obj["tool_name"] as? String ?? "Unknown"
        let sessionID = obj["session_id"] as? String
        let cwd = obj["cwd"] as? String
        let transcriptPath = obj["transcript_path"] as? String

        let toolInputJSON: String = {
            if let input = obj["tool_input"] {
                let data = try? JSONSerialization.data(
                    withJSONObject: input,
                    options: [.prettyPrinted, .sortedKeys]
                )
                return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            return "{}"
        }()

        // Bridge the async → continuation world.
        let semaphore = DispatchSemaphore(value: 0)
        var decision: ApprovalDecision = .deny  // default on timeout

        let req = ApprovalRequest(
            toolName: toolName,
            toolInputJSON: toolInputJSON,
            sessionID: sessionID,
            cwd: cwd,
            transcriptPath: transcriptPath
        ) { d in
            decision = d
            semaphore.signal()
        }

        DispatchQueue.main.async { [pending] in
            pending.enqueue(req)
        }

        // Schedule a timeout that resolves the request to .deny if not already handled.
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak req] in
            req?.resolve(.deny)
        }

        // Wait for user on a background worker (we're on the server queue).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            semaphore.wait()
            let behavior: String
            switch decision {
            case .allow, .allowAlways: behavior = "allow"
            case .deny:                behavior = "deny"
            }
            self?.respondHookDecision(
                conn: conn,
                behavior: behavior,
                message: decision == .deny ? "Denied from TopDawg notch" : nil
            )
        }
    }

    private func respondHookDecision(conn: NWConnection, behavior: String, message: String? = nil) {
        var decision: [String: Any] = ["behavior": behavior]
        if let message { decision["message"] = message }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        respond(conn: conn, status: 200, body: body, contentType: "application/json")
    }

    // MARK: - Notification

    private func handleNotification(conn: NWConnection, body: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let msg = obj["message"] as? String {
            onNotification?(msg)
        }
        respond(conn: conn, status: 200, body: "{}", contentType: "application/json")
    }

    // MARK: - Response writer

    private func respond(
        conn: NWConnection,
        status: Int,
        body: String,
        contentType: String = "text/plain; charset=utf-8"
    ) {
        let reason = Self.reasonPhrase(status)
        let bodyData = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}
