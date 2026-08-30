import Foundation

/// Description of a tool the model may call. Serializes into the OpenAI
/// `tools` request parameter (function + JSON Schema parameters).
struct LLMToolDefinition: Codable, Sendable, Hashable {
    let name: String
    let description: String
    let parameters: LLMToolParameters
    /// Full JSON Schema for this tool's arguments, verbatim, when the source
    /// is richer than the flat `parameters` shape can express — e.g. an MCP
    /// server's `tools/list` `inputSchema`, which may nest objects/arrays
    /// arbitrarily deep. When present, adapters send this instead of
    /// reconstructing schema from `parameters`; `parameters` is still
    /// populated (best-effort, top-level only) for callers — logging,
    /// `ToolRegistry`, tests — that only look at the flat shape. `nil` for
    /// locally-defined tools like `WeatherTool`, whose flat `parameters` is
    /// already the full picture.
    let rawSchema: JSONValue?

    init(
        name: String,
        description: String,
        parameters: LLMToolParameters,
        rawSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.rawSchema = rawSchema
    }

    /// JSON Schema `object` describing the tool's arguments.
    struct LLMToolParameters: Codable, Sendable, Hashable {
        let properties: [String: LLMToolParameter]
        let required: [String]

        init(properties: [String: LLMToolParameter], required: [String]) {
            self.properties = properties
            self.required = required
        }
    }

    /// A single JSON Schema property.
    struct LLMToolParameter: Codable, Sendable, Hashable {
        /// JSON Schema type: "string", "number", "boolean", "array", "object".
        let type: String
        let description: String
        let enumValues: [String]?

        init(type: String, description: String, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }
}
