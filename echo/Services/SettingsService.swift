import Foundation
import SwiftData

/// Service for managing app settings.
///
/// Owns a private `ModelContext` (Profile/Diary-style) so its async reads and
/// writes never share a `ModelContext` instance with MainActor code or any
/// other actor — a single `ModelContext` is not safe to touch concurrently
/// from multiple isolation domains, even though it's `@unchecked Sendable`
/// and the compiler won't flag it.
actor SettingsService: SettingsProviding {
    private let modelContext: ModelContext
    private var settings: AppSettings
    private let logger: LoggingProviding
    
    init(modelContainer: ModelContainer, logger: LoggingProviding) {
        let context = ModelContext(modelContainer)
        self.modelContext = context
        self.logger = logger

        do {
            if let persistedSettings = try Self.loadPersistedSettings(in: context, logger: logger) {
                self.settings = persistedSettings
                return
            }
        } catch {
            // Fall through to creating a fresh row below; still worth knowing
            // why the fetch itself failed (e.g. corrupt store), not just that
            // we ended up on the fallback path.
            Task { await logger.log(
                "SettingsService: failed to fetch persisted settings, creating a fresh row: \(error.localizedDescription)",
                level: .error
            ) }
        }

        // Fresh instance — never insert `AppSettings.default` (shared static)
        // into SwiftData; that can leave zero durable rows / cross-context bugs.
        let defaultSettings = AppSettings()
        context.insert(defaultSettings)
        do {
            try context.save()
        } catch {
            Task { await logger.log(
                "SettingsService: failed to save newly-created default AppSettings row: \(error.localizedDescription)",
                level: .error
            ) }
        }
        self.settings = defaultSettings
    }
    
    func getSettings() async throws -> AppSettings {
        // Never hand the live SwiftData row to callers. Property access on a
        // @Model routes through the owning ModelContext, which must only ever
        // be touched by this actor (serialized). MainActor reads — SwiftUI
        // body re-eval via `ToggleRow` get:, `SettingsScreen` form sync, and
        // `AppSettings.copy()` in updateSetting/saveSettings/applyProfile —
        // racing this actor's `save()` on the same context is undefined
        // behavior: it produced the store-lock deadlock and can also trap
        // (EXC_BREAKPOINT) inside SwiftData. Return a detached value copy;
        // all property reads below happen on the actor, serialized.
        return settings.copy()
    }
    
    func updateSettings(_ newSettings: AppSettings) async throws {
        // Always mutate the service-owned live row. Callers may pass the same
        // instance or a throwaway AppSettings; never adopt/insert a second row
        // — copy values onto `settings` instead. Apply-profile must field-copy
        // API fields onto the live row (never replace the settings instance).
        settings.selectedProvider = newSettings.selectedProvider
        settings.selectedModel = newSettings.selectedModel
        settings.temperature = newSettings.temperature
        settings.maxTokens = newSettings.maxTokens
        settings.customBaseURL = newSettings.customBaseURL
        settings.endpointMode = newSettings.endpointMode
        settings.systemPromptOverride = newSettings.systemPromptOverride
        settings.debugModeEnabled = newSettings.debugModeEnabled
        settings.useAgnesCloudImageRecognition = newSettings.useAgnesCloudImageRecognition
        settings.allowImageSending = newSettings.allowImageSending
        settings.proactiveCaringEnabled = newSettings.proactiveCaringEnabled
        settings.useLLMProactiveJudgment = newSettings.useLLMProactiveJudgment
        settings.enableMCP = newSettings.enableMCP
        settings.mcpServerURL = newSettings.mcpServerURL
        settings.showUserAvatar = newSettings.showUserAvatar
        settings.showCharacterAvatar = newSettings.showCharacterAvatar
        try modelContext.save()
    }
    
    func getSetting<T>(_ key: String) async throws -> T? {
        switch key {
        case "selectedProvider":
            return settings.selectedProvider as? T
        case "selectedModel":
            return settings.selectedModel as? T
        case "temperature":
            return settings.temperature as? T
        case "maxTokens":
            return settings.maxTokens as? T
        case "customBaseURL":
            return settings.customBaseURL as? T
        case "endpointMode":
            return settings.endpointMode as? T
        case "debugModeEnabled":
            return settings.debugModeEnabled as? T
        case "useAgnesCloudImageRecognition":
            return settings.useAgnesCloudImageRecognition as? T
        case "allowImageSending":
            return settings.allowImageSending as? T
        case "proactiveCaringEnabled":
            return settings.proactiveCaringEnabled as? T
        case "enableMCP":
            return settings.enableMCP as? T
        case "mcpServerURL":
            return settings.mcpServerURL as? T
        case "showUserAvatar":
            return settings.showUserAvatar as? T
        case "showCharacterAvatar":
            return settings.showCharacterAvatar as? T
        default:
            return nil
        }
    }
    
    func setSetting<T>(_ key: String, value: T) async throws {
        switch key {
        case "selectedProvider":
            if let provider = value as? LLMProvider {
                settings.selectedProvider = provider
            }
        case "selectedModel":
            if let model = value as? String {
                settings.selectedModel = model
            }
        case "temperature":
            if let temp = value as? Double {
                settings.temperature = temp
            }
        case "maxTokens":
            if let tokens = value as? Int {
                settings.maxTokens = tokens
            }
        case "customBaseURL":
            if let url = value as? String {
                settings.customBaseURL = url
            }
        case "endpointMode":
            if let mode = value as? LLMAPIEndpointMode {
                settings.endpointMode = mode
            }
        case "debugModeEnabled":
            if let debug = value as? Bool {
                settings.debugModeEnabled = debug
            }
        case "useAgnesCloudImageRecognition":
            if let useCloud = value as? Bool {
                settings.useAgnesCloudImageRecognition = useCloud
            }
        case "allowImageSending":
            if let enabled = value as? Bool {
                settings.allowImageSending = enabled
            }
        case "proactiveCaringEnabled":
            if let enabled = value as? Bool {
                settings.proactiveCaringEnabled = enabled
            }
        case "enableMCP":
            if let enabled = value as? Bool {
                settings.enableMCP = enabled
            }
        case "mcpServerURL":
            if let url = value as? String {
                settings.mcpServerURL = url
            }
        case "showUserAvatar":
            if let enabled = value as? Bool {
                settings.showUserAvatar = enabled
            }
        case "showCharacterAvatar":
            if let enabled = value as? Bool {
                settings.showCharacterAvatar = enabled
            }
        default:
            break
        }
        try modelContext.save()
    }

    /// Keep a single AppSettings row. Extra rows (legacy dual-insert) are pruned.
    private static func loadPersistedSettings(in modelContext: ModelContext, logger: LoggingProviding) throws -> AppSettings? {
        let request = FetchDescriptor<AppSettings>()
        let settingsResults = try modelContext.fetch(request)
        guard let first = settingsResults.first else { return nil }
        if settingsResults.count > 1 {
            for extra in settingsResults.dropFirst() {
                modelContext.delete(extra)
            }
            do {
                try modelContext.save()
            } catch {
                let message = "SettingsService: failed to save after pruning extra AppSettings rows: \(error.localizedDescription)"
                Task { await logger.log(message, level: .error) }
            }
        }
        return first
    }
}
