import Foundation
import SwiftUI

@MainActor
final class DiagnosticsFeature {
    private let conversationManager: ConversationManaging
    private let systemEvents: SystemEventCoordinator
    private let logger: LoggingProviding
    private let eventDetection: EventDetecting
    init(conversationManager: ConversationManaging, systemEvents: SystemEventCoordinator, logger: LoggingProviding, eventDetection: EventDetecting) {
        self.conversationManager = conversationManager; self.systemEvents = systemEvents; self.logger = logger; self.eventDetection = eventDetection
    }
    func evaluateSystemTriggers() async { await systemEvents.evaluateSystemTriggers() }
    func characterScheduleDebugInfo() async -> CharacterScheduleDebugInfo { await conversationManager.getCharacterScheduleDebugInfo() }
    func regenerateSchedule() async -> CharacterScheduleDebugInfo { await conversationManager.regenerateScheduleForDebug() }
    func pendingEvents() async -> [PendingEvent] { (try? await conversationManager.getAllPendingEvents()) ?? [] }
    func pendingResponses() async -> [PendingResponseSnapshot] { (try? await conversationManager.getAllPendingResponses()) ?? [] }
}
