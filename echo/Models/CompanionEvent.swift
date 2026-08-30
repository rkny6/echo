import Foundation
import SwiftData

/// Represents a detected life event
@Model
final class CompanionEvent: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    var type: CompanionEventType
    var timestamp: Date
    var priority: Int
    var metadata: [String: String]
    var isProcessed: Bool
    
    init(
        id: UUID = UUID(),
        type: CompanionEventType,
        timestamp: Date = Date(),
        priority: Int? = nil,
        metadata: [String: String] = [:],
        isProcessed: Bool = false
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.priority = priority ?? type.defaultPriority
        self.metadata = metadata
        self.isProcessed = isProcessed
    }
}
