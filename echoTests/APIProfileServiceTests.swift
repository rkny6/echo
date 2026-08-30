import Foundation
import SwiftData
import Testing
@testable import echo

struct APIProfileServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([APIProfile.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func createAndLoadAllReturnsSnapshotsSortedByUpdatedAtDescending() async throws {
        let container = try makeContainer()
        let service = APIProfileService(modelContainer: container, logger: MockLoggerService())

        let older = try await service.create(
            name: "older",
            provider: .customOpenAICompatible,
            baseURL: "https://old.example/v1",
            model: "old-model",
            endpointMode: .chatCompletions,
            temperature: 0.2,
            maxTokens: 500
        )
        // Ensure newer row sorts first even if clocks are coarse.
        try await Task.sleep(nanoseconds: 20_000_000)
        let newer = try await service.create(
            name: "newer",
            provider: .customOpenAICompatible,
            baseURL: "https://new.example/v1",
            model: "new-model",
            endpointMode: .responses,
            temperature: 0.9,
            maxTokens: 3000
        )

        let loaded = await service.loadAll()
        #expect(loaded.count == 2)
        #expect(loaded[0].id == newer.id)
        #expect(loaded[0].name == "newer")
        #expect(loaded[0].endpointMode == .responses)
        #expect(loaded[1].id == older.id)
        #expect(loaded[1].keychainKeyName == "api_key_profile_\(older.id.uuidString)")

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<APIProfile>()).count == 2)
    }

    @Test func updateCopiesFieldsOntoExistingRowWithoutInsertingDraft() async throws {
        let container = try makeContainer()
        let service = APIProfileService(modelContainer: container, logger: MockLoggerService())

        let created = try await service.create(
            name: "draft",
            provider: .customOpenAICompatible,
            baseURL: nil,
            model: "base-model",
            endpointMode: .chatCompletions,
            temperature: 0.5,
            maxTokens: 1000
        )

        try await service.update(
            id: created.id,
            name: "prod",
            baseURL: "https://api.example/v1",
            model: "prod-model",
            endpointMode: .responses,
            temperature: 0.3,
            maxTokens: 4096
        )

        let loaded = await service.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == created.id)
        #expect(loaded[0].name == "prod")
        #expect(loaded[0].baseURL == "https://api.example/v1")
        #expect(loaded[0].model == "prod-model")
        #expect(loaded[0].endpointMode == .responses)
        #expect(loaded[0].temperature == 0.3)
        #expect(loaded[0].maxTokens == 4096)
        #expect(loaded[0].createdAt == created.createdAt)
        #expect(loaded[0].updatedAt >= created.updatedAt)

        let verify = ModelContext(container)
        let rows = try verify.fetch(FetchDescriptor<APIProfile>())
        #expect(rows.count == 1)
        #expect(rows.first?.name == "prod")
        #expect(rows.first?.model == "prod-model")
        #expect(rows.first?.id == created.id)
    }

    @Test func deleteRemovesDurableRow() async throws {
        let container = try makeContainer()
        let service = APIProfileService(modelContainer: container, logger: MockLoggerService())

        let created = try await service.create(
            name: "temp",
            provider: .customOpenAICompatible,
            baseURL: nil,
            model: "m",
            endpointMode: .chatCompletions,
            temperature: 0.7,
            maxTokens: 2000
        )
        #expect((await service.loadAll()).count == 1)

        try await service.delete(id: created.id)
        #expect((await service.loadAll()).isEmpty)

        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<APIProfile>()).count == 0)
    }

    @Test func siblingSeededRowsAreVisibleToService() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let seeded = APIProfile(
            name: "seeded",
            provider: .customOpenAICompatible,
            baseURL: "https://seed.example/v1",
            model: "seed-model",
            endpointMode: .chatCompletions,
            temperature: 0.4,
            maxTokens: 800
        )
        seed.insert(seeded)
        try seed.save()
        let seededId = seeded.id

        let service = APIProfileService(modelContainer: container, logger: MockLoggerService())
        let loaded = await service.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == seededId)
        #expect(loaded[0].name == "seeded")
        #expect(loaded[0].model == "seed-model")
    }
}
