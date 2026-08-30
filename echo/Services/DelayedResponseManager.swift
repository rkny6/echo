import Foundation
import SwiftData

actor DelayedResponseManager {
    private let profileService: any ProfileProviding
    private let notificationService: NotificationScheduling
    private let logger: LoggingProviding
    /// Durable owner for ChatMessage + PendingResponse rows (PR1b / PR2d).
    private let chatMessageStore: ChatMessageStore
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    private var onDelivered: (@Sendable (UUID) async -> Void)?
    /// When true, pending responses may deliver. Defaults closed until status sync.
    private var isCharacterOnline: Bool = false
    /// Pending rows owned by ConversationManager's live user-reply path
    /// (`armInProcessDelivery: false`). Must not be armed by online flush /
    /// cold-start reschedule while the live owner is still responsible —
    /// otherwise the same API reply is inserted twice (live path + delayed path).
    private var liveOwnedResponseIds: Set<UUID> = []

    /// Far-future placeholder so held replies are not treated as due.
    private static let holdUntilOnlinePlaceholderDelay: TimeInterval = 60 * 60 * 24 * 365
    /// When delivery is due but the character is still offline, re-check later.
    private static let offlineRetryDelay: TimeInterval = 30
    /// Held replies older than this are force-released even if still offline
    /// so a broken schedule cannot strand content forever ("read but no reply").
    private static let holdUntilOnlineMaxAge: TimeInterval = 60 * 60 * 12
    /// Periodic cold-start safety net when status never flips to online.
    private static let stuckHoldScanInterval: TimeInterval = 60 * 15
    /// Give the in-process delivery path time to cancel its crash-recovery
    /// fallback before the OS presents a second notification.
    private static let fallbackNotificationGracePeriod: TimeInterval = 5
    private var stuckHoldScanTask: Task<Void, Never>?

    init(
        profileService: any ProfileProviding,
        notificationService: NotificationScheduling,
        chatMessageStore: ChatMessageStore,
        logger: LoggingProviding
    ) {
        self.profileService = profileService
        self.notificationService = notificationService
        self.chatMessageStore = chatMessageStore
        self.logger = logger
        Task {
            await schedulePersistedPendingResponses()
            await startStuckHoldSafetyScan()
        }
    }

    func setOnDelivered(_ handler: @escaping @Sendable (UUID) async -> Void) {
        onDelivered = handler
    }

    func setCharacterOnline(_ online: Bool) {
        isCharacterOnline = online
        if online {
            // Online flag may arrive before handleStatusChange reschedule; also
            // covers force-deliver / debug paths that only toggle the gate.
            Task { await self.releaseStuckHeldResponsesIfNeeded(force: false) }
        }
    }

    /// - Parameter delay: seconds until delivery. `nil` parks the reply until
    ///   `reschedulePendingResponsesForCharacterOnline()` runs (true offline hold).
    /// - Parameter armInProcessDelivery: when `false`, only persists + optional OS
    ///   fallback so a live owner (ConversationManager user-reply path) can claim
    ///   delivery. Cold start still re-arms via `schedulePersistedPendingResponses`.
    @discardableResult
    func schedule(
        content: String,
        conversationId: UUID,
        eventType: CompanionEventType?,
        characterName: String,
        delay: TimeInterval? = nil,
        armInProcessDelivery: Bool = true
    ) async throws -> UUID {
        let resolvedDelay = delay ?? Self.holdUntilOnlinePlaceholderDelay
        let holdUntilOnline = delay == nil
        let snapshot = try await chatMessageStore.insertPendingResponse(
            PendingResponseDraft(
                content: content,
                scheduledDeliveryTime: Date().addingTimeInterval(resolvedDelay),
                conversationId: conversationId,
                eventType: eventType
            )
        )
        if !armInProcessDelivery {
            liveOwnedResponseIds.insert(snapshot.id)
        }
        await logger.log(
            "Delayed response created: id=\(snapshot.id) delay=\(holdUntilOnline ? "holdUntilOnline" : "\(Int(resolvedDelay))s") arm=\(armInProcessDelivery) liveOwned=\(!armInProcessDelivery) event=\(eventType?.rawValue ?? "none")",
            level: .debug
        )

        // Held replies intentionally skip OS fallback notifications — they must
        // only surface when the character actually comes online.
        if !holdUntilOnline {
            // OS fallback: survives process death even when in-process sleep cannot.
            do {
                try await notificationService.scheduleNotification(
                    title: characterName,
                    body: firstLine(of: content),
                    delay: resolvedDelay + Self.fallbackNotificationGracePeriod,
                    metadata: [
                        "conversationId": conversationId.uuidString,
                        "responseId": snapshot.id.uuidString
                    ],
                    identifier: Self.fallbackNotificationIdentifier(for: snapshot.id)
                )
            } catch {
                await logger.log(
                    "Failed to pre-schedule fallback notification for id=\(snapshot.id): \(error.localizedDescription)",
                    level: .warning
                )
            }

            if armInProcessDelivery {
                scheduleDelivery(for: snapshot, characterName: characterName)
            }
        }

        return snapshot.id
    }

    /// Live owner finished inserting chat bubbles itself — mark pending delivered
    /// without inserting again, and cancel the OS fallback.
    func acknowledgeInProcessDelivery(id: UUID) async {
        liveOwnedResponseIds.remove(id)
        do {
            guard try await chatMessageStore.updatePendingResponseStatus(
                id: id,
                status: .delivered,
                onlyIfPending: true
            ) != nil else { return }
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            await logger.log("Pending response acknowledged by in-process delivery: id=\(id)", level: .debug)
        } catch {
            await logger.log(
                "Failed to acknowledge pending response \(id): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    /// Discard a parked reply (e.g. user sent newer content).
    func cancelResponse(id: UUID) async {
        liveOwnedResponseIds.remove(id)
        do {
            guard try await chatMessageStore.updatePendingResponseStatus(
                id: id,
                status: .cancelled,
                onlyIfPending: true
            ) != nil else { return }
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            await logger.log("Delayed response cancelled: id=\(id)", level: .debug)
        } catch {
            await logger.log(
                "Failed to cancel pending response \(id): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    /// Adjust scheduled time + OS fallback while a live owner pauses/resumes.
    func rescheduleResponse(id: UUID, delay: TimeInterval, characterName: String) async {
        do {
            let newTime = Date().addingTimeInterval(max(0, delay))
            guard let response = try await chatMessageStore.updatePendingResponseSchedule(
                id: id,
                scheduledDeliveryTime: newTime,
                onlyIfPending: true
            ) else { return }

            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            try? await notificationService.scheduleNotification(
                title: characterName,
                body: firstLine(of: response.content),
                delay: max(1, delay) + Self.fallbackNotificationGracePeriod,
                metadata: [
                    "conversationId": response.conversationId.uuidString,
                    "responseId": response.id.uuidString
                ],
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            // Live owner keeps in-process wait; do not arm a competing delivery task.
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            await logger.log(
                "Rescheduled live-owned pending response: id=\(id) delay=\(Int(max(0, delay)))s",
                level: .debug
            )
        } catch {
            await logger.log(
                "Failed to reschedule pending response \(id): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    func cancelPendingResponses() async throws {
        let ids = try await chatMessageStore.cancelAllPendingResponses()
        for id in ids {
            liveOwnedResponseIds.remove(id)
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            await logger.log("Delayed response cancelled: id=\(id)", level: .debug)
        }
    }

    /// Cancel undelivered replies for specific conversations (e.g. after the
    /// user deletes messages in that thread). Empty `conversationIds` is a no-op.
    func cancelPendingResponses(for conversationIds: Set<UUID>) async throws {
        guard !conversationIds.isEmpty else { return }
        let ids = try await chatMessageStore.cancelPendingResponses(for: conversationIds)
        for id in ids {
            liveOwnedResponseIds.remove(id)
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
            await logger.log(
                "Delayed response cancelled for conversation: id=\(id)",
                level: .debug
            )
        }
    }

    /// PR2c/d: read-side count goes through `ChatMessageStore`.
    func pendingCount() async throws -> Int {
        await chatMessageStore.pendingDelayedResponseCount()
    }

    /// True when an assistant reply is already parked for this conversation
    /// (offline hold / delayed delivery). Resume must not re-call the LLM.
    func hasPendingResponses(for conversationId: UUID) async throws -> Bool {
        await chatMessageStore.hasPendingDelayedResponses(for: conversationId)
    }

    func reschedulePendingResponsesForCharacterOnline() async {
        isCharacterOnline = true
        await flushPendingResponsesSoon(reason: "character online")
    }

    /// Cold start / foreground: re-arm due work and force-release held replies
    /// that have waited longer than `holdUntilOnlineMaxAge` (schedule stuck).
    func recoverHeldResponsesOnForeground() async {
        await schedulePersistedPendingResponses()
        await releaseStuckHeldResponsesIfNeeded(force: true)
    }

    private func startStuckHoldSafetyScan() {
        stuckHoldScanTask?.cancel()
        stuckHoldScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.stuckHoldScanInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.releaseStuckHeldResponsesIfNeeded(force: true)
            }
        }
    }

    /// Held (`delay: nil`) rows use a year-long placeholder delivery time.
    private func isHeldPlaceholder(_ response: PendingResponseSnapshot, now: Date = Date()) -> Bool {
        response.scheduledDeliveryTime.timeIntervalSince(now) > 60 * 60 * 24
    }

    private func flushPendingResponsesSoon(reason: String) async {
        let characterName = await profileService.characterName()
        let responses = await chatMessageStore.loadPendingDelayedResponses()
        guard !responses.isEmpty else { return }
        // Stagger multi-held replies slightly so they don't all land at once.
        var cumulativeOffset: TimeInterval = 0
        for response in responses {
            // Live owner is already waiting / inserting this content.
            if liveOwnedResponseIds.contains(response.id) {
                await logger.log(
                    "Skipping live-owned pending response on flush (\(reason)): id=\(response.id)",
                    level: .debug
                )
                continue
            }
            let newDelay = TimeInterval(Int.random(in: 2...5)) + cumulativeOffset
            cumulativeOffset += TimeInterval(Int.random(in: 1...3))
            let newTime = Date().addingTimeInterval(newDelay)
            do {
                guard let updated = try await chatMessageStore.updatePendingResponseSchedule(
                    id: response.id,
                    scheduledDeliveryTime: newTime,
                    onlyIfPending: true
                ) else { continue }
                try? await notificationService.scheduleNotification(
                    title: characterName,
                    body: firstLine(of: updated.content),
                    delay: newDelay + Self.fallbackNotificationGracePeriod,
                    metadata: [
                        "conversationId": updated.conversationId.uuidString,
                        "responseId": updated.id.uuidString
                    ],
                    identifier: Self.fallbackNotificationIdentifier(for: updated.id)
                )
                await logger.log(
                    "Rescheduled pending response (\(reason)): id=\(updated.id) newDelay=\(Int(newDelay))s",
                    level: .debug
                )
                scheduleDelivery(for: updated, characterName: characterName)
            } catch {
                await logger.log(
                    "Failed to reschedule pending response \(response.id) (\(reason)): \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    /// If a held reply has been parked past `holdUntilOnlineMaxAge`, open the
    /// online gate and flush — prevents permanent "read but no reply" when
    /// status/schedule never fires offline→online.
    private func releaseStuckHeldResponsesIfNeeded(force: Bool) async {
        let responses = await chatMessageStore.loadPendingDelayedResponses()
        let now = Date()
        let stuck = responses.filter { response in
            guard isHeldPlaceholder(response, now: now) else { return false }
            let age = now.timeIntervalSince(response.createdAt)
            return age >= Self.holdUntilOnlineMaxAge
        }
        guard !stuck.isEmpty else { return }

        await logger.log(
            "Force-releasing \(stuck.count) held pending response(s) older than \(Int(Self.holdUntilOnlineMaxAge / 3600))h (force=\(force))",
            level: .info
        )
        // Temporarily allow deliver(); restore previous gate after flush arms.
        let previousOnline = isCharacterOnline
        isCharacterOnline = true
        await flushPendingResponsesSoon(reason: "stuck hold safety")
        if !previousOnline {
            // Keep gate open only for the armed delivery windows; re-arm
            // path will re-check isCharacterOnline at fire time. If still
            // offline then, offlineRetry re-arm (P0) keeps trying.
            isCharacterOnline = previousOnline
        }
    }

    private func schedulePersistedPendingResponses() async {
        let characterName = await profileService.characterName()
        let responses = await chatMessageStore.loadPendingDelayedResponses()
        let now = Date()
        var scheduledCount = 0
        var releasedStuck = false
        for response in responses {
            // Live owner still owns delivery in this process.
            if liveOwnedResponseIds.contains(response.id) {
                await logger.log(
                    "Skipping live-owned pending response on cold-start reschedule: id=\(response.id)",
                    level: .debug
                )
                continue
            }
            // Skip far-future held replies unless they are past max age.
            if isHeldPlaceholder(response, now: now) {
                let age = now.timeIntervalSince(response.createdAt)
                if age >= Self.holdUntilOnlineMaxAge {
                    releasedStuck = true
                    continue
                }
                await logger.log(
                    "Skipping held pending response until online: id=\(response.id)",
                    level: .debug
                )
                continue
            }
            scheduleDelivery(for: response, characterName: characterName)
            scheduledCount += 1
        }
        if scheduledCount > 0 {
            await logger.log(
                "Rescheduled \(scheduledCount) persisted pending responses after app launch",
                level: .debug
            )
        }
        if releasedStuck {
            await releaseStuckHeldResponsesIfNeeded(force: true)
        }
    }

    private func scheduleDelivery(for response: PendingResponseSnapshot, characterName: String) {
        let responseID = response.id
        let scheduledTime = response.scheduledDeliveryTime
        deliveryTasks[responseID]?.cancel()
        deliveryTasks[responseID] = Task { [weak self] in
            let delay = max(0, scheduledTime.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.deliver(responseID: responseID, characterName: characterName)
        }
    }

    private func rearmDelivery(responseID: UUID, characterName: String, after delay: TimeInterval) {
        deliveryTasks[responseID]?.cancel()
        deliveryTasks[responseID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.deliver(responseID: responseID, characterName: characterName)
        }
    }

    private func deliver(responseID: UUID, characterName: String) async {
        do {
            // Live ConversationManager path owns insert for this id — do not
            // race a second bubble sequence (common when early-online flips
            // status and flush/reschedule arms the same PendingResponse).
            if liveOwnedResponseIds.contains(responseID) {
                await logger.log(
                    "Delivery skipped; response still live-owned: id=\(responseID)",
                    level: .debug
                )
                return
            }

            guard let response = await chatMessageStore.loadPendingResponse(id: responseID),
                  response.status == .pending else { return }

            let eventType = response.eventType
            // Hard gate: never surface held/offline *user* replies while offline.
            // Proactive care (online greeting / evening check-in) may still deliver
            // so users get the already-queued content + notification even if the
            // character schedule says offline.
            // Re-arm instead of ending the one-shot task so due replies are not
            // silently stranded until the next explicit online reschedule path
            // (and OS fallback banners stay consistent with eventual chat insert).
            if !isCharacterOnline && !Self.allowsDeliveryWhileOffline(eventType) {
                await logger.log(
                    "Delivery deferred while character offline: id=\(responseID); re-arm in \(Int(Self.offlineRetryDelay))s",
                    level: .debug
                )
                rearmDelivery(
                    responseID: responseID,
                    characterName: characterName,
                    after: Self.offlineRetryDelay
                )
                return
            }

            // The in-process path is taking over delivery (app is alive right
            // now), so cancel the OS-scheduled fallback to avoid double-notifying.
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: responseID)
            )

            let rawContent = response.content
            let conversationId = response.conversationId
            let plannedCount = AssistantMessageDelivery.plan(from: rawContent).count
            guard plannedCount > 0 else {
                _ = try await chatMessageStore.updatePendingResponseStatus(
                    id: responseID,
                    status: .cancelled,
                    onlyIfPending: true
                )
                deliveryTasks[responseID] = nil
                await logger.log("Delayed response became empty after segmentation: id=\(responseID)", level: .warning)
                return
            }

            var extraMetadata: [String: String] = ["responseId": responseID.uuidString]
            if let eventType {
                extraMetadata["eventType"] = eventType.rawValue
                extraMetadata["source"] = Self.proactiveSourceMetadata(for: eventType)
            }

            let result = try await AssistantMessageDelivery.deliver(
                content: rawContent,
                chatMessageStore: chatMessageStore,
                notificationService: notificationService,
                options: .init(
                    characterName: characterName,
                    conversationId: conversationId,
                    eventType: eventType,
                    extraMetadata: extraMetadata
                ),
                shouldAbort: { [weak self] in
                    if Task.isCancelled { return true }
                    guard let self else { return true }
                    // Status may have been claimed/cancelled mid multi-bubble wait.
                    if let latest = await self.chatMessageStore.loadPendingResponse(id: responseID),
                       latest.status != .pending {
                        return true
                    }
                    return false
                },
                onSegmentInserted: { [weak self] _, _, _ in
                    // insertAssistantSegment already advances lastAssistantMessageAt.
                    guard let self else { return }
                    await self.onDelivered?(conversationId)
                }
            )

            if !result.completed {
                if Task.isCancelled {
                    return
                }
                await logger.log(
                    "Delayed delivery aborted mid-sequence; id=\(responseID)",
                    level: .debug
                )
                return
            }

            // Re-check: in-process owner may have claimed during multi-bubble pacing.
            _ = try await chatMessageStore.updatePendingResponseStatus(
                id: responseID,
                status: .delivered,
                onlyIfPending: true
            )
            deliveryTasks[responseID] = nil
            await logger.log(
                "Delayed response delivered \(result.segmentCount) segment(s): id=\(responseID)",
                level: .debug
            )
        } catch {
            await logger.log(
                "Delayed response delivery failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }


    private static func fallbackNotificationIdentifier(for responseID: UUID) -> String {
        "delayed-response-fallback-\(responseID.uuidString)"
    }

    /// Proactive care already decided to reach out — do not park behind the
    /// character online schedule gate (user replies still wait for online).
    private static func allowsDeliveryWhileOffline(_ eventType: CompanionEventType?) -> Bool {
        switch eventType {
        case .onlineGreeting, .eveningCheckIn:
            return true
        default:
            return false
        }
    }

    private static func proactiveSourceMetadata(for eventType: CompanionEventType) -> String {
        switch eventType {
        case .onlineGreeting: return "online_greeting"
        case .eveningCheckIn: return "evening_check_in"
        default: return eventType.rawValue
        }
    }

    /// Short preview text for the fallback notification's body. Prefer the
    /// first planned segment so JSON multi-message payloads never show raw.
    private nonisolated func firstLine(of content: String) -> String {
        AssistantMessageDelivery.notificationPreview(from: content)
    }

    /// PR2c/d: debug list via store snapshots (no live `@Model` across actors).
    func getAllPendingResponses() async throws -> [PendingResponseSnapshot] {
        await chatMessageStore.loadPendingDelayedResponses()
    }

    func forceDeliverAll() async throws {
        // Debug / manual flush: temporarily open the online gate.
        let previousOnline = isCharacterOnline
        isCharacterOnline = true
        defer { isCharacterOnline = previousOnline }

        let characterName = await profileService.characterName()
        let responses = await chatMessageStore.loadPendingDelayedResponses()
        for response in responses {
            await deliver(responseID: response.id, characterName: characterName)
        }
    }

    func clearAll() async throws {
        let ids = try await chatMessageStore.cancelAllPendingResponses()
        for id in ids {
            liveOwnedResponseIds.remove(id)
            deliveryTasks[id]?.cancel()
            deliveryTasks[id] = nil
            try? await notificationService.cancelNotification(
                identifier: Self.fallbackNotificationIdentifier(for: id)
            )
        }
        if !ids.isEmpty {
            await logger.log("Cleared all pending responses", level: .info)
        }
    }
}
