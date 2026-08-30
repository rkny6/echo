import Foundation
import SwiftData

/// App settings and configuration
@Model
final class AppSettings: @unchecked Sendable {
    var selectedProvider: LLMProvider
    var selectedModel: String
    var temperature: Double
    var maxTokens: Int
    var customBaseURL: String?
    private var endpointModeStorage: String?
    var endpointMode: LLMAPIEndpointMode {
        get {
            LLMAPIEndpointMode(rawValue: endpointModeStorage ?? "chat_completions") ?? .chatCompletions
        }
        set {
            endpointModeStorage = newValue.rawValue
        }
    }
    var systemPromptOverride: String?
    var debugModeEnabled: Bool

    private var useAgnesCloudImageRecognitionStorage: Bool?
    private var _allowImageSending: Bool?

    var useAgnesCloudImageRecognition: Bool {
        get { useAgnesCloudImageRecognitionStorage ?? false }
        set { useAgnesCloudImageRecognitionStorage = newValue }
    }

    var allowImageSending: Bool {
        get { _allowImageSending ?? false }
        set { _allowImageSending = newValue }
    }

    private var _proactiveCaringEnabled: Bool?
    var proactiveCaringEnabled: Bool {
        get { _proactiveCaringEnabled ?? true }
        set { _proactiveCaringEnabled = newValue }
    }
    /// When on, "should the character reach out right now" is decided by a
    /// single structured LLM judgment call (`ProactiveIntentDecider`) instead
    /// of the fixed silence-hour / time-of-day thresholds. Hard safety limits
    /// (no interrupting an active chat, cooldowns, once-a-day caps) are
    /// unaffected either way — this only changes how the *soft* timing
    /// decision within those limits is made. Defaults to off; opt-in while
    /// it's new, and to keep behavior unchanged for anyone not on a
    /// configured LLM provider.
    private var _useLLMProactiveJudgment: Bool?
    var useLLMProactiveJudgment: Bool {
        get { _useLLMProactiveJudgment ?? false }
        set { _useLLMProactiveJudgment = newValue }
    }
    /// Master switch for MCP support. When off, no MCP server is used at all
    /// (tools are not registered and no MCP handshake happens). Defaults to
    /// off — MCP is opt-in.
    private var _enableMCP: Bool?
    var enableMCP: Bool {
        get { _enableMCP ?? false }
        set { _enableMCP = newValue }
    }
    /// Remote MCP server endpoint (Streamable HTTP/SSE). Stored now so the
    /// Settings entry survives and is ready for wiring once the swift-mcp SDK
    /// is integrated.
    var mcpServerURL: String?
    private var _showUserAvatar: Bool?
    var showUserAvatar: Bool {
        get { _showUserAvatar ?? true }
        set { _showUserAvatar = newValue }
    }
    private var _showCharacterAvatar: Bool?
    var showCharacterAvatar: Bool {
        get { _showCharacterAvatar ?? true }
        set { _showCharacterAvatar = newValue }
    }
    
    init(
        selectedProvider: LLMProvider = .customOpenAICompatible,
        selectedModel: String = "gpt-4-turbo",
        temperature: Double = 0.7,
        maxTokens: Int = 2000,
        customBaseURL: String? = "https://api.openai.com/v1",
        endpointMode: LLMAPIEndpointMode = .chatCompletions,
        systemPromptOverride: String? = nil,
        debugModeEnabled: Bool = false,
        useAgnesCloudImageRecognition: Bool = false,
        allowImageSending: Bool = false,
        proactiveCaringEnabled: Bool = true,
        useLLMProactiveJudgment: Bool = false,
        enableMCP: Bool = false,
        showUserAvatar: Bool = true,
        showCharacterAvatar: Bool = true
    ) {
        self.selectedProvider = selectedProvider
        self.selectedModel = selectedModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.customBaseURL = customBaseURL
        self.endpointModeStorage = endpointMode.rawValue
        self.systemPromptOverride = systemPromptOverride
        self.debugModeEnabled = debugModeEnabled
        self.useAgnesCloudImageRecognitionStorage = useAgnesCloudImageRecognition
        self._allowImageSending = allowImageSending
        self._proactiveCaringEnabled = proactiveCaringEnabled
        self._useLLMProactiveJudgment = useLLMProactiveJudgment
        self._enableMCP = enableMCP
        self._showUserAvatar = showUserAvatar
        self._showCharacterAvatar = showCharacterAvatar
    }
    
    /// Detached value copy — safe to hand across isolation domains.
    ///
    /// The live row is owned by `SettingsService`'s private `ModelContext`.
    /// Mutating it from the MainActor (or any other isolation domain) while
    /// the service concurrently saves is undefined SwiftData behavior and can
    /// deadlock the store lock. UI code should copy the live values into this
    /// detached instance, mutate the copy, and hand the copy back — the
    /// service then copies fields onto its own live row and saves.
    func copy() -> AppSettings {
        let copy = AppSettings()
        copy.selectedProvider = selectedProvider
        copy.selectedModel = selectedModel
        copy.temperature = temperature
        copy.maxTokens = maxTokens
        copy.customBaseURL = customBaseURL
        copy.endpointMode = endpointMode
        copy.systemPromptOverride = systemPromptOverride
        copy.debugModeEnabled = debugModeEnabled
        copy.useAgnesCloudImageRecognition = useAgnesCloudImageRecognition
        copy.allowImageSending = allowImageSending
        copy.proactiveCaringEnabled = proactiveCaringEnabled
        copy.useLLMProactiveJudgment = useLLMProactiveJudgment
        copy.enableMCP = enableMCP
        copy.mcpServerURL = mcpServerURL
        copy.showUserAvatar = showUserAvatar
        copy.showCharacterAvatar = showCharacterAvatar
        return copy
    }

    static let `default` = AppSettings()
}
