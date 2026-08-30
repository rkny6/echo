import Foundation
import SwiftUI

@MainActor
final class ProactiveFeature {
    private let coordinator: ProactiveEngagementCoordinator
    private let settingsService: SettingsProviding
    private let logger: LoggingProviding
    init(coordinator: ProactiveEngagementCoordinator, settingsService: SettingsProviding, logger: LoggingProviding) { self.coordinator = coordinator; self.settingsService = settingsService; self.logger = logger }
    func runCatchUp(source: String, enabled: Bool, characterName: String, debugFastMode: Bool) async {
        await coordinator.runProactiveCatchUp(source: source, proactiveCaringEnabled: enabled, characterName: characterName, debugFastMode: debugFastMode)
    }
    func handleScheduledOnline(enabled: Bool, characterName: String, debugFastMode: Bool) async {
        await coordinator.handleScheduledOnline(proactiveCaringEnabled: enabled, characterName: characterName, debugFastMode: debugFastMode)
    }
    func catchUpOnlineGreeting(source: String, enabled: Bool, characterName: String, debugFastMode: Bool) async {
        await coordinator.maybeCatchUpOnlineGreeting(source: source, proactiveCaringEnabled: enabled, characterName: characterName, debugFastMode: debugFastMode)
    }
    func catchUpEveningCheckIn(source: String, enabled: Bool, characterName: String, debugFastMode: Bool) async {
        await coordinator.maybeCatchUpEveningCheckIn(source: source, proactiveCaringEnabled: enabled, characterName: characterName, debugFastMode: debugFastMode)
    }
}
