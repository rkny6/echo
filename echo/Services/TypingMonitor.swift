import Foundation

actor TypingMonitor {
    private let logger: LoggingProviding
    private var isTypingState = false
    private var timeoutTask: Task<Void, Never>?
    private var onTypingStarted: (@Sendable () async -> Void)?
    private var onTypingStopped: (@Sendable () async -> Void)?

    private(set) var lastTypingTimestamp: Date?
    private(set) var typingStartTimestamp: Date?

    static let typingTimeout: TimeInterval = 1.5

    init(logger: LoggingProviding) {
        self.logger = logger
    }

    func setCallbacks(
        onTypingStarted: @escaping @Sendable () async -> Void,
        onTypingStopped: @escaping @Sendable () async -> Void
    ) {
        self.onTypingStarted = onTypingStarted
        self.onTypingStopped = onTypingStopped
    }

    var isTyping: Bool {
        isTypingState
    }

    func observeInputChange(_ text: String) async {
        let now = Date()
        lastTypingTimestamp = now

        if !isTypingState {
            isTypingState = true
            typingStartTimestamp = now
            await onTypingStarted?()
        }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.typingTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopTyping()
        }
    }

    func forceStopTyping() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        await stopTyping()
    }

    func cancel() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        isTypingState = false
        typingStartTimestamp = nil
        lastTypingTimestamp = nil
    }

    private func stopTyping() async {
        guard isTypingState else { return }
        isTypingState = false
        await onTypingStopped?()
    }
}
