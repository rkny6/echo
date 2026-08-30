import Foundation

struct AccumulatedMessage: Sendable {
    let content: String
    let timestamp: Date
}

struct AccumulatedMessageBatch: Sendable {
    let conversationId: UUID
    let messages: [AccumulatedMessage]
    let createdAt: Date
}

actor MessageBatcher {
    private let logger: LoggingProviding
    private let onCompleted: @Sendable (AccumulatedMessageBatch) async -> Void
    private let onWaitingStateChange: (@Sendable (Bool) async -> Void)?

    private let debounceInterval: TimeInterval
    private let readingIndicatorThreshold: TimeInterval
    private let idleResetThreshold: TimeInterval
    private let maxBatchCharacters: Int

    private var conversationId: UUID?
    private var messages: [AccumulatedMessage] = []
    private var accumulationStart: Date?
    private var lastAppendTimestamp: Date?
    private var debounceTask: Task<Void, Never>?
    private var readingIndicatorTask: Task<Void, Never>?
    private var isReadingIndicatorVisible = false

    init(
        debounceInterval: TimeInterval = 2.5,
        readingIndicatorThreshold: TimeInterval = 2.0,
        idleResetThreshold: TimeInterval = 30.0,
        maxBatchCharacters: Int = 500,
        logger: LoggingProviding,
        onCompleted: @escaping @Sendable (AccumulatedMessageBatch) async -> Void,
        onWaitingStateChange: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.debounceInterval = debounceInterval
        self.readingIndicatorThreshold = readingIndicatorThreshold
        self.idleResetThreshold = idleResetThreshold
        self.maxBatchCharacters = maxBatchCharacters
        self.logger = logger
        self.onCompleted = onCompleted
        self.onWaitingStateChange = onWaitingStateChange
    }

    func append(
        _ message: String,
        timestamp: Date,
        conversationId: UUID,
        isTyping: Bool = false,
        forceFlushIfUrgent: Bool = false
    ) async {
        let now = Date()

        if self.conversationId != conversationId {
            await resetState()
            self.conversationId = conversationId
        }

        if let lastAppendTimestamp,
           now.timeIntervalSince(lastAppendTimestamp) > idleResetThreshold {
            await resetState()
            self.conversationId = conversationId
        }

        if self.conversationId == nil {
            self.conversationId = conversationId
            accumulationStart = now
        }

        messages.append(AccumulatedMessage(content: message, timestamp: timestamp))
        lastAppendTimestamp = now

        if forceFlushIfUrgent || shouldForceFlush(message: message) || totalCharacterCount() >= maxBatchCharacters {
            await completeAccumulation(reason: "urgent flush")
            return
        }

        if isTyping {
            await cancelScheduledFlush()
            return
        }

        await scheduleFlush()
    }

    func userStartedTyping() async {
        guard debounceTask != nil else { return }
        await cancelScheduledFlush()
    }

    func userStoppedTyping() async {
        // Don't start a flush timer when the batch is empty — typing alone is not a message.
        guard !messages.isEmpty else { return }
        await scheduleFlush()
    }

    func hasPendingMessages() -> Bool {
        !messages.isEmpty
    }

    func cancel() async {
        debounceTask?.cancel()
        debounceTask = nil
        readingIndicatorTask?.cancel()
        readingIndicatorTask = nil
        await setWaitingIndicatorVisible(false)
        await resetState()
    }

    func flush() async {
        await completeAccumulation(reason: "explicit flush")
    }

    func flushPendingBatch() async -> AccumulatedMessageBatch? {
        guard let conversationId, !messages.isEmpty else { return nil }
        debounceTask?.cancel()
        debounceTask = nil
        readingIndicatorTask?.cancel()
        readingIndicatorTask = nil
        await setWaitingIndicatorVisible(false)

        let batch = AccumulatedMessageBatch(
            conversationId: conversationId,
            messages: messages,
            createdAt: Date()
        )

        await resetState()
        return batch
    }

    private func scheduleFlush() async {
        debounceTask?.cancel()
        readingIndicatorTask?.cancel()
        await setWaitingIndicatorVisible(false)

        let sleepDuration = UInt64(debounceInterval * 1_000_000_000)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: sleepDuration)
            guard let self, !Task.isCancelled else { return }
            await self.completeAccumulation(reason: "debounce window")
        }

        await scheduleReadingIndicator()
    }

    private func cancelScheduledFlush() async {
        debounceTask?.cancel()
        debounceTask = nil
        readingIndicatorTask?.cancel()
        readingIndicatorTask = nil
        await setWaitingIndicatorVisible(false)
    }

    private func scheduleReadingIndicator() async {
        readingIndicatorTask?.cancel()
        let indicatorSleepDuration = UInt64(readingIndicatorThreshold * 1_000_000_000)
        readingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: indicatorSleepDuration)
            guard let self, !Task.isCancelled else { return }
            await self.setWaitingIndicatorVisible(true)
        }
    }

    private func setWaitingIndicatorVisible(_ visible: Bool) async {
        guard visible != isReadingIndicatorVisible else { return }
        isReadingIndicatorVisible = visible
        await onWaitingStateChange?(visible)
    }

    private func completeAccumulation(reason: String) async {
        guard let conversationId, !messages.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = nil
        readingIndicatorTask?.cancel()
        readingIndicatorTask = nil

        let batch = AccumulatedMessageBatch(
            conversationId: conversationId,
            messages: messages,
            createdAt: Date()
        )

        await logger.log(
            "Message batching completed after \(reason): \(batch.messages.count) messages",
            level: .debug
        )

        await setWaitingIndicatorVisible(false)

        Task.detached(priority: .userInitiated) { [batch, onCompleted] in
            await onCompleted(batch)
        }

        await resetState()
    }

    private func resetState() async {
        conversationId = nil
        messages.removeAll()
        accumulationStart = nil
        lastAppendTimestamp = nil
        debounceTask?.cancel()
        debounceTask = nil
        readingIndicatorTask?.cancel()
        readingIndicatorTask = nil
    }

    private func totalCharacterCount() -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    private func shouldForceFlush(message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lowered = trimmed.lowercased()
        let urgentKeywords = ["answer me", "urgent", "right now", "please respond", "now"]
        if urgentKeywords.contains(where: lowered.contains) {
            return true
        }

        if trimmed.contains("??") || trimmed.contains("!!") {
            return true
        }

        let punctuationOnly = trimmed.allSatisfy { ".!?".contains($0) }
        if punctuationOnly {
            return true
        }

        return false
    }
}
