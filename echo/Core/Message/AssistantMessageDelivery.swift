import Foundation

/// Shared outcome for every assistant multi-bubble delivery path.
struct AssistantMessageDeliveryResult: Sendable, Equatable {
    let messageIds: [UUID]
    let segmentCount: Int
    let firstSegmentContent: String?
    /// `false` when cancelled mid-sequence (partial inserts may already exist).
    let completed: Bool
}

/// Single planner + paced multi-bubble insert/notify path used by user replies,
/// delayed recovery, health proactive, online greeting, and evening check-in.
enum AssistantMessageDelivery {
    private static let planner = AssistantMessageSequencePlanner()

    /// Parse structured JSON / plain text into paced segments (cap 1–3).
    static func plan(from content: String) -> [PlannedAssistantMessage] {
        planner.plan(from: content)
    }

    /// Flatten model payload to readable text (e.g. typing-delay estimates).
    static func renderedText(from content: String) -> String {
        planner.renderedText(from: content)
    }

    /// Notification preview that never shows raw JSON wrappers.
    static func notificationPreview(from content: String) -> String {
        if let first = plan(from: content).first?.content {
            return first
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Options: Sendable {
        var characterName: String
        var conversationId: UUID?
        var eventType: CompanionEventType?
        var extraMetadata: [String: String] = [:]
        /// Stable prefix for replacing a pending fallback notification.
        /// Segment indexes are appended for multi-bubble deliveries.
        var notificationIdentifierPrefix: String?
        /// When false, never posts notifications (segments still insert).
        var allowNotifications: Bool = true
        /// Sleep between bubbles using each segment's `delayFromPrevious`.
        var paceSegments: Bool = true
    }

    /// Plan + insert assistant segments with optional pacing and notifications.
    /// - Parameters:
    ///   - chatMessageStore: single durable owner for `ChatMessage` rows.
    ///   - shouldAbort: checked before each segment (and after inter-segment sleep).
    ///   - onSegmentInserted: called after each successful save with the durable
    ///     snapshot (callers pass it to memory / prompt buffers as-is).
    @discardableResult
    static func deliver(
        content: String,
        chatMessageStore: ChatMessageStore,
        notificationService: NotificationScheduling?,
        options: Options,
        shouldAbort: (@Sendable () async -> Bool)? = nil,
        onSegmentInserted: (@Sendable (ChatMessageSnapshot, Int, Int) async -> Void)? = nil
    ) async throws -> AssistantMessageDeliveryResult {
        let plannedMessages = plan(from: content)
        guard !plannedMessages.isEmpty else {
            return AssistantMessageDeliveryResult(
                messageIds: [],
                segmentCount: 0,
                firstSegmentContent: nil,
                completed: false
            )
        }

        let deliveryGroupId = UUID().uuidString
        var messageIds: [UUID] = []

        for (index, plannedMessage) in plannedMessages.enumerated() {
            if let shouldAbort, await shouldAbort() {
                return AssistantMessageDeliveryResult(
                    messageIds: messageIds,
                    segmentCount: plannedMessages.count,
                    firstSegmentContent: messageIds.isEmpty ? nil : plannedMessages.first?.content,
                    completed: false
                )
            }

            if options.paceSegments, index > 0, plannedMessage.delayFromPrevious > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(plannedMessage.delayFromPrevious * 1_000_000_000)
                )
            }

            if let shouldAbort, await shouldAbort() {
                return AssistantMessageDeliveryResult(
                    messageIds: messageIds,
                    segmentCount: plannedMessages.count,
                    firstSegmentContent: messageIds.isEmpty ? nil : plannedMessages.first?.content,
                    completed: false
                )
            }

            var metadata = options.extraMetadata
            if let conversationId = options.conversationId {
                metadata["conversationId"] = conversationId.uuidString
            }
            metadata["deliveryGroupId"] = deliveryGroupId
            metadata["deliveryIndex"] = String(index)
            metadata["deliveryTotal"] = String(plannedMessages.count)

            let snapshot = try await chatMessageStore.insertAssistantSegment(
                AssistantSegmentDraft(
                    content: plannedMessage.content,
                    timestamp: Date(),
                    conversationId: options.conversationId,
                    eventType: options.eventType,
                    metadata: metadata,
                    isRead: false
                )
            )
            messageIds.append(snapshot.id)

            await onSegmentInserted?(snapshot, index, plannedMessages.count)

            if options.allowNotifications,
               plannedMessage.shouldNotify,
               let notificationService {
                let notificationIdentifier = options.notificationIdentifierPrefix.map { prefix in
                    index == 0 ? prefix : "\(prefix)-segment-\(index)"
                }
                try await notificationService.scheduleNotification(
                    title: options.characterName,
                    body: plannedMessage.content,
                    delay: 0,
                    metadata: metadata,
                    identifier: notificationIdentifier ?? UUID().uuidString
                )
            }
        }

        return AssistantMessageDeliveryResult(
            messageIds: messageIds,
            segmentCount: plannedMessages.count,
            firstSegmentContent: plannedMessages.first?.content,
            completed: true
        )
    }
}
