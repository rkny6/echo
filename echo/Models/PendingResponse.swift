import Foundation
import SwiftData

enum PendingResponseStatus: String, Codable, Sendable {
    case pending
    case delivered
    case cancelled
}

/// Sendable read model for pending delayed replies (PR2c/d).
/// Durable rows are owned by `ChatMessageStore`; DRM only orchestrates delivery.
struct PendingResponseSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let content: String
    let createdAt: Date
    let scheduledDeliveryTime: Date
    let conversationId: UUID
    let eventType: CompanionEventType?
    let status: PendingResponseStatus

    init(
        id: UUID,
        content: String,
        createdAt: Date,
        scheduledDeliveryTime: Date,
        conversationId: UUID,
        eventType: CompanionEventType?,
        status: PendingResponseStatus
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.scheduledDeliveryTime = scheduledDeliveryTime
        self.conversationId = conversationId
        self.eventType = eventType
        self.status = status
    }

    init(from response: PendingResponse) {
        self.id = response.id
        self.content = response.content
        self.createdAt = response.createdAt
        self.scheduledDeliveryTime = response.scheduledDeliveryTime
        self.conversationId = response.conversationId
        self.eventType = response.eventType
        self.status = response.status
    }
}

/// Insert draft for delayed assistant replies (PR2d).
struct PendingResponseDraft: Sendable {
    var id: UUID
    var content: String
    var createdAt: Date
    var scheduledDeliveryTime: Date
    var conversationId: UUID
    var eventType: CompanionEventType?
    var status: PendingResponseStatus

    init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = Date(),
        scheduledDeliveryTime: Date,
        conversationId: UUID,
        eventType: CompanionEventType? = nil,
        status: PendingResponseStatus = .pending
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.scheduledDeliveryTime = scheduledDeliveryTime
        self.conversationId = conversationId
        self.eventType = eventType
        self.status = status
    }
}

@Model
final class PendingResponse: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    var content: String
    var createdAt: Date
    var scheduledDeliveryTime: Date
    var conversationId: UUID
    var eventType: CompanionEventType?
    var status: PendingResponseStatus
    
    init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = Date(),
        scheduledDeliveryTime: Date,
        conversationId: UUID,
        eventType: CompanionEventType? = nil,
        status: PendingResponseStatus = .pending
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.scheduledDeliveryTime = scheduledDeliveryTime
        self.conversationId = conversationId
        self.eventType = eventType
        self.status = status
    }
}
