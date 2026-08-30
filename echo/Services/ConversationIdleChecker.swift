import Foundation

/// Determines whether proactive health / care messages may be sent (persisted, background-safe).
///
/// All durable idle inputs go through `ChatMessageStore` (PR2a snapshot + PR2b
/// pending/health-job reads + unread assistant). Callers no longer pass a
/// separate `ModelContext` for these gates.
enum ConversationIdleChecker {
    private static let inactivityTimeout: TimeInterval = 300
    private static let unreadAssistantWindow: TimeInterval = 30 * 60

    /// Routes every idle gate through `ChatMessageStore`.
    ///
    /// The only path back to `.idle` is an in-process timer inside
    /// ConversationManager (a 5-minute Task.sleep), which doesn't
    /// reliably fire once the app is backgrounded — it gets suspended
    /// along with everything else. If we trusted the persisted state
    /// literally, a conversation that went non-idle and then got
    /// backgrounded before that timer fired would block proactive
    /// health messages indefinitely, even though nothing is actually
    /// happening. So: also accept "no real activity for long enough"
    /// as effectively idle, using the same timeout.
    static func isIdle(chatMessageStore: ChatMessageStore) async -> Bool {
        let snapshot = await chatMessageStore.loadConversationSnapshot()
        let now = Date()

        if snapshot.conversationState != .idle {
            guard now.timeIntervalSince(snapshot.lastActivityAt) >= inactivityTimeout else {
                AppLog.debug("ConversationIdleChecker", "Not idle: state=\(snapshot.conversationState.rawValue)")
                return false
            }
        }

        if let lastUser = snapshot.lastUserMessageAt,
           now.timeIntervalSince(lastUser) < inactivityTimeout {
            AppLog.debug(
                "ConversationIdleChecker",
                "Not idle: user message \(Int(now.timeIntervalSince(lastUser)))s ago"
            )
            return false
        }

        if await chatMessageStore.hasPendingDelayedResponses() {
            AppLog.debug("ConversationIdleChecker", "Not idle: pending DelayedResponse exists")
            return false
        }

        if await chatMessageStore.hasGeneratingHealthJobs() {
            AppLog.debug("ConversationIdleChecker", "Not idle: health LLM job in progress")
            return false
        }

        let cutoff = now.addingTimeInterval(-unreadAssistantWindow)
        let hasUnread: Bool
        do {
            hasUnread = try await chatMessageStore.hasRecentUnreadAssistant(since: cutoff)
        } catch {
            // Fail closed for proactive sends if store is unavailable.
            hasUnread = true
        }
        if hasUnread {
            AppLog.debug("ConversationIdleChecker", "Not idle: recent unread assistant message")
            return false
        }

        return true
    }

    static func lastUserMessageDate(chatMessageStore: ChatMessageStore) async -> Date? {
        await chatMessageStore.lastUserMessageAt()
    }
}
