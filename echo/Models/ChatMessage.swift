import Foundation
import SwiftData

enum MessageDeliveryStatus: String, Codable, Sendable {
    case recognizing
    case sending
    case completed
    case failed
}

/// Represents a single chat message
@Model
final class ChatMessage: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
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
    var statusRaw: String = MessageDeliveryStatus.completed.rawValue

    var hasImage: Bool {
        imageData != nil
    }

    var imageBase64: String? {
        imageData?.base64EncodedString()
    }

    var imageRecognitionDescription: String? {
        metadata?["imageRecognitionDescription"]
    }

    var status: MessageDeliveryStatus {
        get {
            MessageDeliveryStatus(rawValue: statusRaw) ?? .completed
        }
        set {
            statusRaw = newValue.rawValue
        }
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
        id: UUID = UUID(),
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
        self.statusRaw = status.rawValue
    }
}
