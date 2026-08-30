import Foundation

/// A tool implementation: schema definition + executor.
///
/// Conformers describe the tool once (`definition`, used in the LLM `tools`
/// request) and implement `execute`, which runs a single invocation and
/// returns result text (typically JSON) that is fed back to the model as a
/// `.tool` message.
protocol LLMTool: Sendable {
    /// JSON-Schema description sent to the model so it knows when/how to call.
    var definition: LLMToolDefinition { get }

    /// Executes one tool call. Errors are caught by `ToolCallLoop` and fed
    /// back to the model as a JSON error message, so implementations can
    /// either throw (to let the loop format the error) or return an error
    /// JSON themselves.
    func execute(_ call: LLMToolCall) async throws -> String
}
