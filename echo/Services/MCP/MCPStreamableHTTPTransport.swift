import Foundation

/// Errors surfaced by `MCPStreamableHTTPTransport`, distinct from
/// `JSONRPCErrorPayload` (which is a well-formed error *from* the server).
enum MCPTransportError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case streamEndedWithoutResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "MCP server 返回了无法解析的响应"
        case .httpStatus(let status, let body):
            return "MCP server 返回 HTTP \(status): \(body)"
        case .streamEndedWithoutResponse:
            return "MCP server 的事件流在返回匹配结果前结束"
        }
    }
}

/// Client-side transport for MCP's "Streamable HTTP" transport
/// (https://modelcontextprotocol.io/specification — Transports). A single
/// HTTPS endpoint accepts POSTed JSON-RPC messages; the server may answer
/// either with a plain `application/json` body (one response) or with a
/// `text/event-stream` body (SSE) carrying the response plus any
/// intermediate server-to-client messages.
///
/// Session affinity: if the server returns an `Mcp-Session-Id` header (set
/// during `initialize`), that id is echoed back on every subsequent request,
/// as the spec requires for servers that need per-client state.
///
/// This client only implements what `MCPClient` needs (request/response +
/// fire-and-forget notifications). It does not open the optional standalone
/// `GET` SSE stream for server-initiated messages outside a request/response
/// cycle, and does not implement resumable streams (`Last-Event-ID`).
actor MCPStreamableHTTPTransport {
    private let serverURL: URL
    private let authToken: String?
    private let session: URLSession
    private let logger: LoggingProviding?
    private var sessionID: String?

    init(
        serverURL: URL,
        authToken: String? = nil,
        logger: LoggingProviding? = nil,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.authToken = authToken
        self.logger = logger
        self.session = session
    }

    /// Sends a JSON-RPC request and waits for its matching response.
    func sendRequest(id: Int, method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let body = try JSONEncoder().encode(JSONRPCRequest(id: id, method: method, params: params))
        let request = makeRequest(body: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPTransportError.invalidResponse
        }
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let raw = (try? await Self.drain(bytes)).flatMap { String(data: $0, encoding: .utf8) } ?? "<empty>"
            await logger?.log(
                "MCP \(method) failed: HTTP \(httpResponse.statusCode) \(raw)",
                level: .error
            )
            throw MCPTransportError.httpStatus(httpResponse.statusCode, raw)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return try await Self.readSSEResponse(bytes, matchingID: id)
        }
        let data = try await Self.drain(bytes)
        return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
    }

    /// Sends a JSON-RPC notification (no `id`, no response expected). MCP
    /// requires `notifications/initialized` be sent this way once the
    /// `initialize` handshake completes.
    func sendNotification(method: String, params: JSONValue?) async throws {
        let body = try JSONEncoder().encode(JSONRPCNotification(method: method, params: params))
        let request = makeRequest(body: body)
        let (bytes, response) = try await session.bytes(for: request)
        _ = try? await Self.drain(bytes)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw MCPTransportError.invalidResponse
        }
    }

    /// Drops any session established with the server. Call this after a
    /// connection failure so the next request re-runs `initialize` instead
    /// of replaying a session id the server may have discarded.
    func resetSession() {
        sessionID = nil
    }

    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        return request
    }

    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    /// Reads SSE `data:` events off `bytes` until one decodes as a JSON-RPC
    /// response whose `id` matches. Non-matching messages (e.g. server
    /// notifications interleaved before the real response) are decoded and
    /// discarded rather than treated as errors.
    private static func readSSEResponse(
        _ bytes: URLSession.AsyncBytes,
        matchingID id: Int
    ) async throws -> JSONRPCResponse {
        var dataBuffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                dataBuffer += value
                continue
            }
            guard line.isEmpty else { continue } // ignore event:/id:/retry: fields
            defer { dataBuffer = "" }
            guard !dataBuffer.isEmpty,
                  let eventData = dataBuffer.data(using: .utf8),
                  let message = try? JSONDecoder().decode(JSONRPCResponse.self, from: eventData)
            else { continue }
            if case .number(let numericID) = message.id, Int(numericID) == id {
                return message
            }
        }
        throw MCPTransportError.streamEndedWithoutResponse
    }
}
