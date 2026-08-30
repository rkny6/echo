import Foundation
import SwiftData

enum ChatMessageStoreError: LocalizedError, Sendable {
    case messageNotFound(UUID)
    case invalidResendTarget(UUID)
    case pendingResponseNotFound(UUID)
    case healthJobNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .messageNotFound(let id):
            return "消息不存在：\(id.uuidString)"
        case .invalidResendTarget(let id):
            return "无法重发非用户消息：\(id.uuidString)"
        case .pendingResponseNotFound(let id):
            return "待发送回复不存在：\(id.uuidString)"
        case .healthJobNotFound(let id):
            return "健康主动任务不存在：\(id.uuidString)"
        }
    }
}

/// Single owner for `ChatMessage` persistence and `ConversationSnapshot` writes.
///
/// PR1a/b: user + assistant chat rows go through here.
/// PR2a: conversation state / silence timestamps / sticky id also go through
/// this actor so CM / Health / IdleChecker do not clobber each other via
/// separate `ModelContext` instances.
/// PR2b/c: PendingResponse / PendingHealthLLMJob read gates + pending list/count.
/// PR2d: PendingResponse durable writes also go through here; DRM keeps
/// delivery orchestration only (tasks / live-owned / online gate / notifications).
/// PR2e: PendingHealthLLMJob durable writes also go through here.
/// PR2f: HealthAlertRecord durable reads/writes also go through here;
/// HealthProactiveDeliveryService keeps detection / LLM / delivery orchestration
/// and still uses a caller `ModelContext` for Character/User profile reads only.
/// Callers must not create their own `ModelContext` writes for `ChatMessage`,
/// production `ConversationSnapshot`, production `PendingResponse`,
/// production `PendingHealthLLMJob`, or production `HealthAlertRecord` mutations.
actor ChatMessageStore {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let logger: LoggingProviding?

    private var changeContinuations: [UUID: AsyncStream<ChatHistoryChange>.Continuation] = [:]

    init(modelContainer: ModelContainer, logger: LoggingProviding? = nil) {
        self.modelContainer = modelContainer
        self.logger = logger
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContext = context
    }

    /// Fan-out stream of durable chat changes (UI should merge on MainActor).
    nonisolated var changes: AsyncStream<ChatHistoryChange> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerChangeContinuation(id: id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregisterChangeContinuation(id: id) }
            }
        }
    }

    // MARK: - User writes

    @discardableResult
    func insertUser(_ draft: UserMessageDraft) async throws -> ChatMessageSnapshot {
        let message = ChatMessage(
            id: draft.id,
            role: .user,
            content: draft.content,
            timestamp: draft.timestamp,
            conversationId: draft.conversationId,
            metadata: draft.metadata,
            isRead: draft.isRead,
            imageData: draft.imageData,
            imageMimeType: draft.imageMimeType,
            status: draft.status
        )
        modelContext.insert(message)
        try modelContext.save()

        if let conversationId = draft.conversationId {
            await ConversationSnapshotStore.updateAfterUserMessage(
                at: draft.timestamp,
                conversationId: conversationId,
                modelContext: modelContext,
                logger: logger
            )
        }

        let snapshot = ChatMessageSnapshot(from: message)
        broadcast(.upserted([snapshot]))
        await logDebug("ChatStore insertUser id=\(snapshot.id) status=\(snapshot.status.rawValue)")
        return snapshot
    }

    @discardableResult
    func updateUser(
        id: UUID,
        status: MessageDeliveryStatus? = nil,
        isFailed: Bool? = nil,
        errorMessage: String?? = nil,
        metadata: [String: String]? = nil,
        content: String? = nil,
        conversationId: UUID? = nil
    ) async throws -> ChatMessageSnapshot {
        let message = try fetchModel(id: id)
        guard message.role == .user else {
            throw ChatMessageStoreError.invalidResendTarget(id)
        }
        if let status { message.status = status }
        if let isFailed { message.isFailed = isFailed }
        if let errorMessage { message.errorMessage = errorMessage }
        if let metadata { message.metadata = metadata }
        if let content { message.content = content }
        if let conversationId { message.conversationId = conversationId }
        try modelContext.save()

        let snapshot = ChatMessageSnapshot(from: message)
        broadcast(.upserted([snapshot]))
        return snapshot
    }

    /// Prepare an existing user bubble for resend (clear failure, set status).
    @discardableResult
    func prepareUserResend(
        id: UUID,
        status: MessageDeliveryStatus,
        conversationId: UUID?
    ) async throws -> ChatMessageSnapshot {
        let message = try fetchModel(id: id)
        guard message.role == .user else {
            throw ChatMessageStoreError.invalidResendTarget(id)
        }
        message.isFailed = false
        message.errorMessage = nil
        message.status = status
        if let conversationId {
            message.conversationId = conversationId
        }
        try modelContext.save()
        let snapshot = ChatMessageSnapshot(from: message)
        broadcast(.upserted([snapshot]))
        return snapshot
    }

    func markSendingUserMessagesCompleted(conversationId: UUID) async throws {
        let candidates = try fetchUserModels(status: .sending).filter {
            $0.conversationId == conversationId
        }
        guard !candidates.isEmpty else { return }
        for message in candidates {
            message.status = .completed
            message.isFailed = false
            message.errorMessage = nil
        }
        try modelContext.save()
        broadcast(.upserted(candidates.map(ChatMessageSnapshot.init(from:))))
    }

    func markUserMessagesFailed(
        conversationId: UUID,
        since batchStart: Date,
        errorMessage: String
    ) async throws {
        let recent = try fetchRecentModels(limit: 100)
        let userMessages = recent.filter {
            $0.role == .user
                && $0.conversationId == conversationId
                && $0.timestamp >= batchStart
        }
        guard !userMessages.isEmpty else { return }
        for message in userMessages {
            message.isFailed = true
            message.status = .failed
            message.errorMessage = errorMessage
        }
        try modelContext.save()
        broadcast(.upserted(userMessages.map(ChatMessageSnapshot.init(from:))))
    }

    func failRecognizingUserMessages(
        errorMessage: String = "图片识别中断，请重试"
    ) async throws -> Int {
        let stuck = try fetchUserModels(status: .recognizing)
        guard !stuck.isEmpty else { return 0 }
        for message in stuck {
            message.status = .failed
            message.isFailed = true
            message.errorMessage = message.errorMessage ?? errorMessage
        }
        try modelContext.save()
        broadcast(.upserted(stuck.map(ChatMessageSnapshot.init(from:))))
        return stuck.count
    }

    // MARK: - Assistant write (used by AssistantMessageDelivery for every scheduled reply)

    @discardableResult
    func insertAssistantSegment(_ draft: AssistantSegmentDraft) async throws -> ChatMessageSnapshot {
        let message = ChatMessage(
            id: draft.id,
            role: .assistant,
            content: draft.content,
            timestamp: draft.timestamp,
            eventType: draft.eventType,
            conversationId: draft.conversationId,
            metadata: draft.metadata,
            isRead: draft.isRead,
            status: .completed
        )
        modelContext.insert(message)
        try modelContext.save()
        await ConversationSnapshotStore.updateAfterAssistantMessage(
            at: draft.timestamp,
            modelContext: modelContext,
            logger: logger
        )
        let snapshot = ChatMessageSnapshot(from: message)
        broadcast(.upserted([snapshot]))
        return snapshot
    }

    // MARK: - Read / delete

    func fetchById(_ id: UUID) async throws -> ChatMessageSnapshot? {
        try fetchModelIfPresent(id: id).map(ChatMessageSnapshot.init(from:))
    }

    /// Newest page, ordered oldest → newest (UI chat window order).
    func fetchRecent(limit: Int) async throws -> [ChatMessageSnapshot] {
        try fetchRecentModels(limit: limit).map(ChatMessageSnapshot.init(from:))
    }

    /// All rows at/after `timestamp`, ordered oldest → newest.
    func fetchFrom(timestamp: Date) async throws -> [ChatMessageSnapshot] {
        let predicate = #Predicate<ChatMessage> { $0.timestamp >= timestamp }
        let request = FetchDescriptor<ChatMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .forward)]
        )
        return try modelContext.fetch(request).map(ChatMessageSnapshot.init(from:))
    }

    /// Rows in `[start, end)`, ordered oldest → newest.
    func fetchInRange(from start: Date, to end: Date) async throws -> [ChatMessageSnapshot] {
        let predicate = #Predicate<ChatMessage> {
            $0.timestamp >= start && $0.timestamp < end
        }
        let request = FetchDescriptor<ChatMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .forward)]
        )
        return try modelContext.fetch(request).map(ChatMessageSnapshot.init(from:))
    }

    /// Older page strictly before `timestamp`, ordered oldest → newest.
    func fetchBefore(timestamp: Date, limit: Int) async throws -> [ChatMessageSnapshot] {
        var request = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { $0.timestamp < timestamp },
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .reverse)]
        )
        request.fetchLimit = max(limit, 0)
        return try modelContext.fetch(request).reversed().map(ChatMessageSnapshot.init(from:))
    }

    func fetchUserMessages(status: MessageDeliveryStatus) async throws -> [ChatMessageSnapshot] {
        try fetchUserModels(status: status).map(ChatMessageSnapshot.init(from:))
    }

    func hasAssistantReply(after timestamp: Date, conversationId: UUID) async throws -> Bool {
        var request = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .reverse)]
        )
        request.fetchLimit = 80
        let messages = try modelContext.fetch(request)
        return messages.contains {
            $0.role == .assistant
                && $0.conversationId == conversationId
                && $0.timestamp > timestamp
        }
    }

    /// Recent unread assistant bubbles used by idle checks.
    func hasRecentUnreadAssistant(since cutoff: Date) async throws -> Bool {
        var request = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .reverse)]
        )
        request.fetchLimit = 40
        let messages = try modelContext.fetch(request)
        return messages.contains {
            $0.role == .assistant && !$0.isRead && $0.timestamp >= cutoff
        }
    }

    @discardableResult
    func setRead(ids: Set<UUID>, isRead: Bool) async throws -> [ChatMessageSnapshot] {
        guard !ids.isEmpty else { return [] }
        let predicate = #Predicate<ChatMessage> { ids.contains($0.id) }
        let messages = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        guard !messages.isEmpty else { return [] }
        for message in messages {
            message.isRead = isRead
        }
        try modelContext.save()
        let snapshots = messages.map(ChatMessageSnapshot.init(from:))
        broadcast(.upserted(snapshots))
        return snapshots
    }

    @discardableResult
    func delete(ids: Set<UUID>) async throws -> ChatMessageDeleteResult {
        guard !ids.isEmpty else {
            return ChatMessageDeleteResult(deletedIDs: [], affectedConversationIds: [])
        }
        let predicate = #Predicate<ChatMessage> { ids.contains($0.id) }
        let messages = try modelContext.fetch(FetchDescriptor(predicate: predicate))
        let affected = Set(messages.compactMap(\.conversationId))
        let deleted = Set(messages.map(\.id))
        for message in messages {
            modelContext.delete(message)
        }
        try modelContext.save()
        await recomputeSnapshotFromHistoryLocked()
        if !deleted.isEmpty {
            broadcast(.deleted(deleted))
        }
        await logDebug("ChatStore delete count=\(deleted.count) conversations=\(affected.count)")
        return ChatMessageDeleteResult(deletedIDs: deleted, affectedConversationIds: affected)
    }

    /// Realign silence timestamps + sticky conversation id with remaining chat rows.
    func recomputeSnapshotFromHistory() async {
        await recomputeSnapshotFromHistoryLocked()
    }

    /// Stable conversation id for inserts / proactive paths.
    /// Prefers snapshot sticky id → newest history conversationId → new sticky UUID.
    func resolveConversationId() async -> UUID {
        let snapshot = await ConversationSnapshotStore.load(from: modelContext, logger: logger)
        if let id = snapshot.currentConversationId {
            return id
        }

        if let fromHistory = latestConversationIdFromHistory() {
            await ConversationSnapshotStore.updateCurrentConversationId(fromHistory, modelContext: modelContext, logger: logger)
            return fromHistory
        }

        let sticky = UUID()
        await ConversationSnapshotStore.updateCurrentConversationId(sticky, modelContext: modelContext, logger: logger)
        return sticky
    }

    // MARK: - ConversationSnapshot (PR2a sole owner)

    /// Read-only snapshot for idle / gap / governor gates.
    func loadConversationSnapshot() async -> ConversationSnapshotData {
        ConversationSnapshotData(from: await ConversationSnapshotStore.load(from: modelContext, logger: logger))
    }

    /// Last user message timestamp used by silence / health governor gates.
    func lastUserMessageAt() async -> Date? {
        await ConversationSnapshotStore.load(from: modelContext, logger: logger).lastUserMessageAt
    }

    /// Persist orchestration state without wiping silence timestamps.
    ///
    /// When `currentConversationId` is `nil` (e.g. CM went idle), keep the
    /// existing sticky id so health / delayed recovery do not mint a new UUID.
    func persistConversationState(
        conversationState: ConversationState,
        currentConversationId: UUID?
    ) async {
        let existing = await ConversationSnapshotStore.load(from: modelContext, logger: logger)
        let conversationIdToPersist = currentConversationId ?? existing.currentConversationId
        await ConversationSnapshotStore.save(
            conversationState: conversationState,
            lastUserMessageAt: existing.lastUserMessageAt,
            lastAssistantMessageAt: existing.lastAssistantMessageAt,
            currentConversationId: conversationIdToPersist,
            modelContext: modelContext,
            logger: logger
        )
        await logDebug(
            "ChatStore persistConversationState state=\(conversationState.rawValue) sticky=\(conversationIdToPersist?.uuidString ?? "nil")"
        )
    }

    /// Assistant bubble landed (CM live path / delayed path side effect).
    func touchSnapshotAfterAssistant(at date: Date) async {
        await ConversationSnapshotStore.updateAfterAssistantMessage(at: date, modelContext: modelContext, logger: logger)
    }

    /// Health proactive finished delivering: mark reactive + assistant time + sticky id.
    /// Preserves `lastUserMessageAt` so silence gates stay accurate.
    func markHealthProactiveDelivered(
        at date: Date = Date(),
        conversationId: UUID
    ) async {
        let existing = await ConversationSnapshotStore.load(from: modelContext, logger: logger)
        await ConversationSnapshotStore.save(
            conversationState: .reactive,
            lastUserMessageAt: existing.lastUserMessageAt,
            lastAssistantMessageAt: date,
            currentConversationId: conversationId,
            modelContext: modelContext,
            logger: logger
        )
        await logDebug(
            "ChatStore markHealthProactiveDelivered conversation=\(conversationId)"
        )
    }

    // MARK: - PendingResponse reads (PR2b + PR2c)

    /// True when any delayed assistant reply is still `.pending`.
    /// Fetch errors fail open (`false`) to match prior IdleChecker behavior.
    func hasPendingDelayedResponses() async -> Bool {
        pendingDelayedResponses().isEmpty == false
    }

    /// True when a delayed reply is already parked for this conversation
    /// (offline hold / delayed delivery). Resume must not re-call the LLM.
    /// Fetch errors fail open (`false`).
    func hasPendingDelayedResponses(for conversationId: UUID) async -> Bool {
        pendingDelayedResponses().contains { $0.conversationId == conversationId }
    }

    /// Count of rows still `.pending`. Fetch errors fail open (`0`).
    func pendingDelayedResponseCount() async -> Int {
        pendingDelayedResponses().count
    }

    /// Debug / inspection list of still-`.pending` delayed replies.
    /// Fetch errors fail open (`[]`). Ordered by `createdAt` ascending.
    func loadPendingDelayedResponses() async -> [PendingResponseSnapshot] {
        pendingDelayedResponses()
            .map(PendingResponseSnapshot.init(from:))
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Load one pending row by id (any status). Missing → `nil`.
    func loadPendingResponse(id: UUID) async -> PendingResponseSnapshot? {
        guard let model = try? fetchPendingModel(id: id) else { return nil }
        return PendingResponseSnapshot(from: model)
    }

    // MARK: - PendingResponse writes (PR2d)

    @discardableResult
    func insertPendingResponse(_ draft: PendingResponseDraft) async throws -> PendingResponseSnapshot {
        let response = PendingResponse(
            id: draft.id,
            content: draft.content,
            createdAt: draft.createdAt,
            scheduledDeliveryTime: draft.scheduledDeliveryTime,
            conversationId: draft.conversationId,
            eventType: draft.eventType,
            status: draft.status
        )
        modelContext.insert(response)
        try modelContext.save()
        await logDebug(
            "ChatStore insertPendingResponse id=\(response.id) conversation=\(response.conversationId)"
        )
        return PendingResponseSnapshot(from: response)
    }

    /// Update status. When `onlyIfPending`, no-ops (returns nil) if missing or not pending.
    @discardableResult
    func updatePendingResponseStatus(
        id: UUID,
        status: PendingResponseStatus,
        onlyIfPending: Bool = true
    ) async throws -> PendingResponseSnapshot? {
        guard let response = try fetchPendingModel(id: id) else {
            if onlyIfPending { return nil }
            throw ChatMessageStoreError.pendingResponseNotFound(id)
        }
        if onlyIfPending, response.status != .pending {
            return nil
        }
        response.status = status
        try modelContext.save()
        await logDebug(
            "ChatStore updatePendingResponseStatus id=\(id) status=\(status.rawValue)"
        )
        return PendingResponseSnapshot(from: response)
    }

    /// Update scheduled delivery time. When `onlyIfPending`, no-ops if missing/not pending.
    @discardableResult
    func updatePendingResponseSchedule(
        id: UUID,
        scheduledDeliveryTime: Date,
        onlyIfPending: Bool = true
    ) async throws -> PendingResponseSnapshot? {
        guard let response = try fetchPendingModel(id: id) else {
            if onlyIfPending { return nil }
            throw ChatMessageStoreError.pendingResponseNotFound(id)
        }
        if onlyIfPending, response.status != .pending {
            return nil
        }
        response.scheduledDeliveryTime = scheduledDeliveryTime
        try modelContext.save()
        await logDebug(
            "ChatStore updatePendingResponseSchedule id=\(id)"
        )
        return PendingResponseSnapshot(from: response)
    }

    /// Cancel every still-`.pending` row. Returns cancelled ids (for task/notif cleanup).
    @discardableResult
    func cancelAllPendingResponses() async throws -> [UUID] {
        let pending = pendingDelayedResponses()
        guard !pending.isEmpty else { return [] }
        let ids = pending.map(\.id)
        for response in pending {
            response.status = .cancelled
        }
        try modelContext.save()
        await logDebug("ChatStore cancelAllPendingResponses count=\(ids.count)")
        return ids
    }

    /// Cancel still-`.pending` rows for the given conversations. Empty set → `[]`.
    @discardableResult
    func cancelPendingResponses(for conversationIds: Set<UUID>) async throws -> [UUID] {
        guard !conversationIds.isEmpty else { return [] }
        let pending = pendingDelayedResponses().filter { conversationIds.contains($0.conversationId) }
        guard !pending.isEmpty else { return [] }
        let ids = pending.map(\.id)
        for response in pending {
            response.status = .cancelled
        }
        try modelContext.save()
        await logDebug(
            "ChatStore cancelPendingResponses conversations=\(conversationIds.count) cancelled=\(ids.count)"
        )
        return ids
    }

    // MARK: - PendingHealthLLMJob reads (PR2b + PR2e)

    /// True when a health LLM job is mid-generation (blocks stacking proactive).
    /// Fetch errors fail open (`false`) to match prior IdleChecker behavior.
    func hasGeneratingHealthJobs() async -> Bool {
        activeHealthJobs().contains { $0.status == .generating }
    }

    /// True when any health job is `.pending` or `.generating`.
    /// Fetch errors fail open (`false`).
    func hasAnyActiveHealthJob() async -> Bool {
        activeHealthJobs().isEmpty == false
    }

    /// True when a still-active job already owns this dedup key.
    /// Fetch errors fail open (`false`).
    func hasActiveHealthJob(dedupKey: String) async -> Bool {
        activeHealthJobs().contains { $0.dedupKey == dedupKey }
    }

    /// Load one health job by id (any status). Missing → `nil`.
    func loadHealthJob(id: UUID) async -> PendingHealthLLMJobSnapshot? {
        guard let model = try? fetchHealthJobModel(id: id) else { return nil }
        return PendingHealthLLMJobSnapshot(from: model)
    }

    /// Still-`.pending` jobs, oldest first. Fetch errors fail open (`[]`).
    func loadPendingHealthJobs() async -> [PendingHealthLLMJobSnapshot] {
        guard let all = try? modelContext.fetch(FetchDescriptor<PendingHealthLLMJob>()) else {
            return []
        }
        return all
            .filter { $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
            .map(PendingHealthLLMJobSnapshot.init(from:))
    }

    // MARK: - PendingHealthLLMJob writes (PR2e)

    @discardableResult
    func insertHealthJob(_ draft: PendingHealthLLMJobDraft) async throws -> PendingHealthLLMJobSnapshot {
        let job = PendingHealthLLMJob(
            id: draft.id,
            eventType: draft.eventType,
            metadata: draft.metadata,
            status: draft.status,
            dedupKey: draft.dedupKey,
            createdAt: draft.createdAt,
            retryCount: draft.retryCount,
            conversationId: draft.conversationId
        )
        modelContext.insert(job)
        try modelContext.save()
        await logDebug(
            "ChatStore insertHealthJob id=\(job.id) type=\(job.eventTypeRaw) key=\(job.dedupKey)"
        )
        return PendingHealthLLMJobSnapshot(from: job)
    }

    /// Update status only. Missing → throws `healthJobNotFound`.
    @discardableResult
    func updateHealthJobStatus(
        id: UUID,
        status: PendingHealthLLMJobStatus
    ) async throws -> PendingHealthLLMJobSnapshot {
        guard let job = try fetchHealthJobModel(id: id) else {
            throw ChatMessageStoreError.healthJobNotFound(id)
        }
        job.status = status
        try modelContext.save()
        await logDebug(
            "ChatStore updateHealthJobStatus id=\(id) status=\(status.rawValue)"
        )
        return PendingHealthLLMJobSnapshot(from: job)
    }

    /// Bump `retryCount` by 1 and set status to `.failed` once retries are
    /// exhausted, otherwise back to `.pending` for another attempt.
    @discardableResult
    func recordHealthJobFailure(
        id: UUID,
        maxRetries: Int = HealthProactiveThresholds.maxLLMRetries
    ) async throws -> PendingHealthLLMJobSnapshot {
        guard let job = try fetchHealthJobModel(id: id) else {
            throw ChatMessageStoreError.healthJobNotFound(id)
        }
        job.retryCount += 1
        job.status = job.retryCount >= maxRetries ? .failed : .pending
        try modelContext.save()
        await logDebug(
            "ChatStore recordHealthJobFailure id=\(id) status=\(job.status.rawValue) retry=\(job.retryCount)"
        )
        return PendingHealthLLMJobSnapshot(from: job)
    }

    // MARK: - HealthAlertRecord reads / writes (PR2f)

    /// True when any health alert was delivered today (`sentAt` or `alertDate`
    /// on/after local day start). Fetch errors fail open (`false`).
    func hasHealthAlertDeliveredToday(now: Date = Date()) async -> Bool {
        let dayStart = Calendar.current.startOfDay(for: now)
        guard let records = try? modelContext.fetch(FetchDescriptor<HealthAlertRecord>()) else {
            return false
        }
        return records.contains { $0.sentAt >= dayStart || $0.alertDate >= dayStart }
    }

    /// True when a dedup key already has an alert row. Fetch errors fail open (`false`).
    func hasAlertRecord(dedupKey: String) async -> Bool {
        let predicate = #Predicate<HealthAlertRecord> { $0.dedupKey == dedupKey }
        let descriptor = FetchDescriptor<HealthAlertRecord>(predicate: predicate)
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Load one alert by dedup key. Missing / fetch error → `nil`.
    func loadHealthAlertRecord(dedupKey: String) async -> HealthAlertRecordSnapshot? {
        let predicate = #Predicate<HealthAlertRecord> { $0.dedupKey == dedupKey }
        guard let record = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else {
            return nil
        }
        return HealthAlertRecordSnapshot(from: record)
    }

    @discardableResult
    func insertHealthAlertRecord(
        _ draft: HealthAlertRecordDraft
    ) async throws -> HealthAlertRecordSnapshot {
        let record = HealthAlertRecord(
            dedupKey: draft.dedupKey,
            eventType: draft.eventType,
            alertDate: draft.alertDate,
            sentAt: draft.sentAt,
            messageId: draft.messageId,
            usedLLM: draft.usedLLM
        )
        modelContext.insert(record)
        try modelContext.save()
        await logDebug(
            "ChatStore insertHealthAlertRecord key=\(record.dedupKey) type=\(record.eventTypeRaw) messageId=\(record.messageId)"
        )
        return HealthAlertRecordSnapshot(from: record)
    }

    // MARK: - Private

    /// Live pending rows on this actor's context. Fail open to `[]` on fetch error.
    private func pendingDelayedResponses() -> [PendingResponse] {
        guard let all = try? modelContext.fetch(FetchDescriptor<PendingResponse>()) else {
            return []
        }
        return all.filter { $0.status == .pending }
    }

    private func fetchPendingModel(id: UUID) throws -> PendingResponse? {
        let predicate = #Predicate<PendingResponse> { $0.id == id }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    /// Active = pending or generating. Fail open to `[]` on fetch error.
    private func activeHealthJobs() -> [PendingHealthLLMJob] {
        guard let all = try? modelContext.fetch(FetchDescriptor<PendingHealthLLMJob>()) else {
            return []
        }
        return all.filter { $0.status == .pending || $0.status == .generating }
    }

    private func fetchHealthJobModel(id: UUID) throws -> PendingHealthLLMJob? {
        let predicate = #Predicate<PendingHealthLLMJob> { $0.id == id }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    private func registerChangeContinuation(
        id: UUID,
        _ continuation: AsyncStream<ChatHistoryChange>.Continuation
    ) {
        changeContinuations[id] = continuation
    }

    private func unregisterChangeContinuation(id: UUID) {
        changeContinuations[id] = nil
    }

    private func broadcast(_ change: ChatHistoryChange) {
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    private func fetchModel(id: UUID) throws -> ChatMessage {
        if let message = try fetchModelIfPresent(id: id) {
            return message
        }
        throw ChatMessageStoreError.messageNotFound(id)
    }

    private func fetchModelIfPresent(id: UUID) throws -> ChatMessage? {
        let predicate = #Predicate<ChatMessage> { $0.id == id }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    private func fetchRecentModels(limit: Int) throws -> [ChatMessage] {
        var request = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .reverse)]
        )
        request.fetchLimit = max(limit, 0)
        return Array(try modelContext.fetch(request).reversed())
    }

    private func fetchUserModels(status: MessageDeliveryStatus) throws -> [ChatMessage] {
        let statusRaw = status.rawValue
        var request = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.statusRaw == statusRaw },
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .forward)]
        )
        request.fetchLimit = 200
        return try modelContext.fetch(request).filter { $0.role == .user }
    }

    /// Newest non-nil conversation id among recent rows (newest first scan).
    private func latestConversationIdFromHistory() -> UUID? {
        var request = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .reverse)]
        )
        request.fetchLimit = 20
        guard let messages = try? modelContext.fetch(request) else { return nil }
        return messages.compactMap(\.conversationId).first
    }

    /// After deletes (or explicit recompute), realign snapshot bookkeeping only.
    private func recomputeSnapshotFromHistoryLocked() async {
        let request = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\ChatMessage.timestamp, order: .forward)]
        )
        let messages = (try? modelContext.fetch(request)) ?? []

        let lastUserMessageAt = messages.last(where: { $0.role == .user })?.timestamp
        let lastAssistantMessageAt = messages.last(where: { $0.role == .assistant })?.timestamp

        let snapshot = await ConversationSnapshotStore.load(from: modelContext, logger: logger)
        var currentConversationId = snapshot.currentConversationId

        if let currentId = currentConversationId {
            let stillHasThread = messages.contains { $0.conversationId == currentId }
            if !stillHasThread {
                // Prefer newest remaining thread; keep sticky if history is empty.
                if let newestConversationId = messages
                    .reversed()
                    .compactMap(\.conversationId)
                    .first
                {
                    currentConversationId = newestConversationId
                }
            }
        } else if let newestConversationId = messages
            .reversed()
            .compactMap(\.conversationId)
            .first
        {
            currentConversationId = newestConversationId
        }

        await ConversationSnapshotStore.applyHistoryBookkeeping(
            lastUserMessageAt: lastUserMessageAt,
            lastAssistantMessageAt: lastAssistantMessageAt,
            currentConversationId: currentConversationId,
            modelContext: modelContext,
            logger: logger
        )
    }

    private func logDebug(_ message: String) async {
        await logger?.log(message, level: .debug)
    }
}
