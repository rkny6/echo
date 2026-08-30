import Foundation
@MainActor
final class AppRuntime {
    let conversation: ChatFeature
    let profiles: ProfileFeature
    let apiProfiles: APIProfileFeature
    let settings: SettingsFeature
    let diary: DiaryFeature
    let memory: MemoryFeature
    let diagnostics: DiagnosticsFeature
    let proactive: ProactiveFeature
    let location: LocationProviding
    let notificationService: NotificationScheduling
    let keychain: KeychainProviding
    let logger: LoggingProviding
    let chatStore: ChatMessageStore

    init(
        conversation: ChatFeature,
        profiles: ProfileFeature,
        apiProfiles: APIProfileFeature,
        settings: SettingsFeature,
        diary: DiaryFeature,
        memory: MemoryFeature,
        diagnostics: DiagnosticsFeature,
        proactive: ProactiveFeature,
        location: LocationProviding,
        notificationService: NotificationScheduling,
        keychain: KeychainProviding,
        logger: LoggingProviding,
        chatStore: ChatMessageStore
    ) {
        self.conversation = conversation
        self.profiles = profiles
        self.apiProfiles = apiProfiles
        self.settings = settings
        self.diary = diary
        self.memory = memory
        self.diagnostics = diagnostics
        self.proactive = proactive
        self.location = location
        self.notificationService = notificationService
        self.keychain = keychain
        self.logger = logger
        self.chatStore = chatStore
    }
}
