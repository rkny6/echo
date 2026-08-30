import Foundation
import SwiftUI
import SwiftData

// MARK: - Feature facades

/// The UI-facing application state.  The previous version made this type both
/// the state container and the orchestration layer for nearly every domain.
/// This version keeps the exact UI API for the existing Views while delegating
/// work to small feature facades.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var chatMessages: [ChatMessageSnapshot] = []
    @Published var character: CharacterProfileSnapshot = .default
    @Published var user: UserProfileSnapshot = .default
    @Published var appSettings: AppSettings = .default
    @Published var conversationState: ConversationState = .idle
    @Published var isCharacterOnline = true
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var debugLogs: [LogEntry] = []
    @Published var showDebugPanel = false
    @Published var isGeneratingReply = false
    @Published var isCharacterReading = false
    @Published var isSendingMessage = false
    @Published private(set) var hasMoreChatHistory = false
    @Published private(set) var isLoadingMoreChatHistory = false

    private let runtime: AppRuntime
    private var historyObservationTask: Task<Void, Never>?
    private var currentConversationId: UUID?
    private var lastTypingForwardDate = Date.distantPast
    private var pendingTypingForwardTask: Task<Void, Never>?

    private static let chatPageSize = 60
    private static let typingForwardThrottle: TimeInterval = 0.25
    static let activeAPIKeyName = "custom_api_key"

    init(
        conversationManager: ConversationManager,
        chatMessageStore: ChatMessageStore,
        eventDetectionService: EventDetecting,
        logger: LoggingProviding,
        settingsService: SettingsProviding,
        llmServiceFactory: LLMServiceFactory,
        notificationService: NotificationScheduling,
        healthDataService: HealthDataProviding,
        locationService: LocationProviding,
        keychainService: KeychainProviding = KeychainService(),
        diaryService: DiaryService,
        profileService: any ProfileProviding,
        apiProfileService: any APIProfileProviding,
        memoryManager: MemoryManaging,
        systemEventCoordinator: SystemEventCoordinator,
        proactiveEngagementCoordinator: ProactiveEngagementCoordinator
    ) {
        self.runtime = AppRuntime(
            conversation: ChatFeature(
                conversationManager: conversationManager,
                chatStore: chatMessageStore,
                logger: logger
            ),
            profiles: ProfileFeature(profileService: profileService, logger: logger),
            apiProfiles: APIProfileFeature(
                apiProfileService: apiProfileService,
                keychain: keychainService,
                settings: settingsService,
                logger: logger
            ),
            settings: SettingsFeature(
                settingsService: settingsService,
                llmFactory: llmServiceFactory,
                logger: logger
            ),
            diary: DiaryFeature(diaryService: diaryService),
            memory: MemoryFeature(memoryManager: memoryManager),
            diagnostics: DiagnosticsFeature(
                conversationManager: conversationManager,
                systemEvents: systemEventCoordinator,
                logger: logger,
                eventDetection: eventDetectionService
            ),
            proactive: ProactiveFeature(
                coordinator: proactiveEngagementCoordinator,
                settingsService: settingsService,
                logger: logger
            ),
            location: locationService,
            notificationService: notificationService,
            keychain: keychainService,
            logger: logger,
            chatStore: chatMessageStore
        )

        startObservingChatHistory()
        Task { await loadInitialState() }
    }

    // MARK: Lifecycle

    func handleAppDidBecomeActive() async {
        await runtime.conversation.reconcileAfterForeground()
        await runtime.conversation.recoverInterruptedUserReplies()
        await refreshChatHistory()
        await runProactiveCatchUp(source: "foreground")
    }

    func handleNotificationOpen(conversationId: UUID?, responseId: UUID?) async {
        if let conversationId { currentConversationId = conversationId }
        await runtime.conversation.reconcileAfterForeground()
        await runtime.conversation.recoverInterruptedUserReplies()
        await refreshChatHistory()
        if let responseId {
            await runtime.logger.log("Opened chat from notification responseId=\(responseId)", level: .debug)
        }
    }

    // MARK: Proactive

    func runProactiveCatchUp(source: String) async {
        let settings = appSettings
        await runtime.proactive.runCatchUp(
            source: source,
            enabled: settings.proactiveCaringEnabled,
            characterName: character.name,
            debugFastMode: settings.debugModeEnabled
        )
    }

    func handleScheduledOnline() async {
        await runtime.proactive.handleScheduledOnline(
            enabled: appSettings.proactiveCaringEnabled,
            characterName: character.name,
            debugFastMode: appSettings.debugModeEnabled
        )
    }

    func maybeCatchUpOnlineGreeting(source: String) async {
        await runtime.proactive.catchUpOnlineGreeting(
            source: source,
            enabled: appSettings.proactiveCaringEnabled,
            characterName: character.name,
            debugFastMode: appSettings.debugModeEnabled
        )
    }

    func maybeCatchUpEveningCheckIn(source: String) async {
        await runtime.proactive.catchUpEveningCheckIn(
            source: source,
            enabled: appSettings.proactiveCaringEnabled,
            characterName: character.name,
            debugFastMode: appSettings.debugModeEnabled
        )
    }

    // MARK: Diary / Memory

    func loadDiaryEntries() async -> [DiaryEntrySnapshot] {
        await runtime.diary.loadAll()
    }

    func generateDiaryForDebug() async {
        await runtime.diary.generateForDebug()
    }

    func regenerateDiary(for day: Date) async -> Bool {
        await runtime.diary.regenerate(for: day)
    }

    func deleteDiaryEntry(_ entry: DiaryEntrySnapshot) async {
        await runtime.diary.delete(id: entry.id)
    }

    func loadUserFacingMemory() async -> UserFacingMemorySnapshot {
        await runtime.memory.load()
    }

    func clearLongTermSummary() async {
        await runtime.memory.clearSummary()
    }

    func clearExtractedUserProfileMemory() async {
        await runtime.memory.clearProfile()
    }

    // MARK: Credentials

    func saveAPIKey(_ key: String, for provider: LLMProvider) async {
        do { try await runtime.keychain.store(key, for: Self.activeAPIKeyName) }
        catch { await runtime.logger.log("Failed to save API key: \(error.localizedDescription)", level: .error) }
    }

    func retrieveAPIKey(for provider: LLMProvider) async -> String? {
        do { return try await runtime.keychain.retrieve(Self.activeAPIKeyName) }
        catch { await runtime.logger.log("Failed to retrieve API key: \(error.localizedDescription)", level: .error); return nil }
    }

    func deleteAPIKey(for provider: LLMProvider) async {
        do { try await runtime.keychain.delete(Self.activeAPIKeyName) }
        catch { await runtime.logger.log("Failed to delete API key: \(error.localizedDescription)", level: .error) }
    }

    func saveAgnesAPIKey(_ key: String) async {
        do {
            try await runtime.keychain.store(key, for: "agnes_ai_api_key")
        } catch {
            UserDefaults.standard.set(key, forKey: "agnes_ai_api_key")
            await runtime.logger.log("Failed to save Agnes API key: \(error.localizedDescription)", level: .error)
        }
        UserDefaults.standard.set(key, forKey: "agnes_ai_api_key")
    }

    func retrieveAgnesAPIKey() async -> String? {
        do { return try await runtime.keychain.retrieve("agnes_ai_api_key") }
        catch { await runtime.logger.log("Failed to retrieve Agnes API key: \(error.localizedDescription)", level: .error); return nil }
    }

    func deleteAgnesAPIKey() async {
        do { try await runtime.keychain.delete("agnes_ai_api_key") }
        catch { await runtime.logger.log("Failed to delete Agnes API key: \(error.localizedDescription)", level: .error) }
        UserDefaults.standard.removeObject(forKey: "agnes_ai_api_key")
    }

    // MARK: API Profiles

    @discardableResult
    func createProfile(
        name: String,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int,
        apiKey: String?
    ) async -> APIProfileSnapshot? {
        await runtime.apiProfiles.create(
            name: name,
            baseURL: baseURL,
            model: model,
            endpointMode: endpointMode,
            temperature: temperature,
            maxTokens: maxTokens,
            apiKey: apiKey
        )
    }

    func loadAPIProfiles() async -> [APIProfileSnapshot] {
        await runtime.apiProfiles.loadAll()
    }

    func deleteProfile(_ profile: APIProfileSnapshot) async {
        await runtime.apiProfiles.delete(profile)
    }

    @discardableResult
    func applyProfile(_ profile: APIProfileSnapshot) async -> Bool {
        do {
            let currentSettings = appSettings.copy()
            var settings = currentSettings
            settings.selectedProvider = profile.provider
            settings.selectedModel = profile.model
            settings.temperature = profile.temperature
            settings.maxTokens = profile.maxTokens
            settings.customBaseURL = profile.baseURL
            settings.endpointMode = profile.endpointMode
            try await runtime.settings.update(settings)
            appSettings = try await runtime.settings.get()
            return await runtime.apiProfiles.applyKey(profile)
        } catch {
            await runtime.logger.log("Failed to apply API profile \(profile.name): \(error.localizedDescription)", level: .error)
            return false
        }
    }

    func updateProfile(
        _ profile: APIProfileSnapshot,
        name: String,
        baseURL: String?,
        model: String,
        endpointMode: LLMAPIEndpointMode,
        temperature: Double,
        maxTokens: Int,
        apiKey: String? = nil
    ) async {
        await runtime.apiProfiles.update(
            profile,
            name: name,
            baseURL: baseURL,
            model: model,
            endpointMode: endpointMode,
            temperature: temperature,
            maxTokens: maxTokens,
            apiKey: apiKey
        )
    }

    func retrieveProfileAPIKey(for profile: APIProfileSnapshot) async -> String? {
        try? await runtime.keychain.retrieve(profile.keychainKeyName)
    }

    // MARK: Chat

    func sendUserMessage(_ content: String) async {
        guard !isSendingMessage else { return }
        isSendingMessage = true
        defer { isSendingMessage = false }
        errorMessage = nil

        do {
            let id = await resolveConversationId()
            try await runtime.conversation.sendMessage(content, conversationId: id)
            conversationState = await runtime.conversation.state()
        } catch {
            await handleChatFailure("发送消息失败", error: error)
        }
    }

    func sendUserImageMessage(content: String, imageData: Data) async {
        guard !isSendingMessage else { return }
        isSendingMessage = true
        defer { isSendingMessage = false }
        errorMessage = nil

        let messageId = UUID()
        let conversationId = await resolveConversationId()
        chatMessages.append(ChatMessageSnapshot(
            id: messageId,
            role: .user,
            content: content,
            timestamp: Date(),
            conversationId: conversationId,
            metadata: ["imageRecognitionDescription": "正在识别图片内容"],
            isRead: true,
            imageData: imageData,
            imageMimeType: "image/jpeg",
            status: .recognizing
        ))

        do {
            try await runtime.conversation.sendImage(
                id: messageId,
                content: content,
                imageData: imageData,
                imageMimeType: "image/jpeg",
                conversationId: conversationId
            )
            conversationState = await runtime.conversation.state()
        } catch {
            if let index = chatMessages.firstIndex(where: { $0.id == messageId }) {
                chatMessages[index].status = .failed
                chatMessages[index].isFailed = true
                chatMessages[index].errorMessage = error.localizedDescription
            }
            await handleChatFailure("发送图片失败", error: error)
        }
    }

    func resendMessage(_ message: ChatMessageSnapshot) async {
        guard !isSendingMessage, message.role == .user else { return }
        guard message.isFailed == true || message.status == .failed else { return }

        isSendingMessage = true
        defer { isSendingMessage = false }
        errorMessage = nil

        if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
            chatMessages[index].isFailed = false
            chatMessages[index].errorMessage = nil
            chatMessages[index].status = message.hasImage ? .recognizing : .sending
        }
        if let id = message.conversationId { currentConversationId = id }

        do {
            let conversationId = await resolveConversationId()
            do {
                try await runtime.conversation.resend(id: message.id)
            } catch ConversationError.messageNotFound {
                if let imageData = message.imageData {
                    try await runtime.conversation.sendImage(
                        id: message.id,
                        content: message.content,
                        imageData: imageData,
                        imageMimeType: message.imageMimeType ?? "image/jpeg",
                        conversationId: conversationId
                    )
                } else {
                    try await runtime.conversation.sendMessage(message.content, conversationId: conversationId)
                }
            }
            conversationState = await runtime.conversation.state()
        } catch {
            if let index = chatMessages.firstIndex(where: { $0.id == message.id }) {
                chatMessages[index].isFailed = true
                chatMessages[index].status = .failed
                chatMessages[index].errorMessage = error.localizedDescription
            }
            await handleChatFailure("重发消息失败", error: error)
            await refreshChatHistory()
        }
    }

    func userInputDidChange(_ text: String) {
        pendingTypingForwardTask?.cancel()
        let now = Date()
        guard now.timeIntervalSince(lastTypingForwardDate) >= Self.typingForwardThrottle else {
            pendingTypingForwardTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.typingForwardThrottle * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.lastTypingForwardDate = Date()
                await self.runtime.conversation.recordTyping(text)
            }
            return
        }
        lastTypingForwardDate = now
        Task { await runtime.conversation.recordTyping(text) }
    }

    func startConversationForEvent(_ event: CompanionEvent) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await runtime.conversation.startConversation(event: event)
            currentConversationId = await runtime.conversation.currentConversationId()
            conversationState = await runtime.conversation.state()
            await runtime.logger.log(
                "Started conversation for event: \(event.type.rawValue)",
                level: .debug
            )
        } catch {
            await runtime.logger.log("Failed to start conversation: \(error.localizedDescription)", level: .error)
            errorMessage = "启动对话失败：\(error.localizedDescription)"
        }
    }

    // MARK: Profiles / settings

    func updateUserProfile(_ profile: UserProfileSnapshot) async {
        do {
            try await runtime.profiles.updateUser(profile)
            user = await runtime.profiles.loadUser()
        } catch {
            await runtime.logger.log("Failed to save user profile: \(error.localizedDescription)", level: .error)
        }
    }

    func updateCharacterProfile(_ profile: CharacterProfileSnapshot) async {
        do {
            try await runtime.profiles.updateCharacter(profile)
            character = await runtime.profiles.loadCharacter()
        } catch {
            await runtime.logger.log("Failed to save character profile: \(error.localizedDescription)", level: .error)
        }
    }

    func saveCharacter(_ profile: CharacterProfileSnapshot) {
        Task { await updateCharacterProfile(profile) }
    }

    func updateAppSettings(_ settings: AppSettings) async {
        do {
            try await runtime.settings.update(settings)
            appSettings = try await runtime.settings.get()
        } catch {
            await runtime.logger.log("Failed to update settings: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: History

    func refreshChatHistory() async {
        do {
            let page = try await runtime.chatStore.fetchRecent(limit: Self.chatPageSize)
            chatMessages = page
            hasMoreChatHistory = page.count == Self.chatPageSize
            currentConversationId = await runtime.conversation.currentConversationId() ?? currentConversationId
            conversationState = await runtime.conversation.state()
        } catch {
            await runtime.logger.log("Failed to refresh chat history: \(error.localizedDescription)", level: .error)
        }
    }

    func loadOlderChatHistory() async {
        guard !isLoadingMoreChatHistory, let oldest = chatMessages.first?.timestamp else { return }
        isLoadingMoreChatHistory = true
        defer { isLoadingMoreChatHistory = false }
        do {
            let older = try await runtime.chatStore.fetchBefore(timestamp: oldest, limit: Self.chatPageSize)
            chatMessages = older + chatMessages
            hasMoreChatHistory = older.count == Self.chatPageSize
        } catch {
            await runtime.logger.log("Failed to load older chat history: \(error.localizedDescription)", level: .error)
        }
    }

    func markMessageAsRead(_ messageId: UUID) {
        guard let index = chatMessages.firstIndex(where: { $0.id == messageId }) else { return }
        chatMessages[index].isRead = true
        Task {
            do { _ = try await runtime.chatStore.setRead(ids: [messageId], isRead: true) }
            catch { await runtime.logger.log("Failed to save message as read: \(error.localizedDescription)", level: .error) }
        }
    }

    func markAllAssistantMessagesAsRead() {
        let ids = Set(chatMessages.filter { $0.role == .assistant && !$0.isRead }.map(\.id))
        guard !ids.isEmpty else { return }
        for index in chatMessages.indices where chatMessages[index].role == .assistant {
            chatMessages[index].isRead = true
        }
        Task {
            do { _ = try await runtime.chatStore.setRead(ids: ids, isRead: true) }
            catch { await runtime.logger.log("Failed to mark all messages as read: \(error.localizedDescription)", level: .error) }
        }
    }

    func deleteMessages(_ messageIDs: Set<UUID>) async throws {
        guard !messageIDs.isEmpty else { return }
        let affectedFromUI = Set(chatMessages.filter { messageIDs.contains($0.id) }.compactMap(\.conversationId))
        let result = try await runtime.chatStore.delete(ids: messageIDs)
        chatMessages.removeAll { messageIDs.contains($0.id) }
        await runtime.memory.removeMessages(messageIDs)
        await runtime.conversation.afterMessagesDeleted(
            messageIDs: result.deletedIDs.isEmpty ? messageIDs : result.deletedIDs,
            conversationIds: result.affectedConversationIds.union(affectedFromUI)
        )
    }

    // MARK: Connections / diagnostics

    func testAPIConnection() async throws -> Bool { try await runtime.settings.testProvider(settings: appSettings) }
    func testProviderConnection(using settings: AppSettings) async throws -> Bool { try await runtime.settings.testProvider(settings: settings) }
    func testAgnesConnection() async throws -> Bool {
        let service = AgnesImageRecognitionService()
        try await service.testConnection()
        await runtime.logger.log("Agnes image recognition connection test succeeded", level: .info)
        return true
    }

    func manualTrigger() async { await detectAndProcessEvents() }
    func testImmediateHealthNotification() async { await runtime.diagnostics.evaluateSystemTriggers() }
    func testRescheduleHealthNotifications() { Task { await detectAndProcessEvents() } }

    func clearDebugLogs() async {
        do { try await runtime.logger.clearLogs(); debugLogs.removeAll() }
        catch { await runtime.logger.log("Failed to clear debug logs: \(error.localizedDescription)", level: .error) }
    }

    func detectAndProcessEvents() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        await runtime.diagnostics.evaluateSystemTriggers()
        await refreshDebugLogs()
    }

    func refreshDebugLogs() async { debugLogs = await runtime.logger.getLogs() }

    func refreshConversationDebugInfo() async -> ConversationDebugInfo? {
        do { return try await runtime.conversation.debugInfo() }
        catch { await runtime.logger.log("Failed to load conversation debug info: \(error.localizedDescription)", level: .error); return nil }
    }

    func refreshCharacterScheduleDebugInfo() async -> CharacterScheduleDebugInfo {
        await runtime.diagnostics.characterScheduleDebugInfo()
    }

    func regenerateCharacterScheduleForDebug() async -> CharacterScheduleDebugInfo {
        await runtime.diagnostics.regenerateSchedule()
    }

    func getAllPendingEvents() async -> [PendingEvent] { await runtime.diagnostics.pendingEvents() }
    func getAllPendingResponses() async -> [PendingResponseSnapshot] { await runtime.diagnostics.pendingResponses() }

    func forceProcessPendingEvents() async {
        do {
            try await runtime.conversation.forceProcessPendingEvents()
            await refreshChatHistory()
            await runtime.logger.log("Force processed pending events", level: .info)
        } catch {
            await runtime.logger.log("Failed to force process pending events: \(error.localizedDescription)", level: .error)
            errorMessage = "处理待处理事件失败：\(error.localizedDescription)"
        }
    }

    func forceDeliverPendingResponses() async {
        do {
            try await runtime.conversation.forceDeliverPendingResponses()
            await refreshChatHistory()
            await runtime.logger.log("Force delivered pending responses", level: .info)
        } catch {
            await runtime.logger.log("Failed to force deliver pending responses: \(error.localizedDescription)", level: .error)
            errorMessage = "发送待发送回复失败：\(error.localizedDescription)"
        }
    }

    func clearAllPendingEvents() async {
        do {
            try await runtime.conversation.clearAllPendingEvents()
            await runtime.logger.log("Cleared all pending events", level: .info)
        } catch {
            await runtime.logger.log("Failed to clear pending events: \(error.localizedDescription)", level: .error)
        }
    }

    func clearAllPendingResponses() async {
        do {
            try await runtime.conversation.clearAllPendingResponses()
            await runtime.logger.log("Cleared all pending responses", level: .info)
        } catch {
            await runtime.logger.log("Failed to clear pending responses: \(error.localizedDescription)", level: .error)
        }
    }
    func handleError(_ message: String) async { errorMessage = message; await runtime.logger.log(message, level: .error) }

    // MARK: Internal

    private func loadInitialState() async {
        do {
            appSettings = try await runtime.settings.get()
            user = await runtime.profiles.loadUser()
            character = await runtime.profiles.loadCharacter()
            await refreshChatHistory()
            _ = try? await runtime.notificationService.requestAuthorization()
            await runtime.location.requestLocationUpdates()

            let defaults = UserDefaults.standard
            for key in [
                "longingValue", "lastUserMessageTime", "lastLongingUpdateTime",
                "lastProactiveMessageTime", "pendingProactiveMessages"
            ] { defaults.removeObject(forKey: key) }

            conversationState = await runtime.conversation.state()
            currentConversationId = await runtime.conversation.currentConversationId()
            await runtime.conversation.recoverInterruptedUserReplies()
            await refreshChatHistory()
            await runtime.logger.log("App initialized successfully", level: .info)
        } catch {
            await runtime.logger.log("Failed to initialize app: \(error.localizedDescription)", level: .error)
        }
    }

    private func resolveConversationId() async -> UUID {
        if let currentConversationId { return currentConversationId }
        if let active = await runtime.conversation.currentConversationId() {
            currentConversationId = active
            return active
        }
        let resolved = await runtime.chatStore.resolveConversationId()
        currentConversationId = resolved
        return resolved
    }

    private func startObservingChatHistory() {
        historyObservationTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.runtime.chatStore.changes
            for await change in stream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self.applyHistoryChange(change) }
            }
        }
    }

    private func applyHistoryChange(_ change: ChatHistoryChange) {
        switch change {
        case .upserted(let snapshots):
            guard !snapshots.isEmpty else { return }
            var next = chatMessages
            for snapshot in snapshots {
                if let index = next.firstIndex(where: { $0.id == snapshot.id }) {
                    next[index] = snapshot
                } else if next.isEmpty || snapshot.timestamp >= (next.first?.timestamp ?? .distantPast) {
                    next.append(snapshot)
                }
            }
            next.sort { $0.timestamp < $1.timestamp }
            chatMessages = next
        case .deleted(let ids):
            chatMessages.removeAll { ids.contains($0.id) }
        }
    }

    private func handleChatFailure(_ prefix: String, error: Error) async {
        errorMessage = "\(prefix)：\(error.localizedDescription)"
        await runtime.logger.log("\(prefix): \(error.localizedDescription)", level: .error)
    }
}
