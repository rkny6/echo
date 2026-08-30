import Foundation
import SwiftData

extension NotificationIntent {
    static func fromHealthEvent(_ event: CompanionEvent) -> NotificationIntent {
        let kind: NotificationKind
        switch event.type {
        case .sleep:
            kind = .sleep
        case .lowSteps, .highSteps, .lowHRV, .goodSteps, .goodHRV:
            kind = .activity
        default:
            kind = .contextual
        }
        return NotificationIntent(
            kind: kind,
            priority: event.priority,
            context: event.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "),
            source: "health_proactive",
            timestamp: Date()
        )
    }
}
