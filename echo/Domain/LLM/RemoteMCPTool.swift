import Foundation

struct RemoteMCPTool: LLMTool {
    let definition: LLMToolDefinition
    let callHandler: @Sendable (LLMToolCall) async throws -> String

    func execute(_ call: LLMToolCall) async throws -> String {
        return try await callHandler(call)
    }
}
