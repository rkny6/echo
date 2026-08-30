import Foundation
import SwiftData

enum PendingHealthLLMJobStatus: String, Codable, Sendable {
    case pending
    case generating
    case delivered
    case failed
}

/// Sendable read model for health proactive LLM jobs (PR2e).
/// Durable rows are owned by `ChatMessageStore`; HealthProactiveDeliveryService
/// only orchestrates detection / LLM / delivery / alert-record side effects.
struct PendingHealthLLMJobSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    let eventType: CompanionEventType
    let metadata: [String: String]
    let status: PendingHealthLLMJobStatus
    let dedupKey: String
    let createdAt: Date
    let retryCount: Int
    let conversationId: UUID

    init(
        id: UUID,
        eventType: CompanionEventType,
        metadata: [String: String],
        status: PendingHealthLLMJobStatus,
        dedupKey: String,
        createdAt: Date,
        retryCount: Int,
        conversationId: UUID
    ) {
        self.id = id
        self.eventType = eventType
        self.metadata = metadata
        self.status = status
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.conversationId = conversationId
    }

    init(from job: PendingHealthLLMJob) {
        self.id = job.id
        self.eventType = job.eventType
        self.metadata = job.metadata
        self.status = job.status
        self.dedupKey = job.dedupKey
        self.createdAt = job.createdAt
        self.retryCount = job.retryCount
        self.conversationId = job.conversationId
    }

    func toCompanionEvent() -> CompanionEvent {
        CompanionEvent(type: eventType, metadata: metadata)
    }
}

/// Insert draft for health proactive LLM jobs (PR2e).
struct PendingHealthLLMJobDraft: Sendable {
    var id: UUID
    var eventType: CompanionEventType
    var metadata: [String: String]
    var status: PendingHealthLLMJobStatus
    var dedupKey: String
    var createdAt: Date
    var retryCount: Int
    var conversationId: UUID

    init(
        id: UUID = UUID(),
        eventType: CompanionEventType,
        metadata: [String: String] = [:],
        status: PendingHealthLLMJobStatus = .pending,
        dedupKey: String,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        conversationId: UUID = UUID()
    ) {
        self.id = id
        self.eventType = eventType
        self.metadata = metadata
        self.status = status
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.conversationId = conversationId
    }
}

/// Queued LLM generation job for proactive health notifications (survives app suspension).
@Model
final class PendingHealthLLMJob: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    var eventTypeRaw: String
    var metadata: [String: String]
    var statusRaw: String
    var dedupKey: String
    var createdAt: Date
    var retryCount: Int
    var conversationId: UUID

    init(
        id: UUID = UUID(),
        eventType: CompanionEventType,
        metadata: [String: String] = [:],
        status: PendingHealthLLMJobStatus = .pending,
        dedupKey: String,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        conversationId: UUID = UUID()
    ) {
        self.id = id
        self.eventTypeRaw = eventType.rawValue
        self.metadata = metadata
        self.statusRaw = status.rawValue
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.conversationId = conversationId
    }

    var eventType: CompanionEventType {
        CompanionEventType(rawValue: eventTypeRaw) ?? .sleep
    }

    var status: PendingHealthLLMJobStatus {
        get { PendingHealthLLMJobStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    func toCompanionEvent() -> CompanionEvent {
        CompanionEvent(
            type: eventType,
            metadata: metadata
        )
    }
}
