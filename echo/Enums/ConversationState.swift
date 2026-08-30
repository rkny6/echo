import Foundation

/// State of the conversation
enum ConversationState: String, Codable {
    /// No active conversation
    case idle
    /// User is actively chatting
    case conversing
    /// Accumulating user messages before generating a reply
    case waitingForResponse
    /// Waiting for user response to system-initiated message
    case reactive
    /// Following up on previous conversation
    case followUp
}

struct ConversationDebugInfo: Sendable {
    let state: ConversationState
    let pendingEventCount: Int
    let pendingResponseCount: Int
    let currentConversationId: UUID?
}
