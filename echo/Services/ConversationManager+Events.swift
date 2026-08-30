import Foundation

/// Event ingress, character status observation, and event-triggered reply generation.
extension ConversationManager {

    func setOnCharacterStatusChange(_ handler: @escaping @Sendable (CharacterOnlineStatus) async -> Void) {
        onCharacterStatusChange = handler
    }

    func setOnScheduledOnline(_ handler: @escaping @Sendable () async -> Void) {
        onScheduledOnline = handler
    }

    /// Whether today's schedule has already reached a planned online window (catch-up).
    func hasReachedPlannedOnlineWindow(at date: Date = Date()) async -> Bool {
        await characterStatusManager.hasReachedPlannedOnlineWindow(at: date)
    }
    
    func initializeDailyContextAndStatus(character: CharacterProfileSnapshot, user: UserProfileSnapshot) async throws {
        self.currentDailyContext = try await dailyContextManager.getOrCreateDailyContextString(
            character: character,
            user: user
        )

        // Register before initialize so the initial status is observed (including offline gate).
        await characterStatusManager.setOnStatusChange { [weak self] status, reason in
            guard let self = self else { return }
            await self.handleStatusChange(status, reason: reason)
        }
        try await characterStatusManager.initializeStatus(for: Date())
    }
    
    private func handleStatusChange(
        _ status: CharacterOnlineStatus,
        reason: OnlineTransitionReason?
    ) async {
        await self.delayedResponseManager.setCharacterOnline(status == .online)

        let becameOnline = status == .online && previousStatus != .online
        let isRealOfflineToOnline = becameOnline && previousStatus == .offline

        // Flush parked replies when becoming online (including cold-start online).
        // Only attach "刚看到消息" when there was a real offline → online transition.
        if becameOnline {
            if isRealOfflineToOnline {
                self.statusChangeContext = "他刚看到消息"
            }
            await self.delayedResponseManager.reschedulePendingResponsesForCharacterOnline()

            // Proactive online greeting only for planned windows after a true
            // offline period — not for temporary early-online reply windows,
            // and not for cold-start already-online.
            if isRealOfflineToOnline, reason == .scheduledWindow {
                await self.onScheduledOnline?()
            }
        }

        self.previousStatus = status
        await self.onCharacterStatusChange?(status)
    }
    
    func resetStatusChangeContext() async {
        self.statusChangeContext = nil
    }

    func handleIncomingEvent(_ event: CompanionEvent) async throws {
        switch conversationState {
        case .idle:
            try await startConversation(event: event)
        case .conversing, .waitingForResponse, .reactive, .followUp:
            try await pendingEventQueue.enqueue(event)
            await logger.log(
                "Queued event \(event.type.rawValue) while conversation state is \(conversationState.rawValue)",
                level: .debug
            )
        }
    }

    /// Runs one LLM reply turn through `ToolCallLoop` so the model can request
    /// tool calls. Tool definitions + executors only come from the registry when
    /// `enableMCP` is on — with the toggle off (default), `tools` is empty and
    /// the loop degenerates to a single plain-text call, exactly like the old
    /// `sendMessageWithRetry` path.
    func generateReply(
        provider: LLMProviderService,
        systemPrompt: String,
        userMessage: String,
        settings: AppSettings
    ) async throws -> String {
        let enableTools = settings.enableMCP
        let tools = enableTools ? toolRegistry.definitions : []
        let executor: ToolCallLoop.ToolExecutor = { [toolRegistry] call in
            guard let executor = toolRegistry.executor(for: call.name) else {
                throw ToolCallLoopError.noToolRegistered(name: call.name)
            }
            return try await executor(call)
        }
        return try await ToolCallLoop.run(
            provider: provider,
            messages: [
                LLMMessage(role: .system, content: systemPrompt),
                LLMMessage(role: .user, content: userMessage)
            ],
            tools: tools,
            executeTool: executor,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens,
            logger: logger
        )
    }

    func startConversation(event: CompanionEvent) async throws {
        await transitionTo(.reactive)
        let conversationId: UUID
        if let currentConversationId {
            conversationId = currentConversationId
        } else {
            conversationId = await chatMessageStore.resolveConversationId()
        }
        currentConversationId = conversationId

        let character = await profileService.loadCharacter()
        let user = await profileService.loadUser()

        let context = await promptContextAssembler.assembleContext(
            userName: user.name,
            characterName: character.name,
            userBirthday: user.birthday
        )
        currentDailyContext = context.dailyContext
        let currentStatus = context.characterStatus
        let memoryContext = context.memoryContext

        let systemPrompt = try await promptBuilder.buildSystemPrompt(
            character: character,
            user: user,
            longTermSummary: memoryContext.globalSummary,
            userProfile: memoryContext.userProfile,
            dailyContext: currentDailyContext,
            characterStatus: currentStatus,
            statusContext: statusChangeContext,
            localTimeString: context.localTimeString,
            dateAmbience: context.dateAmbience,
            weatherAmbience: context.weatherAmbience,
            sleepAmbience: context.sleepAmbience,
            diaryMemory: nil,
            conversationGap: context.conversationGap
        )

        let recentMessages: [ChatMessageSnapshot]
        do {
            recentMessages = try await chatMessageStore.fetchRecent(limit: 6)
        } catch {
            await logger.log(
                "Failed to fetch recent messages for event prompt: \(error.localizedDescription)",
                level: .error
            )
            recentMessages = []
        }
        let eventPrompt = try await promptBuilder.buildEventPrompt(
            event: event,
            character: character,
            user: user,
            recentMessages: recentMessages,
            longTermSummary: memoryContext.globalSummary
        )

        let settings = try await settingsService.getSettings()
        let provider = try await llmServiceFactory.createProvider(settings: settings)

        await onReplyGenerating?()

        // Same reasoning as handleAccumulatedBatch: this call can happen
        // from a background wake (e.g. an outing/location event), and
        // without this it's just as exposed to getting killed mid-request
        // if the execution window runs out.
        let backgroundTask = await BackgroundTaskAssertion()
        await backgroundTask.begin(name: "eventTriggeredReply")

        do {
            let response = try await generateReply(
                provider: provider,
                systemPrompt: systemPrompt,
                userMessage: eventPrompt,
                settings: settings
            )

            try await scheduleGeneratedResponse(
                content: response,
                conversationId: conversationId,
                eventType: event.type,
                characterName: character.name,
                userName: user.name,
                typingDelay: 0,
                elapsed: 0,
                backgroundTask: backgroundTask,
                isEventResponse: true
            )

            await logger.log(
                "Generated event response for \(event.type.rawValue); delivery scheduled",
                level: .info
            )
            await onEventResponseScheduled?()
            resetInactivityTimer()
        } catch {
            await transitionTo(.idle)
            await onError?("事件回复生成失败：\(error.localizedDescription)")
            await onEventResponseScheduled?()
            await logger.log("LLM call failed for event: \(String(describing: error))", level: .error)
            await backgroundTask.end()
            throw error
        }
    }
}
