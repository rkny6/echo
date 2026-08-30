import Foundation

/// Debug-panel and maintenance entry points for `ConversationManager`.
extension ConversationManager {

    func getDebugInfo() async throws -> ConversationDebugInfo {
        ConversationDebugInfo(
            state: conversationState,
            pendingEventCount: try await pendingEventQueue.count(),
            // PR2c: count via store (same source as idle gates).
            pendingResponseCount: await chatMessageStore.pendingDelayedResponseCount(),
            currentConversationId: currentConversationId
        )
    }

    /// Debug panel: today's character online schedule + live status flags.
    func getCharacterScheduleDebugInfo() async -> CharacterScheduleDebugInfo {
        await characterStatusManager.getScheduleDebugInfo(at: Date())
    }

    /// Debug: discard today's schedule and roll a new one under current policy.
    func regenerateScheduleForDebug() async -> CharacterScheduleDebugInfo {
        await characterStatusManager.regenerateScheduleForDebug(at: Date())
    }
    
    func getAllPendingEvents() async throws -> [PendingEvent] {
        try await pendingEventQueue.getAllPendingEvents()
    }

    func getAllPendingResponses() async throws -> [PendingResponseSnapshot] {
        // PR2c: debug list via store snapshots.
        await chatMessageStore.loadPendingDelayedResponses()
    }
    
    func forceProcessPendingEvents() async throws {
        await logger.log("Force processing pending events", level: .info)
        // First complete current conversation if any
        if conversationState != .idle {
            await transitionTo(.idle)
            currentConversationId = nil
            await messageBatcher?.cancel()
            await cancelPendingUserResponse()
        }
        
        // Process all pending events one by one
        while let pendingEvent = try await pendingEventQueue.dequeueHighestPriority() {
            await logger.log(
                "Force processing queued event: \(pendingEvent.eventType.rawValue)",
                level: .info
            )
            try await startConversation(event: pendingEvent.toCompanionEvent())
        }
    }
    
    func forceDeliverPendingResponses() async throws {
        try await delayedResponseManager.forceDeliverAll()
    }

    /// Enqueue already-generated proactive care (online greeting / evening check-in)
    /// through the same PendingResponse dual-track as user replies: persist +
    /// OS local-notification fallback + in-process paced delivery.
    /// - Returns: pending response id after successful schedule.
    @discardableResult
    func scheduleProactiveAssistantResponse(
        content: String,
        conversationId: UUID,
        eventType: CompanionEventType,
        characterName: String,
        delay: TimeInterval = 1
    ) async throws -> UUID {
        let plannedCount = AssistantMessageDelivery.plan(from: content).count
        guard plannedCount > 0 else {
            throw ConversationError.emptyAssistantPlan
        }
        let pendingId = try await delayedResponseManager.schedule(
            content: content,
            conversationId: conversationId,
            eventType: eventType,
            characterName: characterName,
            delay: max(1, delay),
            armInProcessDelivery: true
        )
        await logger.log(
            "Proactive response scheduled: id=\(pendingId) event=\(eventType.rawValue) segments=\(plannedCount) delay=\(Int(max(1, delay)))s",
            level: .info
        )
        return pendingId
    }
    
    func clearAllPendingEvents() async throws {
        try await pendingEventQueue.clearAll()
    }
    
    func clearAllPendingResponses() async throws {
        try await delayedResponseManager.clearAll()
    }

    func afterMessagesDeleted(messageIDs: Set<UUID>, conversationIds: Set<UUID>) async {
        // Durable ChatMessage delete + ConversationSnapshot recompute already ran
        // in ChatMessageStore. Only clear non-chat side effects here.
        _ = messageIDs

        if !conversationIds.isEmpty {
            do {
                try await delayedResponseManager.cancelPendingResponses(for: conversationIds)
            } catch {
                await logger.log(
                    "Failed to cancel pending responses after message delete: \(error.localizedDescription)",
                    level: .warning
                )
            }
        }

        // Drop in-flight / parked user-reply delivery that may still reference
        // deleted context; user can resend if they still want a reply.
        await invalidatePendingUserReply(reason: "messages deleted")
        await logger.log(
            "After message delete: pending cancelled for \(conversationIds.count) conversation(s)",
            level: .debug
        )
    }
}
