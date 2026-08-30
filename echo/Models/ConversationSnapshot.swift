import Foundation
import SwiftData

/// Cross-actor read model for the singleton conversation snapshot.
///
/// Prefer this over holding a live `ConversationSnapshot` model outside
/// `ChatMessageStore` (PR2a single-owner boundary).
struct ConversationSnapshotData: Sendable, Equatable {
    var conversationState: ConversationState
    var lastUserMessageAt: Date?
    var lastAssistantMessageAt: Date?
    var currentConversationId: UUID?
    var updatedAt: Date

    init(
        conversationState: ConversationState = .idle,
        lastUserMessageAt: Date? = nil,
        lastAssistantMessageAt: Date? = nil,
        currentConversationId: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.conversationState = conversationState
        self.lastUserMessageAt = lastUserMessageAt
        self.lastAssistantMessageAt = lastAssistantMessageAt
        self.currentConversationId = currentConversationId
        self.updatedAt = updatedAt
    }

    init(from model: ConversationSnapshot) {
        self.conversationState = model.conversationState
        self.lastUserMessageAt = model.lastUserMessageAt
        self.lastAssistantMessageAt = model.lastAssistantMessageAt
        self.currentConversationId = model.currentConversationId
        self.updatedAt = model.updatedAt
    }

    /// Latest of user / assistant activity, falling back to `updatedAt`.
    var lastActivityAt: Date {
        [lastUserMessageAt, lastAssistantMessageAt]
            .compactMap { $0 }
            .max() ?? updatedAt
    }
}

/// Persisted conversation orchestration state for background idle checks.
@Model
final class ConversationSnapshot: @unchecked Sendable {
    static let singletonId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Attribute(.unique) var id: UUID
    var conversationStateRaw: String
    var lastUserMessageAt: Date?
    var lastAssistantMessageAt: Date?
    var currentConversationId: UUID?
    var updatedAt: Date

    init(
        id: UUID = ConversationSnapshot.singletonId,
        conversationState: ConversationState = .idle,
        lastUserMessageAt: Date? = nil,
        lastAssistantMessageAt: Date? = nil,
        currentConversationId: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationStateRaw = conversationState.rawValue
        self.lastUserMessageAt = lastUserMessageAt
        self.lastAssistantMessageAt = lastAssistantMessageAt
        self.currentConversationId = currentConversationId
        self.updatedAt = updatedAt
    }

    var conversationState: ConversationState {
        get { ConversationState(rawValue: conversationStateRaw) ?? .idle }
        set { conversationStateRaw = newValue.rawValue }
    }
}
