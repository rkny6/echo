import Foundation

/// A generic JSON value.
///
/// MCP is JSON-RPC 2.0: request `params`, results, and tool `inputSchema` are
/// all arbitrary JSON, not the flat shape `LLMToolDefinition.LLMToolParameters`
/// was designed for (that type only models a single, non-nested `object`).
/// `JSONValue` gives the MCP layer (`MCPJSONRPC`, `MCPClient`,
/// `MCPStreamableHTTPTransport`) a faithful, `Codable`/`Sendable` way to carry
/// any JSON payload — including deeply nested tool schemas — without lossy
/// conversion.
indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Parses a JSON-encoded string (e.g. `LLMToolCall.arguments`) into a
    /// `JSONValue`. Returns `.object([:])` for empty/invalid input rather than
    /// throwing, since tool-call arguments are model-generated and callers
    /// should degrade gracefully rather than fail the whole turn.
    init(jsonString: String) throws {
        let data = Data(jsonString.utf8)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Re-serializes this value as a compact JSON string.
    func toJSONString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
