import Foundation

/// UI- and pipeline-facing chat row. Sendable projection of `ChatMessage`
/// so callers never hold a cross-context `@Model` reference.
struct ChatMessageSnapshot: Sendable, Equatable, Identifiable {
    let id: UUID
    var role: MessageRole
    var content: String
    var timestamp: Date
    var eventType: CompanionEventType?
    var conversationId: UUID?
    var metadata: [String: String]?
    var isRead: Bool
    var isFailed: Bool?
    var errorMessage: String?
    var imageData: Data?
    var imageMimeType: String?
    var status: MessageDeliveryStatus

    var hasImage: Bool { imageData != nil }

    var imageRecognitionDescription: String? {
        metadata?["imageRecognitionDescription"]
    }

    var imageBase64: String? {
        imageData?.base64EncodedString()
    }

    var llmContextContent: String {
        guard hasImage else { return content }

        let imageDescription = imageRecognitionDescription ?? "用户发了一张图片"
        let imageContext = "用户发了一张图片，内容是：\(imageDescription)"
        guard !content.isEmpty else {
            return imageContext
        }
        return "\(content)\n\(imageContext)"
    }

    init(
        id: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        eventType: CompanionEventType? = nil,
        conversationId: UUID? = nil,
        metadata: [String: String]? = nil,
        isRead: Bool = false,
        isFailed: Bool? = false,
        errorMessage: String? = nil,
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        status: MessageDeliveryStatus = .completed
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.eventType = eventType
        self.conversationId = conversationId
        self.metadata = metadata
        self.isRead = isRead
        self.isFailed = isFailed
        self.errorMessage = errorMessage
        self.imageData = imageData
        self.imageMimeType = imageMimeType
        self.status = status
    }

    /// Only call inside `ChatMessageStore` (or tests with a live model instance).
    init(from message: ChatMessage) {
        self.id = message.id
        self.role = message.role
        self.content = message.content
        self.timestamp = message.timestamp
        self.eventType = message.eventType
        self.conversationId = message.conversationId
        self.metadata = message.metadata
        self.isRead = message.isRead
        self.isFailed = message.isFailed
        self.errorMessage = message.errorMessage
        self.imageData = message.imageData
        self.imageMimeType = message.imageMimeType
        self.status = message.status
    }
}

/// Draft for inserting a user chat row through `ChatMessageStore`.
struct UserMessageDraft: Sendable {
    var id: UUID = UUID()
    var content: String
    var timestamp: Date = Date()
    var conversationId: UUID?
    var metadata: [String: String]? = nil
    var isRead: Bool = true
    var imageData: Data? = nil
    var imageMimeType: String? = nil
    var status: MessageDeliveryStatus = .sending
}

/// Draft for one assistant bubble (PR1b will use this on all delivery paths).
struct AssistantSegmentDraft: Sendable {
    var id: UUID = UUID()
    var content: String
    var timestamp: Date = Date()
    var conversationId: UUID?
    var eventType: CompanionEventType? = nil
    var metadata: [String: String]? = nil
    var isRead: Bool = false
}

/// Broadcast after durable chat mutations.
enum ChatHistoryChange: Sendable, Equatable {
    case upserted([ChatMessageSnapshot])
    case deleted(Set<UUID>)
}

struct ChatMessageDeleteResult: Sendable, Equatable {
    let deletedIDs: Set<UUID>
    let affectedConversationIds: Set<UUID>
}
