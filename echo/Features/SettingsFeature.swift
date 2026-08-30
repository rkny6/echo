import Foundation
import SwiftUI

@MainActor
final class SettingsFeature {
    private let service: SettingsProviding
    private let llmFactory: LLMServiceFactory
    private let logger: LoggingProviding
    init(settingsService: SettingsProviding, llmFactory: LLMServiceFactory, logger: LoggingProviding) { self.service = settingsService; self.llmFactory = llmFactory; self.logger = logger }
    func get() async throws -> AppSettings { try await service.getSettings() }
    func update(_ settings: AppSettings) async throws { try await service.updateSettings(settings) }
    func testProvider(settings: AppSettings) async throws -> Bool { try await llmFactory.createProvider(settings: settings).testConnection() }
}
