import Foundation
import SwiftData

/// Sole durable owner for `APIProfile` rows.
///
/// Uses a private `ModelContext` (Diary / Profile-style). UI and AppViewModel
/// read via snapshots and write only through create / update / delete — never
/// insert or mutate `APIProfile` on the shared UI context.
actor APIProfileService: APIProfileProviding {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let logger: LoggingProviding

    init(
        modelContainer: ModelContainer,
        logger: LoggingProviding
    ) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.logger = logger
    }

    // MARK: - APIProfileProviding

    func loadAll() async -> [APIProfileSnapshot] {
        do {
            let request = FetchDescriptor<APIProfile>(
                sortBy: [SortDescriptor(\APIProfile.updatedAt, order: .reverse)]
            )
            return try modelContext.fetch(request).map(APIProfileSnapshot.init(from:))
        } catch {
            await logger.log(
                "Failed to load API profiles: \(error.localizedDescription)",
                level: .error
            )
            return []
        }
    }

    func create(
        name: String,
        provider: LLMProvider,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int
    ) async throws -> APIProfileSnapshot {
        let profile = APIProfile(
            name: name,
            provider: provider,
            baseURL: baseURL,
            model: model,
            endpointMode: endpointMode,
            temperature: temperature,
            maxTokens: maxTokens
        )
        modelContext.insert(profile)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(profile)
            await logger.log(
                "Failed to save API profile \(name): \(error.localizedDescription)",
                level: .error
            )
            throw error
        }
        await logger.log("API profile saved: \(name)", level: .debug)
        return APIProfileSnapshot(from: profile)
    }

    func update(
        id: UUID,
        name: String,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int
    ) async throws {
        guard let profile = try fetchProfile(id: id) else {
            await logger.log(
                "API profile update skipped — id not found: \(id.uuidString)",
                level: .warning
            )
            return
        }
        profile.name = name
        profile.baseURL = baseURL
        profile.model = model
        profile.endpointMode = endpointMode
        profile.temperature = temperature
        profile.maxTokens = maxTokens
        profile.updatedAt = Date()
        try modelContext.save()
        await logger.log("API profile updated: \(name)", level: .debug)
    }

    func delete(id: UUID) async throws {
        guard let profile = try fetchProfile(id: id) else {
            await logger.log(
                "API profile delete skipped — id not found: \(id.uuidString)",
                level: .warning
            )
            return
        }
        let name = profile.name
        modelContext.delete(profile)
        try modelContext.save()
        await logger.log("API profile deleted: \(name)", level: .debug)
    }

    // MARK: - Private

    private func fetchProfile(id: UUID) throws -> APIProfile? {
        let request = FetchDescriptor<APIProfile>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(request).first
    }
}
