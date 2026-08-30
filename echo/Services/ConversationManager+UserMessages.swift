import Foundation

/// User message ingress: typing observation, text/image sends, and resend.
extension ConversationManager {

    func recordTypingActivity(_ text: String) async {
        // Idle keystrokes are ignored. We only care about typing while a
        // batch is waiting to flush or a user-reply delay can be paused.
        guard await shouldTrackTyping() else { return }
        await typingMonitor.observeInputChange(text)
    }

    /// True only when typing can still affect scheduling/delivery.
    private func shouldTrackTyping() async -> Bool {
        if await messageBatcher?.hasPendingMessages() == true {
            return true
        }
        // Pauseable pre-delivery wait (not mid multi-bubble insert).
        if activeUserReplyDelivery != nil && !isDeliveringUserReply {
            return true
        }
        return false
    }

    /// Drop stale typing state once nothing remains that cares about it.
    func clearTypingTrackingIfUnneeded() async {
        guard await !shouldTrackTyping() else { return }
        await typingMonitor.cancel()
    }

    func userStartedTyping() async {
        // Pause (don't drop) a reply that is only waiting on its delivery delay.
        // A brand-new user message still invalidates via sendMessage/resend.
        await pauseUserReplyDeliveryForTyping()
        await messageBatcher?.userStartedTyping()
    }

    func userStoppedTyping() async {
        await messageBatcher?.userStoppedTyping()
        await resumeUserReplyDeliveryIfNeeded()
        await clearTypingTrackingIfUnneeded()
    }

    // MARK: - User Messages

    func sendMessage(_ content: String, conversationId: UUID) async throws {
        try await delayedResponseManager.cancelPendingResponses()
        await invalidatePendingUserReply(reason: "new user message")

        // Stays `.sending` until an assistant reply is delivered (or permanently failed).
        // Survives force-quit so cold start can resume LLM work.
        let snapshot = try await chatMessageStore.insertUser(
            UserMessageDraft(
                content: content,
                conversationId: conversationId,
                isRead: true,
                status: .sending
            )
        )

        let user = await profileService.loadUser()
        let character = await profileService.loadCharacter()
        await memoryManager.addMessage(
            snapshot,
            userName: user.name,
            characterName: character.name
        )

        currentConversationId = conversationId
        await transitionTo(.waitingForResponse)

        try await characterStatusManager.userSentMessage()

        guard let messageBatcher else {
            throw ConversationError.messageAccumulatorNotConfigured
        }

        let typingState = await typingMonitor.isTyping
        await messageBatcher.append(
            content,
            timestamp: snapshot.timestamp,
            conversationId: conversationId,
            isTyping: typingState
        )

        if typingState {
            await typingMonitor.forceStopTyping()
        }

        resetInactivityTimer()
    }

    /// Re-queue an existing failed user message for LLM reply generation.
    /// Keeps the original bubble (no duplicate message row) and reuses any
    /// already-computed image recognition metadata.
    func resendMessage(id: UUID) async throws {
        guard let existing = try await chatMessageStore.fetchById(id) else {
            throw ConversationError.messageNotFound
        }
        guard existing.role == .user else {
            throw ConversationError.invalidResendTarget
        }

        try await delayedResponseManager.cancelPendingResponses()
        await invalidatePendingUserReply(reason: "resend user message")

        let conversationId = existing.conversationId
            ?? currentConversationId
            ?? UUID()
        let snapshot = try await chatMessageStore.prepareUserResend(
            id: id,
            status: .sending,
            conversationId: conversationId
        )
        currentConversationId = conversationId
        await transitionTo(.waitingForResponse)

        try await characterStatusManager.userSentMessage()

        guard let messageBatcher else {
            throw ConversationError.messageAccumulatorNotConfigured
        }

        let batchContent: String
        if snapshot.hasImage {
            let imageDescription = snapshot.imageRecognitionDescription ?? "用户发了一张图片"
            batchContent = imageBatchContent(
                userContent: snapshot.content,
                imageDescription: imageDescription
            )
        } else {
            batchContent = snapshot.content
        }

        await messageBatcher.append(
            batchContent,
            timestamp: snapshot.timestamp,
            conversationId: conversationId,
            isTyping: false
        )

        // Keep `.sending` until assistant delivery; enables kill-resume.
        _ = try await chatMessageStore.prepareUserResend(
            id: id,
            status: .sending,
            conversationId: conversationId
        )
        resetInactivityTimer()
    }

    func sendImageMessage(id: UUID = UUID(), content: String, imageData: Data, imageMimeType: String, conversationId: UUID) async throws {
        try await delayedResponseManager.cancelPendingResponses()
        await invalidatePendingUserReply(reason: "new image message")

        var snapshot = try await chatMessageStore.insertUser(
            UserMessageDraft(
                id: id,
                content: content,
                conversationId: conversationId,
                metadata: ["imageRecognitionDescription": "正在识别图片内容"],
                isRead: true,
                imageData: imageData,
                imageMimeType: imageMimeType,
                status: .recognizing
            )
        )

        let imageRecognition = await imageMessageProcessor.recognize(imageData)
        let imageDescription = imageRecognition.description
        snapshot = try await chatMessageStore.updateUser(
            id: id,
            status: .sending,
            metadata: ["imageRecognitionDescription": imageDescription]
        )

        try await sendImagePayloadToBackend(snapshot)

        let user = await profileService.loadUser()
        let character = await profileService.loadCharacter()
        await memoryManager.addMessage(
            snapshot,
            userName: user.name,
            characterName: character.name
        )

        currentConversationId = conversationId
        await transitionTo(.waitingForResponse)

        try await characterStatusManager.userSentMessage()

        guard let messageBatcher else {
            throw ConversationError.messageAccumulatorNotConfigured
        }

        let batchContent = imageBatchContent(userContent: content, imageDescription: imageDescription)
        let typingState = await typingMonitor.isTyping
        await logger.log(
            "sendImageMessage: labels=\(imageRecognition.formattedLabels)",
            level: .debug
        )
        await messageBatcher.append(
            batchContent,
            timestamp: snapshot.timestamp,
            conversationId: conversationId,
            isTyping: typingState
        )

        // Keep `.sending` until assistant delivery; enables kill-resume.
        _ = try await chatMessageStore.updateUser(
            id: id,
            status: .sending,
            isFailed: false,
            errorMessage: .some(nil)
        )

        if typingState {
            await typingMonitor.forceStopTyping()
        }

        resetInactivityTimer()
    }

    private func sendImagePayloadToBackend(_ message: ChatMessageSnapshot) async throws {
        guard let imageBase64 = message.imageBase64 else { return }

        // Placeholder for the real upload request body.
        _ = [
            "id": message.id.uuidString,
            "content": message.content,
            "imageMimeType": message.imageMimeType ?? "image/jpeg",
            "imageRecognitionDescription": message.imageRecognitionDescription ?? "",
            "imageBase64": imageBase64
        ]
    }

    func imageBatchContent(userContent: String, imageDescription: String) -> String {
        let imageContext = "用户发了一张图片，内容是：\(imageDescription)"
        let finalContent = if userContent.isEmpty {
            imageContext
        } else {
            "\(userContent)\n\(imageContext)"
        }

        return finalContent
    }
}
