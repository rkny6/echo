import Foundation

/// LLM provider identity stored on settings/API profiles.
///
/// Runtime support is OpenAI-compatible endpoints only
/// (`CustomOpenAICompatibleAdapter` via `LLMServiceFactory`).
/// Extra cases remain so older SwiftData / JSON values still decode.
enum LLMProvider: String, Codable, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case google = "google"
    case modelScope = "modelscope"
    case deepSeek = "deepseek"
    case xAI = "xai"
    case customOpenAICompatible = "custom_openai"

    /// Providers offered in UI / new configuration.
    static var supportedProviders: [LLMProvider] {
        [.customOpenAICompatible]
    }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .google:
            return "Google Gemini"
        case .modelScope:
            return "ModelScope"
        case .deepSeek:
            return "DeepSeek"
        case .xAI:
            return "xAI (Grok)"
        case .customOpenAICompatible:
            return "自定义 OpenAI 兼容 API"
        }
    }

    var commonModels: [String] {
        switch self {
        case .openAI:
            return [
                "gpt-4-turbo",
                "gpt-4o-mini",
                "gpt-4o",
                "gpt-3.5-turbo"
            ]
        case .anthropic:
            return [
                "claude-3-sonnet-20240229",
                "claude-3.5-mini",
                "claude-instant"
            ]
        case .modelScope:
            return [
                "openai/gpt-4-turbo",
                "openai/gpt-4o",
                "openai/gpt-3.5-turbo",
                "anthropic/claude-3-sonnet",
                "anthropic/claude-3.5-sonnet",
                "deepseek-ai/DeepSeek-V3.2",
                "meta-llama/llama-2-70b-chat"
            ]
        case .customOpenAICompatible:
            return [
                "gpt-4-turbo",
                "gpt-4o-mini",
                "gpt-3.5-turbo"
            ]
        case .google, .deepSeek, .xAI:
            return []
        }
    }
}
