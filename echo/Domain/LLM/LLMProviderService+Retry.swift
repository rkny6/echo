import Foundation

/// Shared network-resilience helper for every LLM call in the app.
///
/// Originally this retry loop only lived inside ConversationManager (for the
/// user-reply path). A full audit of every place that calls
/// `sendMessage` found the same class of risk — the request dying with
/// NSURLErrorNetworkConnectionLost (-1005) if the app gets backgrounded
/// mid-request — in every proactive-message generation service too (health,
/// online greeting, event-triggered replies). Rather than copy-paste the same retry
/// loop into each one, it lives here once as a default extension on
/// `LLMProviderService`, so every call site gets the same protection by
/// simply calling `sendMessageWithRetry` instead of `sendMessage`.
extension LLMProviderService {
    func sendMessageWithRetry(
        systemPrompt: String,
        userMessage: String,
        temperature: Double,
        maxTokens: Int,
        maxAttempts: Int = 3,
        logger: LoggingProviding? = nil
    ) async throws -> String {
        try await withTransientRetry(maxAttempts: maxAttempts, logger: logger) {
            try await sendMessage(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }
    }

    /// Single-turn generation with retry, scoped to this one API call.
    ///
    /// Tool loops must call this per turn — never wrap the whole loop in a
    /// retry — so a retry can't re-run tool calls that already had side effects.
    func generateWithRetry(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        temperature: Double,
        maxTokens: Int,
        maxAttempts: Int = 3,
        logger: LoggingProviding? = nil
    ) async throws -> LLMGenerationResult {
        try await withTransientRetry(maxAttempts: maxAttempts, logger: logger) {
            try await generate(
                messages: messages,
                tools: tools,
                temperature: temperature,
                maxTokens: maxTokens
            )
        }
    }

}

/// Errors worth retrying — the kind that show up when the app gets
/// backgrounded/suspended mid-request, the network blips, or the
/// server returns a transient 5xx. Non-retryable failures (bad API key,
/// malformed request, 4xx client errors) are left alone.
func isTransientLLMError(_ error: Error) -> Bool {
    // 5xx server errors (e.g. 502 Bad Gateway) are usually transient.
    if case let OpenAICompatibleError.invalidResponseStatus(status, _) = error,
       status >= 500 && status < 600 {
        return true
    }

    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return false }
    let transientCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,   // -1005
        NSURLErrorNotConnectedToInternet,  // -1009
        NSURLErrorTimedOut,                // -1001
        NSURLErrorCannotConnectToHost,     // -1004
        NSURLErrorDNSLookupFailed,         // -1006
        NSURLErrorCannotFindHost           // -1003
    ]
    return transientCodes.contains(nsError.code)
}

/// Retry a single unit of work when it fails with a transient network error.
/// Shared by every LLM call site so each one gets the same protection without
/// copy-pasting the loop. Tool loops retry each API call individually via
/// `generateWithRetry` / `sendMessageWithRetry`, never the whole loop.
func withTransientRetry<T>(
    maxAttempts: Int = 3,
    logger: LoggingProviding? = nil,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error = URLError(.unknown)

    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            guard attempt < maxAttempts, isTransientLLMError(error) else {
                await logger?.log(
                    "LLM call attempt \(attempt)/\(maxAttempts) failed permanently: \(error.localizedDescription)",
                    level: .error
                )
                throw error
            }
            let backoffSeconds = Double(attempt) * 1.5
            await logger?.log(
                "LLM call hit a transient network error (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription); retrying in \(backoffSeconds)s",
                level: .warning
            )
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
        }
    }

    throw lastError
}
