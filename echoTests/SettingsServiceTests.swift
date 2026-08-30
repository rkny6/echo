import Foundation
import SwiftData
import Testing
@testable import echo

struct SettingsServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func updateSettingsCopiesAllFieldsOntoSingleLiveRow() async throws {
        let container = try makeContainer()
        let logger = MockLoggerService()
        let service = SettingsService(modelContainer: container, logger: logger)

        let live = try await service.getSettings()
        #expect(live.allowImageSending == false)
        #expect(live.proactiveCaringEnabled == true)
        #expect(live.enableMCP == false)
        #expect(live.showUserAvatar == true)
        #expect(live.showCharacterAvatar == true)

        // Throwaway instance (not the live row) — must copy, not insert.
        let draft = AppSettings(
            selectedProvider: .customOpenAICompatible,
            selectedModel: "test-model",
            temperature: 0.42,
            maxTokens: 1234,
            customBaseURL: "https://example.test/v1",
            endpointMode: .responses,
            systemPromptOverride: "override",
            debugModeEnabled: true,
            useAgnesCloudImageRecognition: true,
            allowImageSending: true,
            proactiveCaringEnabled: false,
            enableMCP: true,
            showUserAvatar: false,
            showCharacterAvatar: false
        )
        try await service.updateSettings(draft)

        let after = try await service.getSettings()
        // `getSettings()` returns a detached value copy (never the live
        // SwiftData row — MainActor reads racing the actor's save() on the
        // same ModelContext is undefined behavior). Assert field values
        // instead of identity; durable single-row state is checked below.
        #expect(after.selectedModel == "test-model")
        #expect(after.temperature == 0.42)
        #expect(after.maxTokens == 1234)
        #expect(after.customBaseURL == "https://example.test/v1")
        #expect(after.endpointMode == .responses)
        #expect(after.systemPromptOverride == "override")
        #expect(after.debugModeEnabled == true)
        #expect(after.useAgnesCloudImageRecognition == true)
        #expect(after.allowImageSending == true)
        #expect(after.proactiveCaringEnabled == false)
        #expect(after.enableMCP == true)
        #expect(after.showUserAvatar == false)
        #expect(after.showCharacterAvatar == false)

        // Re-fetch via a fresh context so we assert durable store state, not
        // only the in-memory registered object held by the service.
        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<AppSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.selectedModel == "test-model")
        #expect(rows.first?.allowImageSending == true)
        #expect(rows.first?.proactiveCaringEnabled == false)
        #expect(rows.first?.enableMCP == true)
        #expect(rows.first?.showUserAvatar == false)
        #expect(rows.first?.showCharacterAvatar == false)
    }

    @Test func initPrunesExtraAppSettingsRows() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(AppSettings(selectedModel: "row-a"))
        seed.insert(AppSettings(selectedModel: "row-b"))
        try seed.save()

        let logger = MockLoggerService()
        let service = SettingsService(modelContainer: container, logger: logger)
        let live = try await service.getSettings()
        // Fetch order is not stable; keep whichever row SwiftData returns first.
        #expect(["row-a", "row-b"].contains(live.selectedModel))

        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<AppSettings>())
        #expect(rows.count == 1)
        #expect(rows.first?.selectedModel == live.selectedModel)
    }
}
