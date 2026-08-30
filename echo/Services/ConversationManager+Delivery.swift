import Foundation

/// Assistant reply scheduling and delivery: online/offline policy routing,
/// paced user-reply delivery, typing pause/resume, and bubble insertion.
extension ConversationManager {

    /// Routes a freshly generated reply through the online/offline delivery policy.
    func scheduleGeneratedResponse(
        content: String,
        conversationId: UUID,
        eventType: CompanionEventType?,
        characterName: String,
        userName: String,
        typingDelay: TimeInterval,
        elapsed: TimeInterval,
        backgroundTask: BackgroundTaskAssertion,
        isEventResponse: Bool,
        generation: Int? = nil
    ) async throws {
        let decision = await characterStatusManager.decideResponseDelivery()

        switch decision {
        case .deliverNow(let statusDelay):
            let remainingDelay = max(0, typingDelay + statusDelay - elapsed)
            await logger.log(
                "Delivery: deliverNow remainingDelay=\(String(format: "%.1f", remainingDelay))s (typing=\(String(format: "%.1f", typingDelay))s status=\(String(format: "%.1f", statusDelay))s elapsed=\(String(format: "%.1f", elapsed))s) event=\(isEventResponse)",
                level: .debug
            )

            if isEventResponse {
                try await delayedResponseManager.schedule(
                    content: content,
                    conversationId: conversationId,
                    eventType: eventType,
                    characterName: characterName,
                    delay: max(1, remainingDelay)
                )
                await backgroundTask.end()
            } else {
                let pendingId = try await delayedResponseManager.schedule(
                    content: content,
                    conversationId: conversationId,
                    eventType: eventType,
                    characterName: characterName,
                    delay: max(1, remainingDelay),
                    armInProcessDelivery: false
                )
                let payload = PendingUserReplyDelivery(
                    content: content,
                    conversationId: conversationId,
                    characterName: characterName,
                    userName: userName,
                    remainingDelay: remainingDelay,
                    needsEarlyOnline: false,
                    generation: generation ?? userReplyGeneration,
                    backgroundTask: backgroundTask,
                    pendingResponseId: pendingId
                )
                await beginUserReplyDelivery(payload)
            }

        case .comeOnlineAndDeliver(let statusDelay):
            let remainingDelay = max(0, typingDelay + statusDelay - elapsed)
            await logger.log(
                "Delivery: early online after \(String(format: "%.1f", remainingDelay))s (may look like no reply until then)",
                level: .info
            )

            if isEventResponse {
                // Event path: schedule early-online wait then park via delayed manager.
                pendingAssistantResponseDeliveryTask?.cancel()
                pendingAssistantResponseDeliveryTask = Task { [weak self] in
                    defer { Task { await backgroundTask.end() } }
                    if remainingDelay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
                    }
                    guard let self, !Task.isCancelled else { return }
                    await self.characterStatusManager.comeOnline()
                    let settleDelay = Double.random(in: 1...3)
                    try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    try? await self.delayedResponseManager.schedule(
                        content: content,
                        conversationId: conversationId,
                        eventType: eventType,
                        characterName: characterName,
                        delay: 1
                    )
                }
            } else {
                // Persist first so crash recovery does not re-LLM; live path still
                // owns early-online + bubble insert (no competing in-process arm).
                let pendingId = try await delayedResponseManager.schedule(
                    content: content,
                    conversationId: conversationId,
                    eventType: eventType,
                    characterName: characterName,
                    delay: max(1, remainingDelay),
                    armInProcessDelivery: false
                )
                let payload = PendingUserReplyDelivery(
                    content: content,
                    conversationId: conversationId,
                    characterName: characterName,
                    userName: userName,
                    remainingDelay: remainingDelay,
                    needsEarlyOnline: true,
                    generation: generation ?? userReplyGeneration,
                    backgroundTask: backgroundTask,
                    pendingResponseId: pendingId
                )
                await beginUserReplyDelivery(payload)
            }

        case .holdUntilOnline:
            await logger.log(
                "Delivery: hold until next online (API reply generated but parked; UI will not show it yet)",
                level: .info
            )
            try await delayedResponseManager.schedule(
                content: content,
                conversationId: conversationId,
                eventType: eventType,
                characterName: characterName,
                delay: nil
            )
            await backgroundTask.end()
            await resetStatusChangeContext()

            // Clear generating indicators; message is parked, not in-flight.
            if isEventResponse {
                // Event path already fires onEventResponseScheduled in caller.
            } else {
                await onReplyReady?()
                await transitionTo(.followUp)
            }
        }
    }

    private func beginUserReplyDelivery(_ payload: PendingUserReplyDelivery) async {
        pendingAssistantResponseDeliveryTask?.cancel()
        activeUserReplyDelivery = payload
        isUserReplyDeliveryPaused = false

        // If the user is currently typing (e.g. mid-batch continuation), hold
        // the reply until they stop — don't drop it.
        if await typingMonitor.isTyping {
            isUserReplyDeliveryPaused = true
            await logger.log(
                "User reply delivery held until typing stops gen=\(payload.generation) delay=\(String(format: "%.1f", payload.remainingDelay))s",
                level: .debug
            )
            return
        }

        await startUserReplyDeliveryTask(payload)
    }

    private func startUserReplyDeliveryTask(_ payload: PendingUserReplyDelivery) async {
        pendingAssistantResponseDeliveryTask?.cancel()
        let sleepDelay = max(0, payload.remainingDelay)
        userReplyDeliveryStartedAt = Date()
        activeUserReplyDelivery = payload
        isUserReplyDeliveryPaused = false

        await logger.log(
            "Starting user reply delivery wait: delay=\(String(format: "%.1f", sleepDelay))s earlyOnline=\(payload.needsEarlyOnline) gen=\(payload.generation) chars=\(payload.content.count)",
            level: .debug
        )

        // Intentionally do NOT end backgroundTask on cancel: typing pause cancels
        // this task and must keep the assertion + payload for resume. Ending is
        // handled by discardActiveUserReplyDelivery / successful deliver.
        pendingAssistantResponseDeliveryTask = Task { [weak self] in
            if sleepDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDelay * 1_000_000_000))
            }
            guard let self else { return }
            if Task.isCancelled {
                await self.logger.log(
                    "User reply delivery wait cancelled before insert gen=\(payload.generation)",
                    level: .debug
                )
                return
            }

            await self.logger.log(
                "User reply delivery wait finished; inserting bubbles gen=\(payload.generation)",
                level: .debug
            )

            if payload.needsEarlyOnline {
                await self.characterStatusManager.comeOnline()
                let settleDelay = Double.random(in: 1...3)
                try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            await self.resetStatusChangeContext()
            await self.deliverAssistantResponse(
                content: payload.content,
                conversationId: payload.conversationId,
                characterName: payload.characterName,
                userName: payload.userName,
                generation: payload.generation,
                backgroundTask: payload.backgroundTask,
                pendingResponseId: payload.pendingResponseId
            )
        }
    }

    func pauseUserReplyDeliveryForTyping() async {
        guard let payload = activeUserReplyDelivery else { return }
        guard !isUserReplyDeliveryPaused else { return }
        // Never interrupt an in-progress multi-bubble insert; only pause the pre-delivery wait.
        guard !isDeliveringUserReply else { return }
        guard payload.generation == userReplyGeneration else {
            await discardActiveUserReplyDelivery(reason: "stale generation while pausing")
            return
        }

        // Cancel the sleep task but keep the payload so we can resume.
        // Do not end backgroundTask here — resume still needs it.
        pendingAssistantResponseDeliveryTask?.cancel()
        pendingAssistantResponseDeliveryTask = nil

        let elapsed = userReplyDeliveryStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = max(0, payload.remainingDelay - max(0, elapsed))
        // After a mid-wait pause, cap residual delay so resume is snappy.
        let residualDelay = min(remaining, 1.5)

        activeUserReplyDelivery = PendingUserReplyDelivery(
            content: payload.content,
            conversationId: payload.conversationId,
            characterName: payload.characterName,
            userName: payload.userName,
            remainingDelay: residualDelay,
            needsEarlyOnline: payload.needsEarlyOnline,
            generation: payload.generation,
            backgroundTask: payload.backgroundTask,
            pendingResponseId: payload.pendingResponseId
        )
        if let pendingId = payload.pendingResponseId {
            await delayedResponseManager.rescheduleResponse(
                id: pendingId,
                delay: residualDelay,
                characterName: payload.characterName
            )
        }
        userReplyDeliveryStartedAt = nil
        isUserReplyDeliveryPaused = true
        await logger.log(
            "Paused pending user reply while typing (remaining \(String(format: "%.1f", residualDelay))s)",
            level: .debug
        )
    }

    func resumeUserReplyDeliveryIfNeeded() async {
        guard isUserReplyDeliveryPaused, let payload = activeUserReplyDelivery else { return }

        // If the user has another batch forming, keep the reply paused until
        // that batch flushes (a send will invalidate if it's a new message).
        if await messageBatcher?.hasPendingMessages() == true {
            return
        }

        guard payload.generation == userReplyGeneration else {
            await discardActiveUserReplyDelivery(reason: "stale generation on resume")
            return
        }

        isUserReplyDeliveryPaused = false
        await logger.log("Resuming paused user reply delivery", level: .debug)
        await startUserReplyDeliveryTask(payload)
    }

    /// Hard-cancel a pending user reply because newer content superseded it.
    func invalidatePendingUserReply(reason: String) async {
        userReplyGeneration += 1
        // Cancel in-flight LLM for the superseded generation so we do not
        // keep paying for (and potentially scheduling) a second API response.
        // Keep the task reference so a concurrent `handleAccumulatedBatch`
        // still awaits it and cannot start a second LLM call mid-unwind.
        activeUserBatchTask?.cancel()
        await discardActiveUserReplyDelivery(reason: reason)
    }

    func discardActiveUserReplyDelivery(reason: String) async {
        if activeUserReplyDelivery != nil || pendingAssistantResponseDeliveryTask != nil {
            await logger.log("Pending user reply discarded: \(reason)", level: .debug)
        }
        pendingAssistantResponseDeliveryTask?.cancel()
        pendingAssistantResponseDeliveryTask = nil
        if let payload = activeUserReplyDelivery {
            if let pendingId = payload.pendingResponseId {
                // Superseded by newer content — do not leave a zombie PendingResponse
                // that would later deliver a stale reply.
                await delayedResponseManager.cancelResponse(id: pendingId)
            }
            await payload.backgroundTask.end()
        }
        activeUserReplyDelivery = nil
        isUserReplyDeliveryPaused = false
        isDeliveringUserReply = false
        userReplyDeliveryStartedAt = nil
        await clearTypingTrackingIfUnneeded()
    }

    private func deliverAssistantResponse(
        content: String,
        conversationId: UUID,
        characterName: String,
        userName: String,
        generation: Int? = nil,
        backgroundTask: BackgroundTaskAssertion? = nil,
        pendingResponseId: UUID? = nil
    ) async {
        self.statusChangeContext = nil
        // Once bubble delivery starts, typing-pause must not cancel this task.
        if generation != nil {
            isDeliveringUserReply = true
            userReplyDeliveryStartedAt = nil
            // Mid-insert typing no longer matters; stop tracking if batch is empty.
            await clearTypingTrackingIfUnneeded()
        }
        defer {
            pendingAssistantResponseDeliveryTask = nil
            isDeliveringUserReply = false
            if let generation, generation == userReplyGeneration {
                activeUserReplyDelivery = nil
                isUserReplyDeliveryPaused = false
                userReplyDeliveryStartedAt = nil
            }
        }

        if let generation, generation != userReplyGeneration {
            await logger.log(
                "Skipping deliver of stale user reply (gen \(generation) → \(userReplyGeneration))",
                level: .debug
            )
            await backgroundTask?.end()
            await clearTypingTrackingIfUnneeded()
            // Stale work must not leave generating stuck; a newer batch owns the UI.
            return
        }

        let plannedCount = AssistantMessageDelivery.plan(from: content).count
        guard plannedCount > 0 else {
            await logger.log(
                "Assistant response was empty after segmentation (rawChars=\(content.count))",
                level: .warning
            )
            if let pendingResponseId {
                await delayedResponseManager.cancelResponse(id: pendingResponseId)
            }
            await backgroundTask?.end()
            await clearTypingTrackingIfUnneeded()
            // Empty plan used to return silently with isGeneratingReply still true.
            if generation == nil || generation == userReplyGeneration {
                await onError?("助手回复为空，请重试")
                await onReplyReady?()
            }
            return
        }

        await logger.log(
            "Delivering assistant response: \(plannedCount) segment(s), rawChars=\(content.count), conversation=\(conversationId)",
            level: .debug
        )

        do {
            await transitionTo(.conversing)
            let liveNotificationIdentifier = (pendingResponseId ?? activeUserReplyDelivery?.pendingResponseId).map {
                "delayed-response-fallback-\($0.uuidString)"
            }

            let result = try await AssistantMessageDelivery.deliver(
                content: content,
                chatMessageStore: chatMessageStore,
                notificationService: notificationService,
                options: .init(
                    characterName: characterName,
                    conversationId: conversationId,
                    notificationIdentifierPrefix: liveNotificationIdentifier
                ),
                shouldAbort: { [weak self] in
                    if Task.isCancelled { return true }
                    guard let self, let generation else { return false }
                    let currentGeneration = await self.userReplyGeneration
                    return generation != currentGeneration
                },
                onSegmentInserted: { [weak self] snapshot, index, total in
                    guard let self else { return }
                    await self.logger.log(
                        "Inserted assistant segment \(index + 1)/\(total) id=\(snapshot.id) chars=\(snapshot.content.count)",
                        level: .debug
                    )
                    await self.memoryManager.addMessage(
                        snapshot,
                        userName: userName,
                        characterName: characterName
                    )
                    await self.applyAssistantSegmentSideEffects(snapshot)
                }
            )

            if !result.completed {
                // Hard cancel / invalidate / stale generation mid-sequence.
                if generation == nil || generation == userReplyGeneration {
                    await backgroundTask?.end()
                    await onReplyReady?()
                }
                await clearTypingTrackingIfUnneeded()
                return
            }

            await logger.log(
                "Assistant delivered \(result.segmentCount) segment(s) for conversation \(conversationId)",
                level: .debug
            )

            await markSendingUserMessagesCompleted(conversationId: conversationId)

            // Claim the persisted PendingResponse so DelayedResponseManager / OS
            // fallback do not insert a duplicate after this live path finished.
            if let pendingResponseId {
                await delayedResponseManager.acknowledgeInProcessDelivery(id: pendingResponseId)
            } else if let pendingId = activeUserReplyDelivery?.pendingResponseId {
                await delayedResponseManager.acknowledgeInProcessDelivery(id: pendingId)
            }

            // Call onReplyReady once at the end to update UI
            await onReplyReady?()
            await transitionTo(.followUp)
            await backgroundTask?.end()
            await clearTypingTrackingIfUnneeded()
        } catch {
            await logger.log("Failed to deliver assistant response: \(error.localizedDescription)", level: .error)
            await backgroundTask?.end()
            await clearTypingTrackingIfUnneeded()
            if generation == nil || generation == userReplyGeneration {
                await onError?("助手回复发送失败：\(error.localizedDescription)")
                await onReplyReady?()
            }
        }
    }

    /// Snapshot / UI refresh hooks for one assistant bubble (shared delivery path).
    private func applyAssistantSegmentSideEffects(_ snapshot: ChatMessageSnapshot) async {
        // insertAssistantSegment already touches lastAssistantMessageAt; only
        // re-publish orchestration state (sticky id + conversationState).
        await persistConversationSnapshot()
        // Reveal this bubble now, rather than waiting for the whole sequence.
        await onMessageDelivered?()
        resetInactivityTimer()
    }

    func handleDelayedResponseDelivered(conversationId: UUID) async {
        currentConversationId = conversationId
        await markSendingUserMessagesCompleted(conversationId: conversationId)
        await transitionTo(.reactive)
        await onReplyReady?()
        resetInactivityTimer()
    }
}
