import Foundation
import SwiftData

/// Generates a short proactive greeting when the character comes online
/// after a long silence. Replaces the old longing-value system.
actor OnlineGreetingService {
    private let llmServiceFactory: LLMServiceFactory
    private let promptBuilder: PromptBuilding
    private let settingsService: SettingsProviding
    private let chatMessageStore: ChatMessageStore
    private let logger: LoggingProviding
    private let timeZoneAwarenessProvider: TimeZoneAwarenessProvider
    private let dateAmbienceProvider: DateAmbienceProvider
    private let profileService: any ProfileProviding

    init(
        llmServiceFactory: LLMServiceFactory,
        promptBuilder: PromptBuilding,
        settingsService: SettingsProviding,
        chatMessageStore: ChatMessageStore,
        logger: LoggingProviding,
        timeZoneAwarenessProvider: TimeZoneAwarenessProvider,
        dateAmbienceProvider: DateAmbienceProvider? = nil,
        profileService: any ProfileProviding
    ) {
        self.llmServiceFactory = llmServiceFactory
        self.promptBuilder = promptBuilder
        self.settingsService = settingsService
        self.chatMessageStore = chatMessageStore
        self.logger = logger
        self.timeZoneAwarenessProvider = timeZoneAwarenessProvider
        self.dateAmbienceProvider = dateAmbienceProvider ?? DateAmbienceProvider(logger: logger)
        self.profileService = profileService
    }

    /// - Parameter silence: Sleep-aware contact metrics (not raw wall-clock alone).
    /// - Returns: Generated text, or `nil` if generation failed (skip sending).
    func generateMessage(
        silence: ContactSilenceMetrics
    ) async -> String? {
        await generateSilenceCareMessage(
            silence: silence,
            eventType: .onlineGreeting,
            sourceTag: "online_greeting",
            characterStatus: .online,
            statusContext: "他刚上线"
        )
    }

    /// Evening long-silence light care (21:00–23:00). Not schedule-driven "just came online".
    func generateEveningCheckInMessage(
        silence: ContactSilenceMetrics
    ) async -> String? {
        await generateSilenceCareMessage(
            silence: silence,
            eventType: .eveningCheckIn,
            sourceTag: "evening_check_in",
            characterStatus: .online,
            statusContext: "晚上，他在线"
        )
    }

    // MARK: - Private

    private func generateSilenceCareMessage(
        silence: ContactSilenceMetrics,
        eventType: CompanionEventType,
        sourceTag: String,
        characterStatus: CharacterOnlineStatus?,
        statusContext: String?
    ) async -> String? {
        let character = await profileService.loadCharacter()
        let user = await profileService.loadUser()
        var metadata = silence.eventMetadata
        metadata["source"] = sourceTag
        let event = CompanionEvent(
            type: eventType,
            priority: eventType.defaultPriority,
            metadata: metadata
        )

        do {
            let content = try await callLLM(
                event: event,
                character: character,
                user: user,
                characterStatus: characterStatus,
                statusContext: statusContext,
                timeout: HealthProactiveThresholds.llmTimeoutSeconds
            )
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw OnlineGreetingError.emptyResponse
            }
            await logger.log(
                "\(eventType.rawValue) LLM generated message (wall \(String(format: "%.1f", silence.wallClockHours))h awake \(String(format: "%.1f", silence.awakeHours))h daysApart=\(silence.calendarDaysApart) tone=\(silence.careTone.rawValue))",
                level: .info
            )
            return trimmed
        } catch {
            await logger.log(
                "\(eventType.rawValue) LLM failed: \(error.localizedDescription); skipping",
                level: .warning
            )
            return nil
        }
    }

    private func callLLM(
        event: CompanionEvent,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        characterStatus: CharacterOnlineStatus?,
        statusContext: String?,
        timeout: TimeInterval
    ) async throws -> String {
        let recentMessages = await fetchRecentMessages(limit: 6)
        let localTimeString = timeZoneAwarenessProvider.getLocalTimeString()
        let dateAmbience = dateAmbienceProvider.ambientPromptSnippet(userBirthday: user.birthday)

        let systemPrompt = try await promptBuilder.buildSystemPrompt(
            character: character,
            user: user,
            longTermSummary: nil,
            userProfile: nil,
            dailyContext: nil,
            characterStatus: characterStatus,
            statusContext: statusContext,
            localTimeString: localTimeString,
            dateAmbience: dateAmbience,
            weatherAmbience: nil,
            sleepAmbience: nil,
            diaryMemory: nil,
            conversationGap: nil
        )
        let eventPrompt = try await promptBuilder.buildEventPrompt(
            event: event,
            character: character,
            user: user,
            recentMessages: recentMessages,
            longTermSummary: nil
        )

        let settings = try await settingsService.getSettings()
        let provider = try await llmServiceFactory.createProvider(settings: settings)
        let capturedLogger = logger

        return try await withTimeout(seconds: timeout) {
            try await provider.sendMessageWithRetry(
                systemPrompt: systemPrompt,
                userMessage: eventPrompt,
                temperature: settings.temperature,
                maxTokens: min(settings.maxTokens, HealthProactiveThresholds.llmMaxTokens),
                logger: capturedLogger
            )
        }
    }

    private func fetchRecentMessages(limit: Int) async -> [ChatMessageSnapshot] {
        do {
            return try await chatMessageStore.fetchRecent(limit: limit)
        } catch {
            await logger.log(
                "Failed to fetch recent messages for silence care: \(error.localizedDescription)",
                level: .error
            )
            return []
        }
    }



    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw OnlineGreetingError.timeout
            }
            guard let result = try await group.next() else {
                throw OnlineGreetingError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

enum OnlineGreetingError: Error, LocalizedError {
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "Online greeting LLM request timed out"
        case .emptyResponse: return "Online greeting LLM returned empty content"
        }
    }
}
