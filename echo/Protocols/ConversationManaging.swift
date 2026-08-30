import Foundation

/// Protocol for managing conversations
protocol ConversationManaging: Sendable {
    /// Start a new conversation based on an event
    func startConversation(event: CompanionEvent) async throws

    /// Handle an incoming system-triggered event
    func handleIncomingEvent(_ event: CompanionEvent) async throws

    /// Receive a user message (accumulates before LLM reply)
    func sendMessage(_ content: String, conversationId: UUID) async throws

    /// Receive a user image message. The Base64 payload is prepared for a backend upload.
    func sendImageMessage(id: UUID, content: String, imageData: Data, imageMimeType: String, conversationId: UUID) async throws

    /// Retry a previously failed user message without creating a duplicate bubble.
    func resendMessage(id: UUID) async throws

    /// Generate a reply for an accumulated batch of user messages
    func handleAccumulatedBatch(_ batch: AccumulatedMessageBatch) async throws

    /// Called when a delayed event response is delivered
    func handleDelayedResponseDelivered(conversationId: UUID) async

    /// Mark the active conversation complete and process queued events
    func completeConversation() async throws

    /// Get conversation state
    func getConversationState() async -> ConversationState

    /// Get the active conversation identifier
    func getCurrentConversationId() async -> UUID?

    /// Resume user messages that were still waiting for an assistant reply
    /// when the process was killed or background work expired.
    func recoverInterruptedUserReplies() async

    /// Reconcile in-memory conversation state after the app returns to the foreground.
    func reconcileAfterForeground() async

    /// Observe user typing so pending reply delivery can be paused/resumed appropriately.
    func recordTypingActivity(_ text: String) async

    /// Debug snapshot of character schedule state
    func getCharacterScheduleDebugInfo() async -> CharacterScheduleDebugInfo

    /// Force-regenerate the character schedule for debugging
    func regenerateScheduleForDebug() async -> CharacterScheduleDebugInfo

    /// Debug snapshot of conversation orchestration state
    func getDebugInfo() async throws -> ConversationDebugInfo
    
    /// Get all pending events
    func getAllPendingEvents() async throws -> [PendingEvent]
    
    /// Get all pending responses (PR2c: Sendable snapshots, not live models)
    func getAllPendingResponses() async throws -> [PendingResponseSnapshot]
    
    /// Force process pending events
    func forceProcessPendingEvents() async throws
    
    /// Force deliver pending responses
    func forceDeliverPendingResponses() async throws

    /// Persist + schedule OS fallback + arm in-process delivery for proactive care
    /// (online greeting / evening check-in) using the shared PendingResponse path.
    @discardableResult
    func scheduleProactiveAssistantResponse(
        content: String,
        conversationId: UUID,
        eventType: CompanionEventType,
        characterName: String,
        delay: TimeInterval
    ) async throws -> UUID
    
    /// Clear all pending events
    func clearAllPendingEvents() async throws
    
    /// Clear all pending responses
    func clearAllPendingResponses() async throws

    /// Side effects after the user permanently deletes chat messages:
    /// mirror delete into the manager context, recompute silence snapshot,
    /// cancel pending replies for affected conversations, drop in-flight delivery.
    func afterMessagesDeleted(messageIDs: Set<UUID>, conversationIds: Set<UUID>) async
}
