import Foundation

/// JSON-RPC 2.0 request. MCP (Model Context Protocol) is JSON-RPC 2.0 over a
/// transport (here: Streamable HTTP) — see
/// https://modelcontextprotocol.io/specification for the wire format this
/// mirrors.
struct JSONRPCRequest: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: JSONValue?
}

/// JSON-RPC 2.0 notification: same shape as a request but with no `id`, and
/// therefore no response is expected. MCP requires the client send
/// `notifications/initialized` after the `initialize` handshake completes.
struct JSONRPCNotification: Encodable, Sendable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?
}

/// JSON-RPC 2.0 error object.
struct JSONRPCErrorPayload: Decodable, Sendable, LocalizedError {
    let code: Int
    let message: String
    let data: JSONValue?

    var errorDescription: String? {
        "MCP server error \(code): \(message)"
    }
}

/// JSON-RPC 2.0 response. `id` is decoded loosely (number or string) since
/// the spec allows either; this client only ever sends integer ids, so on
/// decode we just need enough to match it back up.
struct JSONRPCResponse: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let result: JSONValue?
    let error: JSONRPCErrorPayload?
}

/// Any single line of an MCP Streamable HTTP SSE stream is itself a
/// JSON-RPC message but may be a request, response, or notification sent
/// *from* the server (e.g. server-initiated sampling requests). This client
/// only implements the client role, so it decodes every SSE `data:` payload
/// as a response and ignores anything that isn't one it's waiting on.
typealias JSONRPCMessage = JSONRPCResponse
