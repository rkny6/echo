import Foundation

/// Errors specific to the MCP protocol layer (as opposed to transport-level
/// failures, see `MCPTransportError`).
enum MCPClientError: LocalizedError, Sendable {
    case malformedToolList
    case malformedToolResult
    case toolReportedError(String)

    var errorDescription: String? {
        switch self {
        case .malformedToolList:
            return "MCP server 的 tools/list 响应格式不正确"
        case .malformedToolResult:
            return "MCP server 的 tools/call 响应格式不正确"
        case .toolReportedError(let message):
            return message
        }
    }
}

/// A real MCP client speaking JSON-RPC 2.0 over `MCPStreamableHTTPTransport`.
///
/// Lifecycle: the `initialize` → `notifications/initialized` handshake
/// (https://modelcontextprotocol.io/specification, Lifecycle) runs lazily on
/// first use and is cached; call `reset()` to force it to run again (e.g.
/// after the transport reports a session error).
actor MCPClient {
    /// Protocol version this client implements. MCP servers negotiate down
    /// to a version they also support in the `initialize` response; this
    /// client doesn't currently branch on the negotiated version, since
    /// `tools/list` and `tools/call` have been stable across the versions in
    /// common deployment.
    private static let protocolVersion = "2025-06-18"

    private let transport: MCPStreamableHTTPTransport
    private let logger: LoggingProviding?
    private let clientName: String
    private let clientVersion: String

    private var nextRequestID = 1
    private var didInitialize = false

    init(
        serverURL: URL,
        authToken: String? = nil,
        clientName: String = "echo-ios",
        clientVersion: String = "1.0",
        logger: LoggingProviding? = nil,
        session: URLSession = .shared
    ) {
        self.transport = MCPStreamableHTTPTransport(
            serverURL: serverURL,
            authToken: authToken,
            logger: logger,
            session: session
        )
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.logger = logger
    }

    /// Forces the next call to re-run the `initialize` handshake. Call after
    /// a connection error, since the server may have dropped the session.
    func reset() async {
        didInitialize = false
        await transport.resetSession()
    }

    /// Fetches the server's tool list and converts each entry into an
    /// `LLMToolDefinition` (preserving the full `inputSchema` via
    /// `rawSchema` so nested/complex schemas survive intact).
    func listTools() async throws -> [LLMToolDefinition] {
        try await initializeIfNeeded()
        let result = try await send(method: "tools/list", params: .object([:]))
        guard let tools = result?["tools"]?.arrayValue else {
            throw MCPClientError.malformedToolList
        }
        return tools.compactMap(Self.parseToolDefinition)
    }

    /// Invokes a tool by name with JSON-encoded `arguments` (matching
    /// `LLMToolCall.arguments`) and returns its result as text.
    func callTool(name: String, arguments: String) async throws -> String {
        try await initializeIfNeeded()
        let argumentsValue = (try? JSONValue(jsonString: arguments)) ?? .object([:])
        let params: JSONValue = .object(["name": .string(name), "arguments": argumentsValue])
        let result = try await send(method: "tools/call", params: params)
        return try Self.extractText(from: result)
    }

    // MARK: - Handshake

    private func initializeIfNeeded() async throws {
        guard !didInitialize else { return }

        let initParams: JSONValue = .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion)
            ])
        ])
        _ = try await send(method: "initialize", params: initParams, skipInitCheck: true)
        try await transport.sendNotification(method: "notifications/initialized", params: nil)
        didInitialize = true
        await logger?.log("MCP client initialized", level: .debug)
    }

    // MARK: - Request plumbing

    private func send(
        method: String,
        params: JSONValue?,
        skipInitCheck: Bool = false
    ) async throws -> JSONValue? {
        let id = nextRequestID
        nextRequestID += 1
        let response = try await transport.sendRequest(id: id, method: method, params: params)
        if let error = response.error {
            await logger?.log("MCP \(method) returned error: \(error.message)", level: .error)
            throw error
        }
        return response.result
    }

    // MARK: - Parsing

    /// Maps one entry of `tools/list`'s `tools` array — `{name, description,
    /// inputSchema}` — to `LLMToolDefinition`. `inputSchema` is kept verbatim
    /// as `rawSchema` (arbitrary JSON Schema) and also best-effort flattened
    /// into `parameters` for callers that only look at the flat shape.
    private static func parseToolDefinition(_ tool: JSONValue) -> LLMToolDefinition? {
        guard let name = tool["name"]?.stringValue else { return nil }
        let description = tool["description"]?.stringValue ?? ""
        let schema = tool["inputSchema"] ?? .object(["type": .string("object"), "properties": .object([:])])
        return LLMToolDefinition(
            name: name,
            description: description,
            parameters: flattenTopLevel(schema),
            rawSchema: schema
        )
    }

    /// Best-effort projection of an arbitrary JSON Schema object onto the
    /// flat `LLMToolParameters` shape: top-level properties only, nested
    /// object/array properties collapse to their declared `type` with no
    /// further structure. Only used as a fallback for code paths that don't
    /// consult `rawSchema`; the model itself is always sent `rawSchema`.
    private static func flattenTopLevel(_ schema: JSONValue) -> LLMToolDefinition.LLMToolParameters {
        guard let properties = schema["properties"]?.objectValue else {
            return LLMToolDefinition.LLMToolParameters(properties: [:], required: [])
        }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var flat: [String: LLMToolDefinition.LLMToolParameter] = [:]
        for (key, value) in properties {
            let type = value["type"]?.stringValue ?? "string"
            let description = value["description"]?.stringValue ?? ""
            let enumValues = value["enum"]?.arrayValue?.compactMap(\.stringValue)
            flat[key] = LLMToolDefinition.LLMToolParameter(
                type: type,
                description: description,
                enumValues: enumValues
            )
        }
        return LLMToolDefinition.LLMToolParameters(properties: flat, required: required)
    }

    /// `tools/call` results are `{content: [{type: "text", text: ...}, ...],
    /// isError?: bool}`. Concatenates every text block; non-text content
    /// (images, embedded resources) is summarized rather than dropped
    /// silently, since the model should know something came back.
    private static func extractText(from result: JSONValue?) throws -> String {
        guard let result else { throw MCPClientError.malformedToolResult }
        let isError: Bool = {
            if case .bool(let value)? = result["isError"] { return value }
            return false
        }()

        guard let content = result["content"]?.arrayValue else {
            throw MCPClientError.malformedToolResult
        }
        let parts: [String] = content.map { block in
            switch block["type"]?.stringValue {
            case "text":
                return block["text"]?.stringValue ?? ""
            case "image":
                return "[图片内容，未显示]"
            case "resource":
                return "[资源内容，未显示]"
            default:
                return ""
            }
        }
        let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        if isError {
            throw MCPClientError.toolReportedError(text.isEmpty ? "工具执行失败" : text)
        }
        return text
    }
}
