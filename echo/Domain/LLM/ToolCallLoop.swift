import Foundation

/// Errors thrown by `ToolCallLoop`.
enum ToolCallLoopError: LocalizedError, Sendable {
    /// The model kept requesting tool calls and never produced final text
    /// within `rounds` rounds.
    case maxRoundsExceeded(rounds: Int)
    /// A tool call was requested but no executor is registered for it.
    case noToolRegistered(name: String)

    var errorDescription: String? {
        switch self {
        case .maxRoundsExceeded(let rounds):
            return "工具调用超过 \(rounds) 轮上限，模型未返回最终文本"
        case .noToolRegistered(let name):
            return "没有注册可执行的工具：\(name)"
        }
    }
}

/// Drives one reply's tool loop: generate → execute requested tool calls →
/// append their results → generate again, until the model returns final text
/// or the round budget runs out.
///
/// ## Retry policy
/// Every `generate` call is individually wrapped in `generateWithRetry`, so a
/// transient network failure retries that one API call. The loop itself is
/// **never** retried as a whole — re-running it would re-execute tool calls
/// that already had side effects (sent messages, scheduled deliveries, …).
/// Callers must also not wrap this loop in `withTransientRetry`.
///
/// When `tools` is empty the loop degenerates to a single plain-text turn,
/// exactly equivalent to today's `sendMessage` path — so wiring this in now is
/// behavior-neutral until real tools are registered (Phase 2 ToolRegistry).
struct ToolCallLoop {
    /// Executes one tool invocation and returns result text. Runs at most once
    /// per call; errors are fed back to the model as a `.tool` message rather
    /// than aborting the turn.
    typealias ToolExecutor = @Sendable (LLMToolCall) async throws -> String

    static let defaultMaxRounds = 4

    /// Runs the loop from `messages`, appending tool-call/tool-result turns as
    /// the model requests them. Returns the final assistant text.
    static func run(
        provider: LLMProviderService,
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        executeTool: ToolExecutor,
        temperature: Double,
        maxTokens: Int,
        maxRounds: Int = defaultMaxRounds,
        logger: LoggingProviding? = nil
    ) async throws -> String {
        var working = messages

        for round in 1...maxRounds {
            let result = try await provider.generateWithRetry(
                messages: working,
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature,
                maxTokens: maxTokens,
                logger: logger
            )

            switch result {
            case .text(let content):
                return content

            case .toolCalls(let calls):
                guard !calls.isEmpty else {
                    await logger?.log(
                        "Tool loop round \(round): model returned empty toolCalls; treating as empty reply",
                        level: .warning
                    )
                    return ""
                }
                guard round < maxRounds else {
                    await logger?.log(
                        "Tool loop exhausted \(maxRounds) rounds without final text",
                        level: .error
                    )
                    throw ToolCallLoopError.maxRoundsExceeded(rounds: maxRounds)
                }

                // Record the model's request, then feed each result back so the
                // next generate call sees the full tool transcript.
                working.append(LLMMessage(role: .assistant, content: nil, toolCalls: calls))
                for call in calls {
                    let output: String
                    do {
                        output = try await executeTool(call)
                    } catch {
                        await logger?.log(
                            "Tool \(call.name) failed: \(error.localizedDescription)",
                            level: .error
                        )
                        output = #"{"error": "\#(error.localizedDescription)"}"#
                    }
                    working.append(LLMMessage(role: .tool, content: output, toolCallID: call.id))
                }
            }
        }

        // Only reachable with maxRounds <= 0; keeps the compiler satisfied.
        throw ToolCallLoopError.maxRoundsExceeded(rounds: maxRounds)
    }
}
