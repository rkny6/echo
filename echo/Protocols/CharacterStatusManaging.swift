import Foundation

/// Behavioral seam for `CharacterStatusManager` — lets ConversationManager
/// depend on the interface so tests can inject a deterministic fake (status,
/// delivery decision) instead of the random schedule-based real actor.
protocol CharacterStatusManaging: Actor {
    /// Register a callback fired whenever the computed online status changes.
    func setOnStatusChange(_ handler: @escaping @Sendable (CharacterOnlineStatus, OnlineTransitionReason?) async -> Void) async

    /// Compute + fire the initial status.
    func initializeStatus(for date: Date) async throws

    /// Record that the user sent a message (may affect schedule behavior).
    func userSentMessage() async throws

    /// Decide how a generated reply should be delivered.
    func decideResponseDelivery() async -> ResponseDeliveryDecision

    /// Bring the character online early (temporary window).
    func comeOnline() async

    /// Mark conversation active/inactive (extends online window while active).
    func setConversationActive(_ active: Bool) async

    /// Whether the character has already reached its planned online window at `date`.
    func hasReachedPlannedOnlineWindow(at date: Date) async -> Bool

    /// Debug snapshot of the schedule at `date`.
    func getScheduleDebugInfo(at date: Date) async -> CharacterScheduleDebugInfo

    /// Regenerate the schedule (debug tool) and return a fresh snapshot.
    func regenerateScheduleForDebug(at date: Date) async -> CharacterScheduleDebugInfo
}
