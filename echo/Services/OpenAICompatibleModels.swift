import Foundation

/// Response models for OpenAI-compatible APIs (OpenAI, ModelScope, custom providers)
struct OpenAICompatibleResponse: Decodable {
    let choices: [Choice]?
    let output: [OutputItem]?

    struct Choice: Decodable {
        let message: Message?
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        let id: String?
        let function: Function?

        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
    }

    struct OutputItem: Decodable {
        let type: String?
        let id: String?
        let callID: String?
        let name: String?
        let arguments: String?
        let content: [OutputContent]?

        enum CodingKeys: String, CodingKey {
            case type, id, name, arguments, content
            case callID = "call_id"
        }
    }

    struct OutputContent: Decodable {
        let text: String?
    }

    /// Extracts requested tool calls from either the chat-completions
    /// (`choices[].message.tool_calls`) or responses (`output[]` function_call
    /// items) shape. Returns nil when no tool calls are present.
    func toolCalls() -> [LLMToolCall]? {
        if let choices = choices, let message = choices.first?.message,
           let toolCalls = message.toolCalls {
            let calls = toolCalls.compactMap { call -> LLMToolCall? in
                guard let id = call.id,
                      let name = call.function?.name,
                      let arguments = call.function?.arguments
                else { return nil }
                return LLMToolCall(id: id, name: name, arguments: arguments)
            }
            if !calls.isEmpty { return calls }
        }

        if let output = output {
            let calls = output.compactMap { item -> LLMToolCall? in
                guard item.type == "function_call",
                      // Responses API: `call_id` is the identifier the caller
                      // must echo back in the tool result, so it takes
                      // precedence over the item's own `id`.
                      let id = item.callID ?? item.id,
                      let name = item.name,
                      let arguments = item.arguments
                else { return nil }
                return LLMToolCall(id: id, name: name, arguments: arguments)
            }
            if !calls.isEmpty { return calls }
        }

        return nil
    }
}

enum OpenAICompatibleError: LocalizedError {
    case invalidResponse
    case invalidResponseStatus(status: Int, body: String)
    case noContent
    /// The model requested tool calls despite none being offered (or the
    /// caller only supports plain text).
    case unexpectedToolCalls

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "API 响应无效"
        case .invalidResponseStatus(let status, let body):
            return "API 响应无效 (状态码: \(status)) 响应体: \(body)"
        case .noContent:
            return "API 未返回内容"
        case .unexpectedToolCalls:
            return "模型请求了未提供的工具调用"
        }
    }
}
