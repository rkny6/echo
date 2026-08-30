import Foundation
import SwiftData
import Testing
@testable import echo

struct ChatMessageStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            ChatMessage.self,
            ConversationSnapshot.self,
            PendingResponse.self,
            PendingHealthLLMJob.self,
            HealthAlertRecord.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func insertUserPersistsAndTouchesConversationSnapshot() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()

        let snapshot = try await store.insertUser(
            UserMessageDraft(
                content: "你好",
                conversationId: conversationId,
                isRead: true,
                status: .sending
            )
        )

        #expect(snapshot.role == .user)
        #expect(snapshot.content == "你好")
        #expect(snapshot.status == .sending)
        #expect(snapshot.conversationId == conversationId)

        let recent = try await store.fetchRecent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.id == snapshot.id)

        // Snapshot silence bookkeeping should pick up the user timestamp.
        let sticky = await store.loadConversationSnapshot()
        #expect(sticky.lastUserMessageAt == snapshot.timestamp)
        #expect(sticky.currentConversationId == conversationId)
    }

    @Test func fetchRecentAndFetchBeforeReturnOldestToNewest() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<5 {
            _ = try await store.insertUser(
                UserMessageDraft(
                    content: "m\(i)",
                    timestamp: base.addingTimeInterval(TimeInterval(i)),
                    conversationId: conversationId,
                    isRead: true,
                    status: .completed
                )
            )
        }

        let recent = try await store.fetchRecent(limit: 3)
        #expect(recent.count == 3)
        #expect(recent.map(\.content) == ["m2", "m3", "m4"])
        #expect(recent.first?.timestamp ?? .distantFuture < recent.last?.timestamp ?? .distantPast)

        // Limit must return the newest N rows, still ordered oldest → newest.
        let limited = try await store.fetchRecent(limit: 2)
        #expect(limited.count == 2)
        #expect(limited.map(\.content) == ["m3", "m4"])

        let older = try await store.fetchBefore(
            timestamp: recent.first!.timestamp,
            limit: 10
        )
        #expect(older.map(\.content) == ["m0", "m1"])
        #expect(older.first?.timestamp ?? .distantFuture < older.last?.timestamp ?? .distantPast)

        let from = try await store.fetchFrom(timestamp: recent.first!.timestamp)
        #expect(from.map(\.content) == ["m2", "m3", "m4"])

        let range = try await store.fetchInRange(
            from: base.addingTimeInterval(1),
            to: base.addingTimeInterval(4)
        )
        #expect(range.map(\.content) == ["m1", "m2", "m3"])
        #expect(range.first?.timestamp ?? .distantFuture < range.last?.timestamp ?? .distantPast)
    }

    @Test func hasRecentUnreadAssistantRespectsCutoffAndReadState() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let now = Date()

        _ = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "old unread",
                timestamp: now.addingTimeInterval(-3_600),
                conversationId: conversationId,
                isRead: false
            )
        )
        let recentUnread = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "recent unread",
                timestamp: now.addingTimeInterval(-60),
                conversationId: conversationId,
                isRead: false
            )
        )
        _ = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "recent read",
                timestamp: now.addingTimeInterval(-30),
                conversationId: conversationId,
                isRead: true
            )
        )

        let cutoff = now.addingTimeInterval(-30 * 60)
        #expect(try await store.hasRecentUnreadAssistant(since: cutoff) == true)

        _ = try await store.setRead(ids: Set([recentUnread.id]), isRead: true)
        #expect(try await store.hasRecentUnreadAssistant(since: cutoff) == false)
    }

    @Test func updateUserStatusAndFailRecognizing() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()

        let inserted = try await store.insertUser(
            UserMessageDraft(
                content: "图",
                conversationId: conversationId,
                metadata: ["imageRecognitionDescription": "识别中"],
                status: .recognizing
            )
        )

        let updated = try await store.updateUser(
            id: inserted.id,
            status: .sending,
            metadata: ["imageRecognitionDescription": "一只猫"]
        )
        #expect(updated.status == .sending)
        #expect(updated.imageRecognitionDescription == "一只猫")

        // Leave one stuck in recognizing and fail it.
        _ = try await store.insertUser(
            UserMessageDraft(
                content: "另一张",
                conversationId: conversationId,
                status: .recognizing
            )
        )
        let failedCount = try await store.failRecognizingUserMessages()
        #expect(failedCount == 1)

        let recognizing = try await store.fetchUserMessages(status: .recognizing)
        #expect(recognizing.isEmpty)

        let failed = try await store.fetchUserMessages(status: .failed)
        #expect(failed.count == 1)
        #expect(failed.first?.isFailed == true)
    }

    @Test func markSendingCompletedAndFailedByConversation() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let otherId = UUID()
        let batchStart = Date()

        let first = try await store.insertUser(
            UserMessageDraft(
                content: "a",
                timestamp: batchStart,
                conversationId: conversationId,
                status: .sending
            )
        )
        _ = try await store.insertUser(
            UserMessageDraft(
                content: "b",
                timestamp: batchStart.addingTimeInterval(1),
                conversationId: conversationId,
                status: .sending
            )
        )
        _ = try await store.insertUser(
            UserMessageDraft(
                content: "other",
                timestamp: batchStart.addingTimeInterval(2),
                conversationId: otherId,
                status: .sending
            )
        )

        try await store.markSendingUserMessagesCompleted(conversationId: conversationId)
        let completed = try await store.fetchUserMessages(status: .completed)
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { $0.conversationId == conversationId })

        // Re-mark a message as sending then fail the batch window.
        _ = try await store.prepareUserResend(
            id: first.id,
            status: .sending,
            conversationId: conversationId
        )
        try await store.markUserMessagesFailed(
            conversationId: conversationId,
            since: batchStart,
            errorMessage: "timeout"
        )
        let failed = try await store.fetchById(first.id)
        #expect(failed?.status == .failed)
        #expect(failed?.errorMessage == "timeout")
        #expect(failed?.isFailed == true)
    }

    @Test func resolveConversationIdPrefersStickyThenHistory() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        // Empty history: mint sticky and persist it.
        let first = await store.resolveConversationId()
        let sticky = await store.loadConversationSnapshot()
        #expect(sticky.currentConversationId == first)

        // Clear sticky via store-owned persist, insert history, resolve should
        // pick newest conversation id. (Tests still seed via ConversationSnapshotStore
        // only when wiping fields the public store API intentionally preserves.)
        let context = ModelContext(container)
        await ConversationSnapshotStore.save(
            conversationState: .idle,
            lastUserMessageAt: nil,
            lastAssistantMessageAt: nil,
            currentConversationId: nil,
            modelContext: context,
            logger: nil
        )
        try context.save()

        _ = try await store.insertUser(
            UserMessageDraft(
                content: "old thread",
                timestamp: base,
                conversationId: UUID(),
                status: .completed
            )
        )
        _ = try await store.insertUser(
            UserMessageDraft(
                content: "new thread",
                timestamp: base.addingTimeInterval(10),
                conversationId: conversationId,
                status: .completed
            )
        )

        // Wipe sticky again so resolve must read history (insertUser re-set it).
        let context2 = ModelContext(container)
        await ConversationSnapshotStore.save(
            conversationState: .idle,
            lastUserMessageAt: base.addingTimeInterval(10),
            lastAssistantMessageAt: nil,
            currentConversationId: nil,
            modelContext: context2,
            logger: nil
        )
        try context2.save()

        let resolved = await store.resolveConversationId()
        #expect(resolved == conversationId)
    }

    @Test func deleteRemovesRowsAndRecomputesSnapshot() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()

        let older = try await store.insertUser(
            UserMessageDraft(
                content: "先删我",
                timestamp: Date().addingTimeInterval(-10),
                conversationId: conversationId,
                status: .completed
            )
        )
        let keep = try await store.insertAssistantSegment(
            AssistantSegmentDraft(
                content: "留着我",
                conversationId: conversationId
            )
        )

        let result = try await store.delete(ids: Set([older.id]))
        #expect(result.deletedIDs == Set([older.id]))
        #expect(result.affectedConversationIds.contains(conversationId))

        let remaining = try await store.fetchRecent(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == keep.id)

        let sticky = await store.loadConversationSnapshot()
        #expect(sticky.lastUserMessageAt == nil)
        #expect(sticky.lastAssistantMessageAt == keep.timestamp)
    }

    @Test func persistConversationStatePreservesSilenceAndStickyWhenIdle() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let userAt = Date(timeIntervalSince1970: 1_700_000_200)

        _ = try await store.insertUser(
            UserMessageDraft(
                content: "hi",
                timestamp: userAt,
                conversationId: conversationId,
                status: .completed
            )
        )

        await store.persistConversationState(
            conversationState: .conversing,
            currentConversationId: conversationId
        )
        var snap = await store.loadConversationSnapshot()
        #expect(snap.conversationState == .conversing)
        #expect(snap.currentConversationId == conversationId)
        #expect(snap.lastUserMessageAt == userAt)

        // Idle with nil active id must keep sticky + silence timestamps.
        await store.persistConversationState(
            conversationState: .idle,
            currentConversationId: nil
        )
        snap = await store.loadConversationSnapshot()
        #expect(snap.conversationState == .idle)
        #expect(snap.currentConversationId == conversationId)
        #expect(snap.lastUserMessageAt == userAt)
        #expect(snap.lastAssistantMessageAt == nil)
    }

    @Test func markHealthProactiveDeliveredSetsReactiveWithoutClobberingUser() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let userAt = Date(timeIntervalSince1970: 1_700_000_300)
        let deliverAt = Date(timeIntervalSince1970: 1_700_000_400)

        _ = try await store.insertUser(
            UserMessageDraft(
                content: "hi",
                timestamp: userAt,
                conversationId: conversationId,
                status: .completed
            )
        )
        await store.persistConversationState(
            conversationState: .idle,
            currentConversationId: conversationId
        )

        await store.markHealthProactiveDelivered(
            at: deliverAt,
            conversationId: conversationId
        )

        let snap = await store.loadConversationSnapshot()
        #expect(snap.conversationState == .reactive)
        #expect(snap.lastUserMessageAt == userAt)
        #expect(snap.lastAssistantMessageAt == deliverAt)
        #expect(snap.currentConversationId == conversationId)
    }

    @Test func idlePendingGatesReadThroughStore() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)

        #expect(await store.hasPendingDelayedResponses() == false)
        #expect(await store.hasGeneratingHealthJobs() == false)
        #expect(await store.hasAnyActiveHealthJob() == false)
        #expect(await ConversationIdleChecker.isIdle(chatMessageStore: store) == true)

        // PendingResponse seed via store write path (PR2d).
        _ = try await store.insertPendingResponse(
            PendingResponseDraft(
                content: "later",
                scheduledDeliveryTime: Date().addingTimeInterval(60),
                conversationId: UUID()
            )
        )
        // Health job seed via store write path (PR2e).
        _ = try await store.insertHealthJob(
            PendingHealthLLMJobDraft(
                eventType: .sleep,
                metadata: ["severity": "extreme"],
                status: .generating,
                dedupKey: "test-dedup"
            )
        )

        #expect(await store.hasPendingDelayedResponses() == true)
        #expect(await store.hasGeneratingHealthJobs() == true)
        #expect(await store.hasAnyActiveHealthJob() == true)
        #expect(await ConversationIdleChecker.isIdle(chatMessageStore: store) == false)
    }

    @Test func healthJobCRUDOwnsWrites() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_200_000)

        #expect(await store.loadPendingHealthJobs().isEmpty)
        #expect(await store.hasActiveHealthJob(dedupKey: "sleep-day") == false)

        let pending = try await store.insertHealthJob(
            PendingHealthLLMJobDraft(
                eventType: .sleep,
                metadata: ["severity": "extreme", "reason": "short"],
                status: .pending,
                dedupKey: "sleep-day",
                createdAt: base,
                conversationId: conversationId
            )
        )
        #expect(pending.status == .pending)
        #expect(await store.hasAnyActiveHealthJob() == true)
        #expect(await store.hasActiveHealthJob(dedupKey: "sleep-day") == true)
        #expect(await store.hasGeneratingHealthJobs() == false)
        #expect(await store.loadPendingHealthJobs().map(\.id) == [pending.id])
        #expect(await store.loadHealthJob(id: pending.id)?.dedupKey == "sleep-day")

        let generating = try await store.updateHealthJobStatus(id: pending.id, status: .generating)
        #expect(generating.status == .generating)
        #expect(await store.hasGeneratingHealthJobs() == true)
        #expect(await store.loadPendingHealthJobs().isEmpty)
        #expect(await store.hasActiveHealthJob(dedupKey: "sleep-day") == true)

        // Failure path: bump retry, stay pending until maxRetries.
        let failedOnce = try await store.recordHealthJobFailure(id: pending.id, maxRetries: 3)
        #expect(failedOnce.retryCount == 1)
        #expect(failedOnce.status == .pending)
        #expect(await store.loadPendingHealthJobs().count == 1)

        _ = try await store.updateHealthJobStatus(id: pending.id, status: .generating)
        let failedTwice = try await store.recordHealthJobFailure(id: pending.id, maxRetries: 3)
        #expect(failedTwice.retryCount == 2)
        #expect(failedTwice.status == .pending)

        _ = try await store.updateHealthJobStatus(id: pending.id, status: .generating)
        let exhausted = try await store.recordHealthJobFailure(id: pending.id, maxRetries: 3)
        #expect(exhausted.retryCount == 3)
        #expect(exhausted.status == .failed)
        #expect(await store.hasAnyActiveHealthJob() == false)
        #expect(await store.hasActiveHealthJob(dedupKey: "sleep-day") == false)
        #expect(await store.loadPendingHealthJobs().isEmpty)

        // Delivered path on a fresh job.
        let other = try await store.insertHealthJob(
            PendingHealthLLMJobDraft(
                eventType: .lowSteps,
                metadata: ["severity": "extreme"],
                dedupKey: "steps-day",
                conversationId: conversationId
            )
        )
        let delivered = try await store.updateHealthJobStatus(id: other.id, status: .delivered)
        #expect(delivered.status == .delivered)
        #expect(await store.hasActiveHealthJob(dedupKey: "steps-day") == false)
        #expect(await store.loadHealthJob(id: other.id)?.status == .delivered)
    }

    @Test func healthAlertRecordCRUDOwnsWrites() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let messageId = UUID()
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_300_000))
        let sentAt = day.addingTimeInterval(3_600)

        #expect(await store.hasAlertRecord(dedupKey: "sleep-day") == false)
        #expect(await store.hasHealthAlertDeliveredToday(now: sentAt) == false)
        #expect(await store.loadHealthAlertRecord(dedupKey: "sleep-day") == nil)

        let inserted = try await store.insertHealthAlertRecord(
            HealthAlertRecordDraft(
                dedupKey: "sleep-day",
                eventType: .sleep,
                alertDate: day,
                sentAt: sentAt,
                messageId: messageId,
                usedLLM: true
            )
        )
        #expect(inserted.dedupKey == "sleep-day")
        #expect(inserted.eventType == .sleep)
        #expect(inserted.messageId == messageId)
        #expect(inserted.usedLLM == true)
        #expect(await store.hasAlertRecord(dedupKey: "sleep-day") == true)
        #expect(await store.hasHealthAlertDeliveredToday(now: sentAt) == true)
        #expect(await store.loadHealthAlertRecord(dedupKey: "sleep-day")?.messageId == messageId)

        // Different key still free; "today" remains true once any alert exists.
        #expect(await store.hasAlertRecord(dedupKey: "steps-day") == false)
        #expect(await store.hasHealthAlertDeliveredToday(now: sentAt.addingTimeInterval(60)) == true)

        // Next local day: record is before that day's start → not "today".
        let nextDay = day.addingTimeInterval(86_400)
        #expect(await store.hasHealthAlertDeliveredToday(now: nextDay) == false)
    }

    @Test func pendingDelayedReadsCountAndFilterByConversation() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)

        let keepConversation = UUID()
        let dropConversation = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(await store.pendingDelayedResponseCount() == 0)
        #expect(await store.loadPendingDelayedResponses().isEmpty)
        #expect(await store.hasPendingDelayedResponses(for: keepConversation) == false)

        // Sibling-context seed (DRM-style writer) — store must still read them.
        let seed = ModelContext(container)
        seed.insert(
            PendingResponse(
                content: "keep-a",
                createdAt: base,
                scheduledDeliveryTime: base.addingTimeInterval(60),
                conversationId: keepConversation
            )
        )
        seed.insert(
            PendingResponse(
                content: "keep-b",
                createdAt: base.addingTimeInterval(1),
                scheduledDeliveryTime: base.addingTimeInterval(90),
                conversationId: keepConversation
            )
        )
        seed.insert(
            PendingResponse(
                content: "drop",
                createdAt: base.addingTimeInterval(2),
                scheduledDeliveryTime: base.addingTimeInterval(120),
                conversationId: dropConversation
            )
        )
        // Non-pending must not count.
        seed.insert(
            PendingResponse(
                content: "done",
                createdAt: base.addingTimeInterval(3),
                scheduledDeliveryTime: base.addingTimeInterval(30),
                conversationId: keepConversation,
                status: .delivered
            )
        )
        seed.insert(
            PendingResponse(
                content: "cancelled",
                createdAt: base.addingTimeInterval(4),
                scheduledDeliveryTime: base.addingTimeInterval(30),
                conversationId: dropConversation,
                status: .cancelled
            )
        )
        try seed.save()

        #expect(await store.pendingDelayedResponseCount() == 3)
        #expect(await store.hasPendingDelayedResponses(for: keepConversation) == true)
        #expect(await store.hasPendingDelayedResponses(for: dropConversation) == true)
        #expect(await store.hasPendingDelayedResponses(for: UUID()) == false)

        let listed = await store.loadPendingDelayedResponses()
        #expect(listed.map(\.content) == ["keep-a", "keep-b", "drop"])
        #expect(listed.allSatisfy { $0.status == .pending })
        #expect(Set(listed.map(\.conversationId)) == Set([keepConversation, dropConversation]))
    }

    @Test func pendingResponseCRUDOwnsWrites() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let conversationA = UUID()
        let conversationB = UUID()
        let base = Date(timeIntervalSince1970: 1_700_100_000)

        let a = try await store.insertPendingResponse(
            PendingResponseDraft(
                content: "a",
                createdAt: base,
                scheduledDeliveryTime: base.addingTimeInterval(60),
                conversationId: conversationA
            )
        )
        let b = try await store.insertPendingResponse(
            PendingResponseDraft(
                content: "b",
                createdAt: base.addingTimeInterval(1),
                scheduledDeliveryTime: base.addingTimeInterval(90),
                conversationId: conversationB
            )
        )
        #expect(await store.pendingDelayedResponseCount() == 2)
        #expect(await store.loadPendingResponse(id: a.id)?.content == "a")

        let newTime = base.addingTimeInterval(120)
        let rescheduled = try await store.updatePendingResponseSchedule(
            id: a.id,
            scheduledDeliveryTime: newTime
        )
        #expect(rescheduled?.scheduledDeliveryTime == newTime)

        let delivered = try await store.updatePendingResponseStatus(
            id: a.id,
            status: .delivered
        )
        #expect(delivered?.status == .delivered)
        #expect(await store.hasPendingDelayedResponses(for: conversationA) == false)
        #expect(await store.pendingDelayedResponseCount() == 1)

        // onlyIfPending no-ops once already delivered.
        let noop = try await store.updatePendingResponseStatus(
            id: a.id,
            status: .cancelled,
            onlyIfPending: true
        )
        #expect(noop == nil)
        #expect(await store.loadPendingResponse(id: a.id)?.status == .delivered)

        let cancelledIds = try await store.cancelPendingResponses(for: Set([conversationB]))
        #expect(cancelledIds == [b.id])
        #expect(await store.pendingDelayedResponseCount() == 0)
        #expect(await store.loadPendingResponse(id: b.id)?.status == .cancelled)

        // Re-insert then cancel-all.
        _ = try await store.insertPendingResponse(
            PendingResponseDraft(
                content: "c",
                scheduledDeliveryTime: base.addingTimeInterval(30),
                conversationId: conversationA
            )
        )
        let all = try await store.cancelAllPendingResponses()
        #expect(all.count == 1)
        #expect(await store.pendingDelayedResponseCount() == 0)
    }

    @Test func prepareUserResendRejectsAssistant() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)
        let assistant = try await store.insertAssistantSegment(
            AssistantSegmentDraft(content: "助手")
        )

        await #expect(throws: ChatMessageStoreError.self) {
            try await store.prepareUserResend(
                id: assistant.id,
                status: .sending,
                conversationId: UUID()
            )
        }
    }

    @Test func changesStreamEmitsUpsertAndDelete() async throws {
        let container = try makeContainer()
        let store = ChatMessageStore(modelContainer: container)

        let stream = store.changes
        let collector = Task {
            var events: [ChatHistoryChange] = []
            for await change in stream {
                events.append(change)
                if events.count >= 2 { break }
            }
            return events
        }

        // Give the stream registration a tick.
        try await Task.sleep(nanoseconds: 20_000_000)

        let inserted = try await store.insertUser(
            UserMessageDraft(content: "stream", status: .sending)
        )
        _ = try await store.delete(ids: Set([inserted.id]))

        let events = await collector.value
        #expect(events.count >= 2)
        if case .upserted(let rows) = events[0] {
            #expect(rows.first?.id == inserted.id)
        } else {
            Issue.record("Expected first event to be upserted")
        }
        if case .deleted(let ids) = events[1] {
            #expect(ids.contains(inserted.id))
        } else {
            Issue.record("Expected second event to be deleted")
        }
    }
}
