import Foundation

/// Role of a message in an LLM conversation, including tool roles.
enum LLMMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// A function/tool invocation requested by the model.
struct LLMToolCall: Codable, Sendable, Hashable {
    let id: String
    let name: String
    /// JSON-encoded arguments, e.g. `{"city": "Tokyo"}`.
    let arguments: String
}

/// One entry in an LLM conversation. Mirrors the OpenAI chat-completions
/// message shape so the adapter can serialize it 1:1 for both
/// `.chatCompletions` and `.responses` endpoints.
struct LLMMessage: Codable, Sendable, Hashable {
    let role: LLMMessageRole
    var content: String?
    /// Required for `role == .tool`; the id of the tool call this is a result for.
    var toolCallID: String?
    /// Required for `role == .assistant` messages that request tool calls.
    var toolCalls: [LLMToolCall]?

    init(
        role: LLMMessageRole,
        content: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }
}
