import Foundation

/// Crash/foreground recovery and conversation teardown for `ConversationManager`.
extension ConversationManager {

    /// Cold start / foreground: re-queue user bubbles still marked `.sending`
    /// (or stuck `.recognizing`) so a force-quit mid-reply does not leave a
    /// permanent silent dead-end.
    func recoverInterruptedUserReplies() async {
        guard !isRecoveringInterruptedReplies else { return }
        isRecoveringInterruptedReplies = true
        defer { isRecoveringInterruptedReplies = false }

        // In-memory pipeline already owns the reply — do not double-fire LLM.
        if isProcessingUserBatch {
            await logger.log("Skip interrupted-reply recovery: user batch already processing", level: .debug)
            return
        }
        if await messageBatcher?.hasPendingMessages() == true {
            await logger.log("Skip interrupted-reply recovery: batcher still pending", level: .debug)
            return
        }
        if activeUserReplyDelivery != nil || isDeliveringUserReply || pendingAssistantResponseDeliveryTask != nil {
            await logger.log("Skip interrupted-reply recovery: in-memory delivery still active", level: .debug)
            return
        }

        await failStuckRecognizingUserMessages()

        let pendingUsers: [ChatMessageSnapshot]
        do {
            pendingUsers = try await chatMessageStore.fetchUserMessages(status: .sending)
        } catch {
            await logger.log(
                "Interrupted-reply recovery failed to fetch sending users: \(error.localizedDescription)",
                level: .error
            )
            return
        }
        guard !pendingUsers.isEmpty else { return }

        await logger.log(
            "Interrupted-reply recovery found \(pendingUsers.count) user message(s) still sending",
            level: .info
        )

        let stickyFallback = await chatMessageStore.resolveConversationId()
        let grouped = Dictionary(grouping: pendingUsers) { message -> UUID in
            message.conversationId ?? currentConversationId ?? stickyFallback
        }

        for (conversationId, messages) in grouped {
            let sorted = messages.sorted { $0.timestamp < $1.timestamp }

            // Assistant already landed after these users (e.g. crash between
            // insert and status flip) — just clear the sticky sending flag.
            let lastTimestamp = sorted.last?.timestamp ?? .distantPast
            let assistantPresent: Bool
            do {
                assistantPresent = try await chatMessageStore.hasAssistantReply(
                    after: lastTimestamp,
                    conversationId: conversationId
                )
            } catch {
                assistantPresent = false
            }
            if assistantPresent {
                await markSendingUserMessagesCompleted(conversationId: conversationId)
                await logger.log(
                    "Recovery: assistant already present for \(conversationId); marked user messages completed",
                    level: .debug
                )
                continue
            }

            // Reply content already parked offline / delayed — wait for that path.
            // PR2c: pending existence is read through ChatMessageStore.
            if await chatMessageStore.hasPendingDelayedResponses(for: conversationId) {
                await logger.log(
                    "Recovery: pending delayed response already exists for \(conversationId); skip re-LLM",
                    level: .debug
                )
                continue
            }

            let batchMessages: [AccumulatedMessage] = sorted.map { message in
                let content: String
                if message.hasImage {
                    content = imageBatchContent(
                        userContent: message.content,
                        imageDescription: message.imageRecognitionDescription ?? "用户发了一张图片"
                    )
                } else {
                    content = message.content
                }
                return AccumulatedMessage(content: content, timestamp: message.timestamp)
            }

            guard !batchMessages.isEmpty else { continue }

            let batch = AccumulatedMessageBatch(
                conversationId: conversationId,
                messages: batchMessages,
                createdAt: Date()
            )

            await logger.log(
                "Recovery: re-queueing \(batch.messages.count) interrupted user message(s) for conversation \(conversationId)",
                level: .info
            )

            do {
                try await handleAccumulatedBatch(batch)
            } catch is CancellationError {
                await logger.log("Recovery batch cancelled for \(conversationId)", level: .debug)
            } catch {
                await logger.log(
                    "Recovery batch failed for \(conversationId): \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    func markSendingUserMessagesCompleted(conversationId: UUID) async {
        do {
            try await chatMessageStore.markSendingUserMessagesCompleted(conversationId: conversationId)
        } catch {
            await logger.log(
                "Failed to mark sending user messages completed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func failStuckRecognizingUserMessages() async {
        do {
            let count = try await chatMessageStore.failRecognizingUserMessages()
            guard count > 0 else { return }
            await logger.log(
                "Marked \(count) stuck recognizing user message(s) as failed for resend",
                level: .info
            )
        } catch {
            await logger.log(
                "Failed to mark stuck recognizing messages: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func handleReadingIndicatorChange(_ visible: Bool) async {
        await onReadingIndicatorChange?(visible)
    }

    func cancelPendingUserResponse() async {
        // Hard cancel (conversation complete / force process): drop paused state too.
        await discardActiveUserReplyDelivery(reason: "hard cancel")
    }

    func completeConversation() async throws {
        guard conversationState != .idle else { return }
        // Keep sticky conversation id in the snapshot for health / delayed /
        // recovery; only clear the in-memory active handle so inactivity can
        // end the "live" session without minting a new UUID on the next care msg.
        // transitionTo(.idle) already persists via store (preserves sticky).
        currentConversationId = nil
        await transitionTo(.idle)
        await messageBatcher?.cancel()
        await cancelPendingUserResponse()
        // Foreground safety: held offline replies should not wait forever.
        await delayedResponseManager.recoverHeldResponsesOnForeground()

        if let pendingEvent = try await pendingEventQueue.dequeueHighestPriority() {
            await logger.log(
                "Processing queued event \(pendingEvent.eventType.rawValue) after conversation became idle",
                level: .info
            )
            try await startConversation(event: pendingEvent.toCompanionEvent())
        }
    }
}
