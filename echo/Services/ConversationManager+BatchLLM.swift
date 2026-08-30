import Foundation

/// Accumulated user-batch → single LLM turn, with failure marking.
extension ConversationManager {

    func handleAccumulatedBatch(_ batch: AccumulatedMessageBatch) async throws {
        guard !batch.messages.isEmpty else { return }

        // Wait for any prior batch task to finish (or be cancelled by a newer
        // send). Do not start a second concurrent LLM call for the same chat.
        if let prior = activeUserBatchTask {
            await logger.log("Waiting for prior user-batch LLM task before starting next batch", level: .debug)
            _ = try? await prior.value
        }

        let work = Task { [weak self] in
            guard let self else { return }
            try await self.processAccumulatedBatch(batch)
        }
        activeUserBatchTask = work
        defer {
            if activeUserBatchTask == work {
                activeUserBatchTask = nil
            }
        }
        try await work.value
    }

    func processAccumulatedBatch(_ batch: AccumulatedMessageBatch) async throws {
        guard !batch.messages.isEmpty else { return }

        // Batch already left the accumulator; drop typing state unless a
        // pauseable delivery is still outstanding.
        await clearTypingTrackingIfUnneeded()

        // Capture generation at start so a newer user send can discard this reply.
        let generation = userReplyGeneration
        isProcessingUserBatch = true
        // Cleared when this batch function returns. Delivery may still run
        // in-memory; recovery also checks activeUserReplyDelivery / tasks.
        defer { isProcessingUserBatch = false }

        // Another concurrent entry slipped in after the outer wait (should be
        // rare with activeUserBatchTask); drop if generation already moved on.
        if Task.isCancelled {
            await logger.log("User batch cancelled before LLM gen=\(generation)", level: .debug)
            return
        }

        await transitionTo(.conversing)
        currentConversationId = batch.conversationId
        await onReplyGenerating?()

        // See BackgroundTaskAssertion's doc comment: this is specifically for
        // the "user sends a message and immediately backgrounds/quits the
        // app" case — without it, the LLM request below (and the delivery
        // that follows it) gets killed mid-flight within seconds of
        // backgrounding, with no reply ever generated.
        let backgroundTask = await BackgroundTaskAssertion()
        await backgroundTask.begin(name: "accumulatedBatchReply")

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
        let recentMessages = memoryContext.recentMessages

        let combinedUserMessage = batch.messages.map { $0.content }.joined(separator: "\n")
        let diaryMemory = await diaryService.diaryMemorySnippet(
            for: combinedUserMessage,
            characterName: character.name
        )
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
            diaryMemory: diaryMemory,
            conversationGap: context.conversationGap
        )

        // Multi-message batches use an explicit consecutive-message prompt so
        // the model answers once, cohesively, instead of itemizing each line.
        let userMessage: String
        if batch.messages.count > 1 {
            userMessage = buildBatchPrompt(
                batch.messages,
                recentMessages: recentMessages,
                character: character,
                user: user,
                longTermSummary: memoryContext.globalSummary
            )
        } else {
            userMessage = promptBuilder.buildConversationPrompt(
                userMessage: combinedUserMessage,
                character: character,
                user: user,
                recentMessages: recentMessages,
                longTermSummary: memoryContext.globalSummary
            )
        }

        await logger.log(
            "Building reply for batch: \(batch.messages.count) msg(s), \(combinedUserMessage.count) chars gen=\(generation)",
            level: .debug
        )

        let settings: AppSettings
        let provider: LLMProviderService
        do {
            settings = try await settingsService.getSettings()
            await logger.log(
                "Batch reply provider setup: model=\(settings.selectedModel) mode=\(settings.endpointMode.rawValue) temp=\(settings.temperature) maxTokens=\(settings.maxTokens)",
                level: .debug
            )
            provider = try await llmServiceFactory.createProvider(settings: settings)
            await logger.log("Batch reply provider ready; invoking LLM API", level: .debug)
        } catch {
            await logger.log(
                "Failed to create LLM provider for batch reply: \(error.localizedDescription)",
                level: .error
            )
            // Must clear generating UI + surface the error. Previously this path
            // only logged and rethrew, so the chat stayed on "正在输入…" forever
            // (common when API key / endpoint is missing or misconfigured).
            await failUserBatch(
                batch,
                generation: generation,
                error: error,
                userFacingPrefix: "助手回复失败：",
                backgroundTask: backgroundTask
            )
            throw error
        }

        do {
            let requestStart = Date()
            // Cooperative cancel check right before the network call; generation
            // is re-checked after so a response that finished after supersession
            // is still discarded and not scheduled for delivery.
            try Task.checkCancellation()
            guard generation == userReplyGeneration else {
                await logger.log(
                    "Skipping LLM call for superseded batch (gen \(generation) → \(userReplyGeneration))",
                    level: .debug
                )
                await backgroundTask.end()
                await onReplyReady?()
                return
            }
            let response = try await generateReply(
                provider: provider,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                settings: settings
            )
            let elapsed = Date().timeIntervalSince(requestStart)
            await logger.log(
                "Batch LLM response received in \(String(format: "%.2f", elapsed))s (\(response.count) chars) gen=\(generation)",
                level: .debug
            )

            guard generation == userReplyGeneration else {
                await logger.log(
                    "Discarding stale batch reply (gen \(generation) → \(userReplyGeneration))",
                    level: .debug
                )
                await backgroundTask.end()
                await onReplyReady?()
                return
            }

            let typingDelay = await typingDelayCalculator.totalDelay(
                forBatchMessages: batch.messages,
                assistantResponse: response
            )
            await logger.log(
                "Scheduling batch reply delivery: typingDelay=\(String(format: "%.1f", typingDelay))s elapsed=\(String(format: "%.1f", elapsed))s gen=\(generation)",
                level: .debug
            )

            try await scheduleGeneratedResponse(
                content: response,
                conversationId: batch.conversationId,
                eventType: nil,
                characterName: character.name,
                userName: user.name,
                typingDelay: typingDelay,
                elapsed: elapsed,
                backgroundTask: backgroundTask,
                isEventResponse: false,
                generation: generation
            )
        } catch is CancellationError {
            await logger.log("Batch LLM call cancelled gen=\(generation)", level: .debug)
            await backgroundTask.end()
            // Avoid leaving the generating indicator stuck after cancellation.
            if generation == userReplyGeneration {
                await onReplyReady?()
            }
            throw CancellationError()
        } catch {
            await failUserBatch(
                batch,
                generation: generation,
                error: error,
                userFacingPrefix: "助手回复失败：",
                backgroundTask: backgroundTask
            )
            throw error
        }
    }

    /// Marks the batch's user bubbles failed, clears generating UI, and logs.
    /// No-ops (except ending the background task) when a newer generation
    /// already superseded this batch.
    private func failUserBatch(
        _ batch: AccumulatedMessageBatch,
        generation: Int,
        error: Error,
        userFacingPrefix: String,
        backgroundTask: BackgroundTaskAssertion
    ) async {
        guard generation == userReplyGeneration else {
            await logger.log(
                "Ignoring failed stale batch reply (gen \(generation) → \(userReplyGeneration))",
                level: .debug
            )
            await backgroundTask.end()
            return
        }

        await markUserMessagesFailed(for: batch, errorMessage: error.localizedDescription)

        await transitionTo(.conversing)
        await onError?("\(userFacingPrefix)\(error.localizedDescription)")
        await onReplyReady?()
        await logger.log(
            "LLM call failed for user batch: \(String(describing: error))",
            level: .error
        )
        await backgroundTask.end()
    }

    private func markUserMessagesFailed(
        for batch: AccumulatedMessageBatch,
        errorMessage: String
    ) async {
        let batchStart = batch.messages.first?.timestamp ?? Date.distantPast
        do {
            try await chatMessageStore.markUserMessagesFailed(
                conversationId: batch.conversationId,
                since: batchStart,
                errorMessage: errorMessage
            )
        } catch {
            await logger.log(
                "Failed to mark user messages failed via store: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func buildBatchPrompt(
        _ messages: [AccumulatedMessage],
        recentMessages: [ChatMessageSnapshot],
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        longTermSummary: String?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.timeStyle = .medium
        dateFormatter.dateStyle = .none

        var prompt = ""

        if let longTermSummary, !longTermSummary.isEmpty {
            prompt += "【长期记忆】\n\(longTermSummary)\n\n"
        }

        if !recentMessages.isEmpty {
            prompt += "【最近的对话】\n"
            for message in recentMessages {
                let roleText = message.role == .assistant ? character.name : user.name
                prompt += "\(roleText)：\(message.llmContextContent)\n"
            }
            prompt += "\n"
        }

        prompt += "【用户连续发送的多条消息】\n"
        for (index, message) in messages.enumerated() {
            let timestamp = dateFormatter.string(from: message.timestamp)
            prompt += "\(index + 1). (\(timestamp)) \(message.content)\n"
        }

        prompt += """


说明：以上是用户在短时间内连续发出的多条消息，请当作同一段话听完后再回复。
要求：
1. 只给出一次自然、连贯的回复，不要逐条点名或编号回答。
2. 综合理解全部内容，抓住重点即可，不必面面俱到。
3. 以\(character.name)（男性角色）的身份回复\(user.name)（女性用户），语气自然、温暖。
"""

        return prompt
    }
}
