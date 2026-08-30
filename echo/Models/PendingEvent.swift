import Foundation
import SwiftData

@Model
final class PendingEvent: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    var eventType: CompanionEventType
    var timestamp: Date
    var priority: Int
    var metadata: [String: String]
    
    init(
        id: UUID = UUID(),
        eventType: CompanionEventType,
        timestamp: Date = Date(),
        priority: Int,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.eventType = eventType
        self.timestamp = timestamp
        self.priority = priority
        self.metadata = metadata
    }
    
    convenience init(event: CompanionEvent) {
        self.init(
            eventType: event.type,
            timestamp: event.timestamp,
            priority: event.priority,
            metadata: event.metadata
        )
    }
    
    func toCompanionEvent() -> CompanionEvent {
        CompanionEvent(
            type: eventType,
            timestamp: timestamp,
            priority: priority,
            metadata: metadata
        )
    }
}
