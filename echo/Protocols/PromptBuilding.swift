import Foundation

/// Protocol for building prompts
protocol PromptBuilding: Sendable {
    /// Build a system prompt
    func buildSystemPrompt(
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        longTermSummary: String?,
        userProfile: [String: String]?,
        dailyContext: String?,
        characterStatus: CharacterOnlineStatus?,
        statusContext: String?,
        localTimeString: String?,
        dateAmbience: String?,
        weatherAmbience: String?,
        sleepAmbience: String?,
        diaryMemory: String?,
        conversationGap: String?
    ) async throws -> String
    
    /// Build a user message prompt with event context
    func buildEventPrompt(
        event: CompanionEvent,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        recentMessages: [ChatMessageSnapshot],
        longTermSummary: String?
    ) async throws -> String
    
    /// Build a conversation prompt
    func buildConversationPrompt(
        userMessage: String,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        recentMessages: [ChatMessageSnapshot],
        longTermSummary: String?
    ) -> String
}

extension PromptBuilding {
    /// Convenience overload for call sites that don't (yet) have weather,
    /// sleep, or diary-memory ambience to pass in.
    func buildSystemPrompt(
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        longTermSummary: String? = nil,
        userProfile: [String: String]? = nil,
        dailyContext: String? = nil,
        characterStatus: CharacterOnlineStatus? = nil,
        statusContext: String? = nil,
        localTimeString: String? = nil,
        dateAmbience: String? = nil
    ) async throws -> String {
        try await buildSystemPrompt(
            character: character,
            user: user,
            longTermSummary: longTermSummary,
            userProfile: userProfile,
            dailyContext: dailyContext,
            characterStatus: characterStatus,
            statusContext: statusContext,
            localTimeString: localTimeString,
            dateAmbience: dateAmbience,
            weatherAmbience: nil,
            sleepAmbience: nil,
            diaryMemory: nil,
            conversationGap: nil
        )
    }
}
