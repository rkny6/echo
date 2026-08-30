import Foundation
import SwiftData

/// Central orchestrator for conversation state, message accumulation, and delayed event replies.
actor ConversationManager: ConversationManaging {
    let llmServiceFactory: any LLMServiceFactoryProviding
    let promptBuilder: PromptBuilding
    let notificationService: NotificationScheduling
    let logger: LoggingProviding
    let settingsService: SettingsProviding
    /// Sole durable owner for Character/User profile singleton rows.
    let profileService: any ProfileProviding
    /// Sole owner for ChatMessage user writes / status / delete coordination (PR1a).
    let chatMessageStore: ChatMessageStore
    let delayedResponseManager: DelayedResponseManager
    let pendingEventQueue: PendingEventQueue
    let typingMonitor: TypingMonitor
    let memoryManager: MemoryManaging
    let dailyContextManager: DailyContextManager
    let characterStatusManager: any CharacterStatusManaging
    let diaryService: DiaryService
    /// Cloud/on-device image recognition + fallback policy (extracted; see
    /// ImageMessageProcessor.swift).
    let imageMessageProcessor: ImageMessageProcessor
    /// Tools the model may call when `AppSettings.enableMCP` is on. Empty by
    /// default; composition root registers the weather tool synchronously and
    /// merges in remote MCP tools asynchronously afterward via
    /// `setToolRegistry`, since fetching a remote server's `tools/list`
    /// can't happen inside this actor's (synchronous) `init`.
    var toolRegistry: ToolRegistry
    /// Assembles daily-context/status/memory/ambience/gap once per reply —
    /// previously duplicated inline in both `startConversation` and
    /// `processAccumulatedBatch`.
    let promptContextAssembler: PromptContextAssembler

    var messageBatcher: MessageBatcher?
    let typingDelayCalculator = TypingDelayCalculator()
    var pendingAssistantResponseDeliveryTask: Task<Void, Never>?
    /// Bumped whenever the user sends new content so in-flight LLM work and
    /// parked deliveries from an older batch are discarded.
    var userReplyGeneration: Int = 0
    /// User-reply delivery that can be paused while the user is typing again
    /// (instead of being permanently cancelled).
    var activeUserReplyDelivery: PendingUserReplyDelivery?
    var isUserReplyDeliveryPaused = false
    /// True while bubbles are being inserted — typing must not cancel mid-stream.
    var isDeliveringUserReply = false
    /// When the current user-reply delivery wait started, used to recompute
    /// remaining delay if typing pauses mid-wait.
    var userReplyDeliveryStartedAt: Date?
    /// Prevents overlapping cold-start / foreground recovery scans.
    var isRecoveringInterruptedReplies = false
    /// True while `handleAccumulatedBatch` owns an in-flight LLM/delivery path.
    var isProcessingUserBatch = false
    /// Serializes user-batch LLM work. MessageBatcher dispatches each flush via
    /// `Task.detached`, so without this gate two batches can re-enter the actor
    /// and fire concurrent `sendMessageWithRetry` for the same conversation.
    var activeUserBatchTask: Task<Void, Error>?

    /// In-memory hold for a user-path reply that is waiting to be delivered.
    /// Content is also persisted as `PendingResponse` (`pendingResponseId`) so a
    /// process kill can recover without re-calling the LLM. The live owner arms
    /// the wait here with `armInProcessDelivery: false` to avoid double delivery.
    struct PendingUserReplyDelivery {
        let content: String
        let conversationId: UUID
        let characterName: String
        let userName: String
        let remainingDelay: TimeInterval
        let needsEarlyOnline: Bool
        let generation: Int
        let backgroundTask: BackgroundTaskAssertion
        /// Matching row in DelayedResponseManager (OS fallback + crash recovery).
        let pendingResponseId: UUID?
    }
    var onStateChange: (@Sendable (ConversationState) async -> Void)?
    var onReplyGenerating: (@Sendable () async -> Void)?
    var onReadingIndicatorChange: (@Sendable (Bool) async -> Void)?
    var onEventResponseScheduled: (@Sendable () async -> Void)?
    var onReplyReady: (@Sendable () async -> Void)?
    /// Fires after each individual bubble in a multi-message reply is
    /// inserted, so the UI can reveal them one at a time as their pacing
    /// delays actually elapse — distinct from onReplyReady, which only fires
    /// once at the end and also clears the "generating" indicator (firing it
    /// per-message would hide that indicator after the first bubble instead
    /// of keeping it up through the whole sequence).
    var onMessageDelivered: (@Sendable () async -> Void)?
    var onError: (@Sendable (String) async -> Void)?
    var onCharacterStatusChange: (@Sendable (CharacterOnlineStatus) async -> Void)?
    /// Fired on real offline→online transitions that come from the daily schedule
    /// (not temporary early-online for answering the user).
    var onScheduledOnline: (@Sendable () async -> Void)?

    var conversationState: ConversationState = .idle
    var currentConversationId: UUID?
    var inactivityTask: Task<Void, Never>?
    var currentDailyContext: String?
    var statusChangeContext: String?
    /// `nil` until the first status callback (cold start).
    var previousStatus: CharacterOnlineStatus?

    static let inactivityTimeout: TimeInterval = 300

    init(
        llmServiceFactory: any LLMServiceFactoryProviding,
        promptBuilder: PromptBuilding,
        notificationService: NotificationScheduling,
        logger: LoggingProviding,
        settingsService: SettingsProviding,
        profileService: any ProfileProviding,
        chatMessageStore: ChatMessageStore,
        delayedResponseManager: DelayedResponseManager,
        pendingEventQueue: PendingEventQueue,
        typingMonitor: TypingMonitor,
        memoryManager: MemoryManaging,
        dailyContextManager: DailyContextManager,
        characterStatusManager: any CharacterStatusManaging,
        diaryService: DiaryService,
        promptContextAssembler: PromptContextAssembler,
        imageMessageProcessor: ImageMessageProcessor,
        toolRegistry: ToolRegistry = ToolRegistry(tools: [])
    ) {
        self.llmServiceFactory = llmServiceFactory
        self.promptBuilder = promptBuilder
        self.notificationService = notificationService
        self.logger = logger
        self.settingsService = settingsService
        self.profileService = profileService
        self.chatMessageStore = chatMessageStore
        self.delayedResponseManager = delayedResponseManager
        self.pendingEventQueue = pendingEventQueue
        self.typingMonitor = typingMonitor
        self.memoryManager = memoryManager
        self.dailyContextManager = dailyContextManager
        self.characterStatusManager = characterStatusManager
        // Injected from composition root so generation + retrieval share one actor.
        self.diaryService = diaryService
        self.promptContextAssembler = promptContextAssembler
        self.imageMessageProcessor = imageMessageProcessor
        self.toolRegistry = toolRegistry
    }
    
    func configureTypingMonitorCallbacks() async {
        await typingMonitor.setCallbacks(
            onTypingStarted: { [weak self] in
                await self?.userStartedTyping()
            },
            onTypingStopped: { [weak self] in
                await self?.userStoppedTyping()
            }
        )
    }

    func setMessageBatcher(_ batcher: MessageBatcher) {
        messageBatcher = batcher
    }

    func setCallbacks(
        onStateChange: @escaping @Sendable (ConversationState) async -> Void,
        onReplyGenerating: @escaping @Sendable () async -> Void,
        onReadingIndicatorChange: @escaping @Sendable (Bool) async -> Void,
        onEventResponseScheduled: @escaping @Sendable () async -> Void,
        onReplyReady: @escaping @Sendable () async -> Void,
        onError: @escaping @Sendable (String) async -> Void,
        onMessageDelivered: (@Sendable () async -> Void)? = nil
    ) {
        self.onStateChange = onStateChange
        self.onReplyGenerating = onReplyGenerating
        self.onReadingIndicatorChange = onReadingIndicatorChange
        self.onEventResponseScheduled = onEventResponseScheduled
        self.onReplyReady = onReplyReady
        self.onError = onError
        self.onMessageDelivered = onMessageDelivered
    }

    /// Replaces the tool registry wholesale — used by the composition root
    /// once an async MCP `tools/list` fetch completes (or fails) after
    /// launch, and again whenever the user reconnects to a different MCP
    /// server from Settings. In-flight replies keep using whatever registry
    /// they already captured; only the *next* `generateReply` call sees the
    /// update.
    func setToolRegistry(_ registry: ToolRegistry) {
        toolRegistry = registry
    }

    func getConversationState() async -> ConversationState {
        conversationState
    }

    func getCurrentConversationId() async -> UUID? {
        currentConversationId
    }

    // MARK: - Private Helpers

    func transitionTo(_ newState: ConversationState) async {
        guard conversationState != newState else { return }
        let oldState = conversationState
        conversationState = newState
        await persistConversationSnapshot()

        // Soft keep-online while non-idle; schedule resumes authority on idle.
        // Always publish so a missed edge still self-heals.
        let isActive = newState != .idle
        Task {
            await characterStatusManager.setConversationActive(isActive)
        }

        Task {
            await logger.log(
                "Conversation state: \(oldState.rawValue) → \(newState.rawValue)",
                level: .debug
            )
            await onStateChange?(newState)
        }
    }

    func resetInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.inactivityTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            try? await completeConversation()
        }
    }

    /// Call when the app returns to the foreground.
    ///
    /// `resetInactivityTimer()` drives the only path back to `.idle` (and
    /// therefore the only path that drains `pendingEventQueue`) via an
    /// in-process `Task.sleep`. That timer only keeps running while the app
    /// process is alive; once backgrounded for more than a few seconds it's
    /// suspended along with everything else. So if a conversation goes
    /// non-idle (e.g. from an outing event) and the app is backgrounded
    /// before the 5-minute timer fires, the conversation stays stuck in that
    /// state indefinitely and every event that arrives in the meantime (e.g.
    /// more SLC location-change events) just piles up in the queue with
    /// nothing to drain it. This reconciles on foreground: if real wall-clock
    /// time well past the inactivity timeout has actually elapsed, force the
    /// conversation idle so any queued events get a chance to run.
    func reconcileAfterForeground() async {
        // Always re-check held / due pending replies when returning to foreground,
        // even if conversation state is already idle.
        await delayedResponseManager.recoverHeldResponsesOnForeground()

        guard conversationState != .idle else { return }
        let snapshot = await chatMessageStore.loadConversationSnapshot()
        let elapsed = Date().timeIntervalSince(snapshot.lastActivityAt)
        guard elapsed >= Self.inactivityTimeout else { return }

        await logger.log(
            "Reconciling stuck conversation state (\(conversationState.rawValue)) on foreground after \(Int(elapsed))s of inactivity",
            level: .info
        )
        try? await completeConversation()
    }

    /// Persist orchestration state through `ChatMessageStore` (PR2a sole owner).
    /// Sticky id is preserved when `currentConversationId` is nil (idle).
    func persistConversationSnapshot() async {
        await chatMessageStore.persistConversationState(
            conversationState: conversationState,
            currentConversationId: currentConversationId
        )
    }

}

enum ConversationError: Error, LocalizedError {
    case messageAccumulatorNotConfigured
    case messageNotFound
    case invalidResendTarget
    case emptyAssistantPlan

    var errorDescription: String? {
        switch self {
        case .messageAccumulatorNotConfigured:
            return "消息批处理器未配置"
        case .messageNotFound:
            return "找不到要重发的消息"
        case .invalidResendTarget:
            return "只能重发用户消息"
        case .emptyAssistantPlan:
            return "助手回复分段后为空"
        }
    }
}
