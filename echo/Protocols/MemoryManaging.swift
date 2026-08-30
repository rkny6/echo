import Foundation

/// Read-only snapshot of user-facing memory for UI (not SwiftData models).
struct UserFacingMemorySnapshot: Sendable, Equatable {
    var longTermSummary: String
    var longTermLastUpdated: Date?
    var extractedUserProfile: [String: String]
    var totalMessagesProcessed: Int
    var unsummarizedMessageCount: Int

    static let empty = UserFacingMemorySnapshot(
        longTermSummary: "",
        longTermLastUpdated: nil,
        extractedUserProfile: [:],
        totalMessagesProcessed: 0,
        unsummarizedMessageCount: 0
    )

    var hasLongTermSummary: Bool {
        !longTermSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasExtractedUserProfile: Bool {
        !extractedUserProfile.isEmpty
    }

    var isCompletelyEmpty: Bool {
        !hasLongTermSummary && !hasExtractedUserProfile
    }
}

/// Protocol for reading and writing the companion's long-term/relationship memory.
///
/// `MemoryManager` is currently the only conformer. Extracting this protocol doesn't
/// change its behavior — it exists so callers (`ConversationManager` today; the
/// event-generation services later, if they're ever given a memory dependency) depend
/// on this narrow surface instead of the concrete actor, and so a future
/// implementation (e.g. one backed by discrete, individually-retrievable fact records
/// instead of a single rolling summary) can be swapped in without touching any call site.
protocol MemoryManaging: Sendable {
    /// Record a message and let the manager decide whether accumulated context now
    /// warrants a long-term summary update. Accepts store-owned chat snapshots only.
    func addMessage(_ message: ChatMessageSnapshot, userName: String, characterName: String) async

    /// Drop messages the user deleted so they are not folded into the next
    /// long-term summary. Does not rewrite existing summaries.
    func removeMessages(_ messageIDs: Set<UUID>) async

    /// Current long-term memory context: the rolling summary, extracted user profile,
    /// and a bounded window of recent raw messages (store snapshots).
    func getMemoryContext(
        userName: String,
        characterName: String,
        recentMessageLimit: Int?
    ) async -> (globalSummary: String, userProfile: [String: String], recentMessages: [ChatMessageSnapshot])

    /// Snapshot for settings/UI: long-term facts extracted so far.
    func loadUserFacingMemory() async -> UserFacingMemorySnapshot

    /// Clear rolling long-term summary text (keeps extracted profile).
    func clearLongTermSummary() async

    /// Clear LLM-extracted user profile facts stored on long-term memory.
    func clearExtractedUserProfile() async
}

extension MemoryManaging {
    // Protocols can't declare default parameter values directly — this overload
    // preserves the `recentMessageLimit` default the concrete MemoryManager already
    // has, so existing call sites that omit it (there are two, in ConversationManager)
    // keep compiling unchanged after switching their `memoryManager` property to this
    // protocol type.
    func getMemoryContext(
        userName: String,
        characterName: String
    ) async -> (globalSummary: String, userProfile: [String: String], recentMessages: [ChatMessageSnapshot]) {
        await getMemoryContext(userName: userName, characterName: characterName, recentMessageLimit: nil)
    }
}
