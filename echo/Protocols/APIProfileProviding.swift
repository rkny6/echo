import Foundation

/// Single owner surface for durable `APIProfile` R/W.
/// Cross-actor consumers must use snapshots — never live `@Model`s.
/// Keychain secrets stay outside this protocol (AppViewModel / KeychainProviding).
protocol APIProfileProviding: Sendable {
    func loadAll() async -> [APIProfileSnapshot]
    func create(
        name: String,
        provider: LLMProvider,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int
    ) async throws -> APIProfileSnapshot
    func update(
        id: UUID,
        name: String,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int
    ) async throws
    func delete(id: UUID) async throws
}
