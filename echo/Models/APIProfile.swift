import Foundation
import SwiftData

/// API configuration profile for managing multiple endpoints and keys
@Model
final class APIProfile: @unchecked Sendable, Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var provider: LLMProvider
    var baseURL: String?
    var model: String
    private var endpointModeStorage: String?
    var endpointMode: LLMAPIEndpointMode {
        get {
            LLMAPIEndpointMode(rawValue: endpointModeStorage ?? "chat_completions") ?? .chatCompletions
        }
        set {
            endpointModeStorage = newValue.rawValue
        }
    }
    var temperature: Double
    var maxTokens: Int
    var createdAt: Date
    var updatedAt: Date

    /// Stable Keychain key for this profile's own API key. Each profile
    /// stores its own key rather than sharing a single global slot — the
    /// whole point of having multiple profiles is to switch between
    /// different endpoints (often the same `.customOpenAICompatible`
    /// provider with different base URLs), which almost always means
    /// different keys too.
    var keychainKeyName: String {
        "api_key_profile_\(id.uuidString)"
    }
    
    init(
        name: String,
        provider: LLMProvider,
        baseURL: String? = nil,
        model: String,
        endpointMode: LLMAPIEndpointMode = .chatCompletions,
        temperature: Double = 0.7,
        maxTokens: Int = 2000
    ) {
        self.id = UUID()
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.endpointModeStorage = endpointMode.rawValue
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
