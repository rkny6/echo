import Foundation
import SwiftData

/// Whether health proactive currently "owns" caring outreach.
enum HealthCareStoryState: String, Sendable, Equatable {
    case none
    /// Job queued or LLM in flight.
    case pendingOrGenerating
    /// Extreme health event is detectable and not yet deduped away.
    case detectableNow
    /// Already delivered a health proactive message today.
    case alreadyDeliveredToday

    var hasStory: Bool { self != .none }
}

/// Orchestrates LLM-first proactive health notifications with job queue and dedup.
///
/// PR2e/f: durable `PendingHealthLLMJob` + `HealthAlertRecord` rows are owned by
/// `ChatMessageStore`. This service keeps detection / idle / governor / LLM /
/// delivery orchestration. Character/User profile reads go through
/// `ProfileService` (display name + LLM generation).
actor HealthProactiveDeliveryService {
    private let eventDetectionService: EventDetecting
    private let llmGenerationService: HealthLLMGenerationService
    private let notificationService: NotificationScheduling
    private let governor: NotificationGovernor
    private let logger: LoggingProviding
    /// Single durable owner for `ChatMessage` + health job rows (PR1b / PR2e).
    private let chatMessageStore: ChatMessageStore
    private let profileService: any ProfileProviding
    /// Lets the UI know a message landed outside the normal chat-reply flow
    /// (which has its own refresh callbacks) — without this, a health
    /// proactive message gets saved to the database and its notification
    /// fires, but the in-memory chat list the UI is actually showing never
    /// gets told to reload, so the message is invisible until something
    /// else happens to trigger a refresh.
    private var onMessageInserted: (@Sendable () async -> Void)?

    init(
        eventDetectionService: EventDetecting,
        llmGenerationService: HealthLLMGenerationService,
        notificationService: NotificationScheduling,
        chatMessageStore: ChatMessageStore,
        profileService: any ProfileProviding,
        governor: NotificationGovernor = NotificationGovernor(),
        logger: LoggingProviding
    ) {
        self.eventDetectionService = eventDetectionService
        self.llmGenerationService = llmGenerationService
        self.notificationService = notificationService
        self.chatMessageStore = chatMessageStore
        self.profileService = profileService
        self.governor = governor
        self.logger = logger
    }

    func setOnMessageInserted(_ handler: @escaping @Sendable () async -> Void) {
        self.onMessageInserted = handler
    }


    /// Snapshot used by online-greeting catch-up: health story wins over silence greeting.
    func healthCareStoryState() async -> HealthCareStoryState {
        if await chatMessageStore.hasAnyActiveHealthJob() {
            return .pendingOrGenerating
        }
        if await chatMessageStore.hasHealthAlertDeliveredToday() {
            return .alreadyDeliveredToday
        }

        do {
            let events = try await eventDetectionService.detectExtremeHealthEvents()
            let sorted = events.sorted { $0.priority > $1.priority }
            for event in sorted {
                let dedupKey = HealthAlertDedup.key(for: event)
                if await chatMessageStore.hasAlertRecord(dedupKey: dedupKey) {
                    continue
                }
                if await chatMessageStore.hasActiveHealthJob(dedupKey: dedupKey) {
                    return .pendingOrGenerating
                }
                return .detectableNow
            }
        } catch {
            await logger.log(
                "Health story detection failed: \(error.localizedDescription)",
                level: .debug
            )
        }
        return .none
    }

    /// Detect extreme health events, enqueue LLM jobs when idle and not deduped.
    func evaluateAndEnqueue(processImmediately: Bool) async {
        await logger.log(
            "Health proactive evaluate start processImmediately=\(processImmediately)",
            level: .debug
        )
        do {
            let events = try await eventDetectionService.detectExtremeHealthEvents()
            guard !events.isEmpty else {
                await logger.log("Health proactive: no candidates to enqueue", level: .debug)
                return
            }

            let candidateSummary = events
                .sorted { $0.priority > $1.priority }
                .map { "\($0.type.rawValue)/\($0.metadata["severity"] ?? "-")" }
                .joined(separator: ", ")
            await logger.log(
                "Health proactive candidates (\(events.count)): \(candidateSummary)",
                level: .debug
            )

            guard await ConversationIdleChecker.isIdle(
                chatMessageStore: chatMessageStore
            ) else {
                await logger.log(
                    "Health proactive skipped: conversation not idle (candidates=\(candidateSummary))",
                    level: .debug
                )
                return
            }

            let lastUserMessage = await ConversationIdleChecker.lastUserMessageDate(
                chatMessageStore: chatMessageStore
            )
            let governorDecision = governor.shouldSendHealthProactive(lastUserMessageDate: lastUserMessage)
            guard governorDecision.allowed else {
                await logger.log(
                    "Health proactive blocked: \(governorDecision.reason) (candidates=\(candidateSummary))",
                    level: .debug
                )
                return
            }

            let sorted = events.sorted { $0.priority > $1.priority }
            var enqueued = false
            var skippedDedup = 0
            var skippedActive = 0

            for event in sorted {
                // Menstrual uses cycle-scoped key; other health events stay per-day.
                let dedupKey = HealthAlertDedup.key(for: event)
                if await chatMessageStore.hasAlertRecord(dedupKey: dedupKey) {
                    skippedDedup += 1
                    await logger.log(
                        "Health proactive dedup skip: \(event.type.rawValue) key=\(dedupKey)",
                        level: .debug
                    )
                    continue
                }
                if await chatMessageStore.hasActiveHealthJob(dedupKey: dedupKey) {
                    skippedActive += 1
                    await logger.log(
                        "Health proactive job already queued: \(event.type.rawValue) key=\(dedupKey)",
                        level: .debug
                    )
                    continue
                }

                // Prefer active/sticky conversation id — never mint a one-off UUID
                // that fragments recovery / pending / notification deep-links.
                let conversationId = await chatMessageStore.resolveConversationId()
                do {
                    _ = try await chatMessageStore.insertHealthJob(
                        PendingHealthLLMJobDraft(
                            eventType: event.type,
                            metadata: event.metadata,
                            dedupKey: dedupKey,
                            conversationId: conversationId
                        )
                    )
                    enqueued = true
                    await logger.log(
                        "Enqueued health LLM job: \(event.type.rawValue) severity=\(event.metadata["severity"] ?? "-") key=\(dedupKey) reason=\(event.metadata["reason"] ?? "-")",
                        level: .info
                    )
                    break
                } catch {
                    await logger.log(
                        "Health proactive job insert failed: \(error.localizedDescription)",
                        level: .error
                    )
                    return
                }
            }

            if enqueued {
                await MainActor.run {
                    BackgroundTaskService.shared.scheduleHealthProcessing()
                }
                if processImmediately {
                    await logger.log("Health proactive processing enqueued job immediately", level: .debug)
                    await processPendingJobs()
                } else {
                    await logger.log("Health proactive job left for BG processing", level: .debug)
                }
            } else {
                await logger.log(
                    "Health proactive no job enqueued (dedup=\(skippedDedup) active=\(skippedActive) candidates=\(events.count))",
                    level: .debug
                )
            }
        } catch {
            await logger.log(
                "Health proactive evaluation failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    /// Process all pending health LLM jobs (BGProcessingTask or foreground).
    func processPendingJobs() async {
        let pending = await chatMessageStore.loadPendingHealthJobs()
        guard !pending.isEmpty else { return }

        await logger.log("Processing \(pending.count) pending health LLM job(s)", level: .debug)

        // Same reasoning as ConversationManager's accumulated-batch path:
        // this can now run its LLM call(s) directly from a background wake
        // (see processImmediately in SystemEventCoordinator), so it needs
        // the same protection against getting cut off mid-request.
        let backgroundTask = await BackgroundTaskAssertion()
        await backgroundTask.begin(name: "healthProactiveJobs")

        for job in pending {
            await processJob(job)
        }

        await backgroundTask.end()
    }

    private func processJob(
        _ job: PendingHealthLLMJobSnapshot
    ) async {
        if await chatMessageStore.hasAlertRecord(dedupKey: job.dedupKey) {
            await logger.log(
                "Health job already delivered (dedup): \(job.eventType.rawValue) key=\(job.dedupKey)",
                level: .debug
            )
            _ = try? await chatMessageStore.updateHealthJobStatus(id: job.id, status: .delivered)
            return
        }

        guard await ConversationIdleChecker.isIdle(
            chatMessageStore: chatMessageStore
        ) else {
            await logger.log(
                "Deferring health job \(job.eventType.rawValue) key=\(job.dedupKey): not idle",
                level: .debug
            )
            return
        }

        do {
            _ = try await chatMessageStore.updateHealthJobStatus(id: job.id, status: .generating)
        } catch {
            await logger.log(
                "Health job mark generating failed id=\(job.id): \(error.localizedDescription)",
                level: .error
            )
            return
        }
        await logger.log(
            "Health job generating: \(job.eventType.rawValue) key=\(job.dedupKey) retry=\(job.retryCount)",
            level: .debug
        )

        let event = job.toCompanionEvent()
        let character = await profileService.characterName()
        guard let rawContent = await llmGenerationService.generateMessage(
            for: event
        ) else {
            // No template fallback — skip sending anything. Treat it like any
            // other delivery failure: retry a few times (in case it was a
            // transient network/timeout issue), then give up.
            if let updated = try? await chatMessageStore.recordHealthJobFailure(id: job.id) {
                await logger.log(
                    "Health LLM generation failed for \(event.type.rawValue) key=\(job.dedupKey), status=\(updated.status.rawValue) retry=\(updated.retryCount)",
                    level: .warning
                )
            } else {
                await logger.log(
                    "Health LLM generation failed for \(event.type.rawValue) key=\(job.dedupKey); could not record failure",
                    level: .warning
                )
            }
            return
        }

        // Shared with chat / delayed / greeting: plan JSON multi-message
        // payloads into paced bubbles instead of rendering one flattened string.
        do {
            let result = try await AssistantMessageDelivery.deliver(
                content: rawContent,
                chatMessageStore: chatMessageStore,
                notificationService: notificationService,
                options: .init(
                    characterName: character,
                    conversationId: job.conversationId,
                    eventType: event.type,
                    extraMetadata: [
                        "eventType": event.type.rawValue,
                        "source": "health_proactive"
                    ]
                ),
                onSegmentInserted: { [weak self] _, _, _ in
                    await self?.onMessageInserted?()
                }
            )

            guard result.completed, let firstMessageId = result.messageIds.first else {
                if let updated = try? await chatMessageStore.recordHealthJobFailure(id: job.id) {
                    await logger.log(
                        "Health proactive delivery produced no segments for \(event.type.rawValue) status=\(updated.status.rawValue) retry=\(updated.retryCount)",
                        level: .warning
                    )
                } else {
                    await logger.log(
                        "Health proactive delivery produced no segments for \(event.type.rawValue)",
                        level: .warning
                    )
                }
                return
            }

            // PR2f: alert dedup row owned by store (same context as chat/job).
            do {
                _ = try await chatMessageStore.insertHealthAlertRecord(
                    HealthAlertRecordDraft(
                        dedupKey: job.dedupKey,
                        eventType: event.type,
                        alertDate: Calendar.current.startOfDay(for: Date()),
                        messageId: firstMessageId,
                        usedLLM: true
                    )
                )
            } catch {
                await logger.log(
                    "Health alert record insert failed key=\(job.dedupKey): \(error.localizedDescription)",
                    level: .error
                )
                // Still mark job delivered — message already landed; retrying
                // would risk a second send if dedup insert later succeeds.
            }

            _ = try await chatMessageStore.updateHealthJobStatus(id: job.id, status: .delivered)

            governor.recordSend(NotificationIntent.fromHealthEvent(event))

            // PR2a: snapshot state via store (same context as assistant insert).
            // insertAssistantSegment already advanced lastAssistantMessageAt;
            // this sets .reactive + sticky conversation id without clobbering
            // lastUserMessageAt from a separate ModelContext.
            await chatMessageStore.markHealthProactiveDelivered(
                conversationId: job.conversationId
            )

            await logger.log(
                "Delivered health proactive message: \(event.type.rawValue) segments=\(result.segmentCount)",
                level: .info
            )
        } catch {
            if let updated = try? await chatMessageStore.recordHealthJobFailure(id: job.id) {
                await logger.log(
                    "Health job delivery failed (retry \(updated.retryCount)): \(error.localizedDescription)",
                    level: .error
                )
            } else {
                await logger.log(
                    "Health job delivery failed: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

}
