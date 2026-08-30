import Foundation

/// Sendable read model for saved API endpoint profiles.
/// Durable `APIProfile` rows are owned by `APIProfileService` (private
/// ModelContext). UI holds snapshots so it never keeps live `@Model`s on the
/// shared UI context or races other writers.
struct APIProfileSnapshot: Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var provider: LLMProvider
    var baseURL: String?
    var model: String
    var endpointMode: LLMAPIEndpointMode
    var temperature: Double
    var maxTokens: Int
    var createdAt: Date
    var updatedAt: Date

    /// Stable Keychain key for this profile's own API key (mirrors
    /// `APIProfile.keychainKeyName`).
    var keychainKeyName: String {
        "api_key_profile_\(id.uuidString)"
    }

    init(
        id: UUID = UUID(),
        name: String,
        provider: LLMProvider = .customOpenAICompatible,
        baseURL: String? = nil,
        model: String,
        endpointMode: LLMAPIEndpointMode = .chatCompletions,
        temperature: Double = 0.7,
        maxTokens: Int = 2000,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.endpointMode = endpointMode
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from profile: APIProfile) {
        self.id = profile.id
        self.name = profile.name
        self.provider = profile.provider
        self.baseURL = profile.baseURL
        self.model = profile.model
        self.endpointMode = profile.endpointMode
        self.temperature = profile.temperature
        self.maxTokens = profile.maxTokens
        self.createdAt = profile.createdAt
        self.updatedAt = profile.updatedAt
    }
}
