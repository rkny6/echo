import Foundation
import SwiftData

/// Stores relationship memory and context about the user
@Model
final class RelationshipMemory: @unchecked Sendable {
    @Attribute(.unique) var id: UUID
    var summary: String
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        summary: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.summary = summary
        self.updatedAt = updatedAt
    }
}
