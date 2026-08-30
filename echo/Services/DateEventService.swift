import Foundation
import SwiftData

/// Generates LLM companion messages for proactive date-based events (birthday, holiday, weekend).
actor DateEventService {
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

    /// Generate a companion message for a date event.
    /// - Returns: The generated content, or `nil` if the LLM call failed —
    ///   callers should skip sending anything in that case rather than
    ///   falling back to a canned template.
    func generateMessage(
        for event: CompanionEvent
    ) async -> String? {
        let character = await profileService.loadCharacter()
        let user = await profileService.loadUser()

        do {
            let content = try await callLLM(
                event: event,
                character: character,
                user: user,
                timeout: HealthProactiveThresholds.llmTimeoutSeconds
            )
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DateEventError.emptyResponse
            }
            await logger.log(
                "Date LLM generated message for \(event.type.rawValue)",
                level: .info
            )
            return trimmed
        } catch {
            await logger.log(
                "Date LLM failed for \(event.type.rawValue): \(error.localizedDescription); skipping (no template fallback)",
                level: .warning
            )
            return nil
        }
    }

    private func callLLM(
        event: CompanionEvent,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
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
            characterStatus: nil,
            statusContext: nil,
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
                "Failed to fetch recent messages for date event: \(error.localizedDescription)",
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
                throw DateEventError.timeout
            }
            guard let result = try await group.next() else {
                throw DateEventError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

enum DateEventError: Error, LocalizedError {
    case timeout
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .timeout: return "Date event LLM request timed out"
        case .emptyResponse: return "Date event LLM returned empty content"
        }
    }
}