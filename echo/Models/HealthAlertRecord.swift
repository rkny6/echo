import Foundation
import SwiftData

/// Sendable read model for delivered health proactive alerts (PR2f).
/// Durable rows are owned by `ChatMessageStore`; HealthProactiveDeliveryService
/// only orchestrates detection / LLM / delivery and records alerts via the store.
struct HealthAlertRecordSnapshot: Sendable, Identifiable, Equatable {
    /// Stable identity for Identifiable; matches unique `dedupKey`.
    var id: String { dedupKey }

    let dedupKey: String
    let eventType: CompanionEventType
    let alertDate: Date
    let sentAt: Date
    let messageId: UUID
    let usedLLM: Bool

    init(
        dedupKey: String,
        eventType: CompanionEventType,
        alertDate: Date,
        sentAt: Date,
        messageId: UUID,
        usedLLM: Bool
    ) {
        self.dedupKey = dedupKey
        self.eventType = eventType
        self.alertDate = alertDate
        self.sentAt = sentAt
        self.messageId = messageId
        self.usedLLM = usedLLM
    }

    init(from record: HealthAlertRecord) {
        self.dedupKey = record.dedupKey
        self.eventType = record.eventType
        self.alertDate = record.alertDate
        self.sentAt = record.sentAt
        self.messageId = record.messageId
        self.usedLLM = record.usedLLM
    }
}

/// Insert draft for health alert dedup rows (PR2f).
struct HealthAlertRecordDraft: Sendable {
    var dedupKey: String
    var eventType: CompanionEventType
    var alertDate: Date
    var sentAt: Date
    var messageId: UUID
    var usedLLM: Bool

    init(
        dedupKey: String,
        eventType: CompanionEventType,
        alertDate: Date,
        sentAt: Date = Date(),
        messageId: UUID,
        usedLLM: Bool
    ) {
        self.dedupKey = dedupKey
        self.eventType = eventType
        self.alertDate = alertDate
        self.sentAt = sentAt
        self.messageId = messageId
        self.usedLLM = usedLLM
    }
}

/// Records a delivered proactive health alert to prevent duplicate sends per day.
@Model
final class HealthAlertRecord: @unchecked Sendable {
    @Attribute(.unique) var dedupKey: String
    var eventTypeRaw: String
    var alertDate: Date
    var sentAt: Date
    var messageId: UUID
    var usedLLM: Bool

    init(
        dedupKey: String,
        eventType: CompanionEventType,
        alertDate: Date,
        sentAt: Date = Date(),
        messageId: UUID,
        usedLLM: Bool
    ) {
        self.dedupKey = dedupKey
        self.eventTypeRaw = eventType.rawValue
        self.alertDate = alertDate
        self.sentAt = sentAt
        self.messageId = messageId
        self.usedLLM = usedLLM
    }

    var eventType: CompanionEventType {
        CompanionEventType(rawValue: eventTypeRaw) ?? .sleep
    }
}
