import Foundation

/// Protocol for LLM provider services
protocol LLMProviderService: Sendable {
    /// Generate a single turn from a message array (optionally with tools).
    /// Returns either final text or requested tool calls.
    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMGenerationResult
    
    /// Test the connection and API key validity
    func testConnection() async throws -> Bool
}

extension LLMProviderService {
    /// Convenience for plain text generation (no tools). Builds a
    /// `[system, user]` message array and returns the final text.
    func sendMessage(
        systemPrompt: String,
        userMessage: String,
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        let result = try await generate(
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: userMessage)
            ],
            tools: nil,
            temperature: temperature,
            maxTokens: maxTokens
        )
        switch result {
        case .text(let content):
            return content
        case .toolCalls:
            throw OpenAICompatibleError.unexpectedToolCalls
        }
    }
}
