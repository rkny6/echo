import Foundation

/// Seam so actors (ConversationManager, MemoryManager, DailyContextManager)
/// can inject a provider factory without coupling to the concrete
/// `LLMServiceFactory` — which always builds a real HTTP adapter. Tests
/// inject a scripted fake that returns `MockLLMProvider`.
protocol LLMServiceFactoryProviding: Sendable {
    /// Create a provider based on the provided settings.
    func createProvider(settings: AppSettings) async throws -> LLMProviderService
}

/// Factory for creating LLM provider instances
final class LLMServiceFactory: LLMServiceFactoryProviding {
    private let keychainService: KeychainProviding
    private let settingsService: SettingsProviding
    private let logger: LoggingProviding?
    
    init(
        keychainService: KeychainProviding,
        settingsService: SettingsProviding,
        logger: LoggingProviding? = nil
    ) {
        self.keychainService = keychainService
        self.settingsService = settingsService
        self.logger = logger
    }
    
    /// Create a provider based on the provided settings.
    /// All historical provider identities use the same OpenAI-compatible adapter;
    /// base URL / model / key come from settings + Keychain.
    func createProvider(settings: AppSettings) async throws -> LLMProviderService {
        try await createCustomOpenAIProvider(settings: settings)
    }
    
    // MARK: - Private Helpers

    private func createCustomOpenAIProvider(settings: AppSettings) async throws -> LLMProviderService {
        let apiKey = try await keychainService.retrieve("custom_api_key")
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw LLMServiceFactoryError.missingAPIKey("Custom API Key")
        }

        let baseURL = (settings.customBaseURL ?? "https://api.openai.com/v1").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointMode = settings.endpointMode

        await logger?.log(
            "Creating LLM provider adapter: model=\(settings.selectedModel) mode=\(endpointMode.rawValue) baseURL=\(baseURL) storedProvider=\(settings.selectedProvider.rawValue)",
            level: .debug
        )

        return CustomOpenAICompatibleAdapter(
            apiKey: apiKey,
            baseURL: baseURL,
            modelName: settings.selectedModel,
            endpointMode: endpointMode,
            logger: logger
        )
    }
}

enum LLMServiceFactoryError: LocalizedError {
    case missingAPIKey(String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) 未配置。请在设置中添加 API Key。"
        }
    }
}
