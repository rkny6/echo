import Foundation
import SwiftData

/// Low-level singleton `ConversationSnapshot` load/save helpers.
///
/// **PR2a:** Production mutation of conversation state / silence timestamps /
/// sticky id must go through `ChatMessageStore` so all writers share one
/// `ModelContext`. Prefer store APIs (`loadConversationSnapshot`,
/// `persistConversationState`, `markHealthProactiveDelivered`, …).
/// Direct use of this type outside the store (or tightly-scoped tests that
/// seed fixture state) risks cross-context clobber.
///
/// Every `save()` here takes a `logger` and reports failures instead of
/// silently discarding them (`try?`) — previously a failed save (disk
/// pressure, migration conflict, etc.) left no trace anywhere, including in
/// `ChatMessageStore`, whose own direct saves *do* propagate/log errors.
enum ConversationSnapshotStore {
    static func load(from modelContext: ModelContext, logger: LoggingProviding?) async -> ConversationSnapshot {
        let singletonId = ConversationSnapshot.singletonId
        let descriptor = FetchDescriptor<ConversationSnapshot>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }

        let snapshot = ConversationSnapshot()
        modelContext.insert(snapshot)
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save initial snapshot: \(error.localizedDescription)",
                level: .error
            )
        }
        return snapshot
    }

    static func save(
        conversationState: ConversationState,
        lastUserMessageAt: Date?,
        lastAssistantMessageAt: Date?,
        currentConversationId: UUID?,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.conversationState = conversationState
        snapshot.lastUserMessageAt = lastUserMessageAt
        snapshot.lastAssistantMessageAt = lastAssistantMessageAt
        snapshot.currentConversationId = currentConversationId
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save conversation snapshot: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    static func updateAfterUserMessage(
        at date: Date,
        conversationId: UUID,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.lastUserMessageAt = date
        snapshot.currentConversationId = conversationId
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save after user message: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    static func updateAfterAssistantMessage(
        at date: Date,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.lastAssistantMessageAt = date
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save after assistant message: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    static func updateConversationState(
        _ state: ConversationState,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.conversationState = state
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save conversation state: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    /// Write sticky conversation id without touching silence timestamps.
    static func updateCurrentConversationId(
        _ conversationId: UUID,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.currentConversationId = conversationId
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save current conversation id: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    /// Apply silence / sticky bookkeeping after chat history changes.
    /// Callers must derive timestamps / ids from `ChatMessageStore` (not raw fetches).
    static func applyHistoryBookkeeping(
        lastUserMessageAt: Date?,
        lastAssistantMessageAt: Date?,
        currentConversationId: UUID?,
        modelContext: ModelContext,
        logger: LoggingProviding?
    ) async {
        let snapshot = await load(from: modelContext, logger: logger)
        snapshot.lastUserMessageAt = lastUserMessageAt
        snapshot.lastAssistantMessageAt = lastAssistantMessageAt
        snapshot.currentConversationId = currentConversationId
        snapshot.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            await logger?.log(
                "ConversationSnapshotStore: failed to save history bookkeeping: \(error.localizedDescription)",
                level: .error
            )
        }
    }
}
