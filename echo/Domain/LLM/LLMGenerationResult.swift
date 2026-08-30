import Foundation

/// Outcome of a single LLM generation turn.
enum LLMGenerationResult: Sendable, Equatable {
    /// Model produced final text (no tool calls).
    case text(String)
    /// Model requested one or more tool invocations.
    case toolCalls([LLMToolCall])
}
