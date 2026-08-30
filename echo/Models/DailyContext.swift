import Foundation
import SwiftData

@Model
final class DailyContext: @unchecked Sendable {
    var id: UUID
    var date: Date
    var context: String
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        context: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.context = context
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum CharacterOnlineStatus: String, Codable, Sendable {
    case online
    case offline
}

@Model
final class CharacterStatus: @unchecked Sendable {
    var id: UUID
    var date: Date
    var currentStatus: CharacterOnlineStatus
    var lastStatusChange: Date
    var lastActivityTime: Date
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        date: Date = Date(),
        currentStatus: CharacterOnlineStatus = .online,
        lastStatusChange: Date = Date(),
        lastActivityTime: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.date = Calendar.current.startOfDay(for: date)
        self.currentStatus = currentStatus
        self.lastStatusChange = lastStatusChange
        self.lastActivityTime = lastActivityTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
