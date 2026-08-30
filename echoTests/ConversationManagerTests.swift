import Foundation
import SwiftData
import Testing
@testable import echo

// MARK: - Timeout helper

/// Polls `condition` every 0.1s until it returns true or `timeout` elapses.
/// Throws `TestTimeoutError` on timeout so `#expect` failures read clearly.
func waitUntil(
    timeout: TimeInterval = 10,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    throw TestTimeoutError()
}

struct TestTimeoutError: Error {}

// MARK: - Callback recorder

/// Collects ConversationManager UI callbacks so tests can assert them.
actor CallbackRecorder {
    private(set) var states: [ConversationState] = []
    private(set) var replyReadyCount = 0
    private(set) var replyGeneratingCount = 0
    private(set) var messageDeliveredCount = 0
    private(set) var errors: [String] = []

    func recordState(_ state: ConversationState) { states.append(state) }
    func recordReplyReady() { replyReadyCount += 1 }
    func recordGenerating() { replyGeneratingCount += 1 }
    func recordMessageDelivered() { messageDeliveredCount += 1 }
    func recordError(_ message: String) { errors.append(message) }
}

// MARK: - Conversation test harness

/// Builds a real ConversationManager graph (mirroring `PreviewFactory`) with
/// deterministic fakes: a scripted `MockLLMServiceFactory` and a
/// `MockCharacterStatusManager` returning a fixed delivery decision.
struct ConversationTestHarness: Sendable {
    let container: ModelContainer
    let logger: MockLoggerService
    let settings: MockSettingsService
    let keychain: MockKeychainService
    let notification: MockNotificationService
    let store: ChatMessageStore
    let profileService: ProfileService
    let stubStatus: MockCharacterStatusManager
    let typingMonitor: TypingMonitor
    let delayedResponseManager: DelayedResponseManager
    let conversationManager: ConversationManager
    let batcher: MessageBatcher
    let recorder: CallbackRecorder
    /// Non-nil when the default `MockLLMServiceFactory` is used.
    let mockFactory: MockLLMServiceFactory?

    static func make(
        decision: ResponseDeliveryDecision = .deliverNow(delay: 0.05),
        llmFactory: (any LLMServiceFactoryProviding)? = nil,
        llmScript: [LLMGenerationResult] = [.text("好的呀，我在呢。")]
    ) async throws -> ConversationTestHarness {
        // Mirror the production 16-model schema from VirtualCompanionApp.
        let schema = Schema([
            ChatMessage.self, CompanionEvent.self, RelationshipMemory.self,
            APIProfile.self, CharacterProfile.self, UserProfile.self,
            AppSettings.self, PendingResponse.self, PendingEvent.self,
            ConversationSnapshot.self, HealthAlertRecord.self,
            PendingHealthLLMJob.self, LongTermMemory.self, DailyContext.self,
            CharacterStatus.self, DiaryEntry.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let logger = MockLoggerService()
        let settings = MockSettingsService()
        let keychain = MockKeychainService()
        let notification = MockNotificationService()

        let store = ChatMessageStore(modelContainer: container, logger: logger)
        let profileService = ProfileService(modelContainer: container, logger: logger)

        let resolvedFactory: any LLMServiceFactoryProviding
        let mockFactory: MockLLMServiceFactory?
        if let llmFactory {
            resolvedFactory = llmFactory
            mockFactory = nil
        } else {
            let factory = MockLLMServiceFactory(script: llmScript)
            resolvedFactory = factory
            mockFactory = factory
        }
        // Real factory, never actually called in these tests (the diary snippet
        // path is local-only when no diary entries exist).
        let inertLLMFactory = LLMServiceFactory(keychainService: keychain, settingsService: settings, logger: logger)

        let stubStatus = MockCharacterStatusManager(decision: decision, status: .online)
        // Real status manager for PromptContextAssembler (only status string is read).
        let realStatus = CharacterStatusManager(logger: logger)

        let typingMonitor = TypingMonitor(logger: logger)
        let pendingEventQueue = PendingEventQueue(modelContainer: container, logger: logger)
        let delayedResponseManager = DelayedResponseManager(
            profileService: profileService,
            notificationService: notification,
            chatMessageStore: store,
            logger: logger
        )

        let memoryManager = MemoryManager(
            modelContainer: container,
            chatMessageStore: store,
            logger: logger,
            llmServiceFactory: resolvedFactory,
            settingsService: settings
        )
        let dailyContextManager = DailyContextManager(
            logger: logger,
            llmServiceFactory: resolvedFactory,
            settingsService: settings
        )
        let diaryService = DiaryService(
            modelContainer: container,
            chatMessageStore: store,
            logger: logger,
            llmServiceFactory: inertLLMFactory,
            settingsService: settings,
            profileService: profileService
        )
        let timeZoneAwarenessProvider = MockTimeZoneAwarenessProvider(logger: logger)
        let promptContextAssembler = PromptContextAssembler(
            dailyContextManager: dailyContextManager,
            characterStatusManager: realStatus,
            memoryManager: memoryManager,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            dateAmbienceProvider: DateAmbienceProvider(logger: logger, rng: { 1.0 }),
            weatherAmbienceProvider: WeatherAmbienceProvider(logger: logger, rng: { 1.0 }),
            sleepAmbienceProvider: SleepAmbienceProvider(healthDataService: MockHealthDataService(), logger: logger, rng: { 1.0 }),
            locationProvider: MockLocationService(),
            chatMessageStore: store
        )
        let imageMessageProcessor = ImageMessageProcessor(settingsService: settings, logger: logger)

        let recorder = CallbackRecorder()
        let conversationManager = ConversationManager(
            llmServiceFactory: resolvedFactory,
            promptBuilder: MockPromptBuilder(),
            notificationService: notification,
            logger: logger,
            settingsService: settings,
            profileService: profileService,
            chatMessageStore: store,
            delayedResponseManager: delayedResponseManager,
            pendingEventQueue: pendingEventQueue,
            typingMonitor: typingMonitor,
            memoryManager: memoryManager,
            dailyContextManager: dailyContextManager,
            characterStatusManager: stubStatus,
            diaryService: diaryService,
            promptContextAssembler: promptContextAssembler,
            imageMessageProcessor: imageMessageProcessor
        )

        let batcher = MessageBatcher(
            debounceInterval: 0.05,
            readingIndicatorThreshold: 60,
            idleResetThreshold: 30,
            maxBatchCharacters: 500,
            logger: logger,
            onCompleted: { batch in
                try? await conversationManager.handleAccumulatedBatch(batch)
            }
        )
        await conversationManager.setMessageBatcher(batcher)
        await conversationManager.configureTypingMonitorCallbacks()
        await conversationManager.setCallbacks(
            onStateChange: { state in await recorder.recordState(state) },
            onReplyGenerating: { await recorder.recordGenerating() },
            onReadingIndicatorChange: { _ in },
            onEventResponseScheduled: {},
            onReplyReady: { await recorder.recordReplyReady() },
            onError: { message in await recorder.recordError(message) },
            onMessageDelivered: { await recorder.recordMessageDelivered() }
        )

        return ConversationTestHarness(
            container: container,
            logger: logger,
            settings: settings,
            keychain: keychain,
            notification: notification,
            store: store,
            profileService: profileService,
            stubStatus: stubStatus,
            typingMonitor: typingMonitor,
            delayedResponseManager: delayedResponseManager,
            conversationManager: conversationManager,
            batcher: batcher,
            recorder: recorder,
            mockFactory: mockFactory
        )
    }

    func hasAssistantMessage(containing text: String? = nil) async -> Bool {
        let recent = (try? await store.fetchRecent(limit: 100)) ?? []
        return recent.contains { snapshot in
            guard snapshot.role == .assistant else { return false }
            if let text { return snapshot.content.contains(text) }
            return true
        }
    }
}

// MARK: - Blocking LLM for invalidation tests

/// Provider that suspends until `release()` — used to hold an LLM call
/// in-flight while the test invalidates it.
actor BlockingLLMProvider: LLMProviderService {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private let reply: String

    init(reply: String) {
        self.reply = reply
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMGenerationResult {
        callCount += 1
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return .text(reply)
    }

    func testConnection() async throws -> Bool { true }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// First `createProvider` returns the blocking provider; later calls return a
/// fast scripted `MockLLMProvider` (so the superseding batch can finish).
actor BlockingLLMServiceFactory: LLMServiceFactoryProviding {
    let provider = BlockingLLMProvider(reply: "旧回复")
    private var subsequentProvider: MockLLMProvider?
    private var callCount = 0

    func createProvider(settings: AppSettings) async throws -> LLMProviderService {
        callCount += 1
        if callCount == 1 { return provider }
        if let subsequentProvider { return subsequentProvider }
        let mock = MockLLMProvider(script: [.text("新回复")])
        subsequentProvider = mock
        return mock
    }
}

// MARK: - Tests

/// Step 0 test net: exercises the sendMessage → batcher → LLM → delivery
/// pipeline end to end with deterministic fakes. @MainActor because the
/// pipeline creates `BackgroundTaskAssertion` (UIKit).
@MainActor
struct ConversationManagerTests {

    @Test func sendMessageFlowsThroughBatcherToSingleLLMAndDelivers() async throws {
        let harness = try await ConversationTestHarness.make()
        let cm = harness.conversationManager
        let conversationId = UUID()

        try await cm.sendMessage("你好呀", conversationId: conversationId)

        // Batcher flushes (debounce 0.05s) → exactly one LLM provider created.
        try await waitUntil(timeout: 10) {
            await harness.mockFactory?.createProviderCallCount == 1
        }
        let provider = try #require(await harness.mockFactory?.lastProvider)
        #expect(await provider.callCount == 1)

        // Delivery is async (typing delay) — poll for the assistant bubble.
        try await waitUntil(timeout: 10) {
            await harness.hasAssistantMessage()
        }
        let recent = try await harness.store.fetchRecent(limit: 100)
        #expect(recent.filter { $0.role == .assistant }.count == 1)
        #expect(recent.contains { $0.role == .user && $0.content == "你好呀" })
    }

    @Test func handleAccumulatedBatchPassesFullBatchToLLMOnce() async throws {
        let harness = try await ConversationTestHarness.make(decision: .deliverNow(delay: 0.05))
        let cm = harness.conversationManager
        let conversationId = UUID()

        let batch = AccumulatedMessageBatch(
            conversationId: conversationId,
            messages: [
                AccumulatedMessage(content: "第一条", timestamp: Date()),
                AccumulatedMessage(content: "第二条", timestamp: Date().addingTimeInterval(1))
            ],
            createdAt: Date()
        )

        try await cm.handleAccumulatedBatch(batch)

        let provider = try #require(await harness.mockFactory?.lastProvider)
        #expect(await provider.callCount == 1)
        let firstCall = try #require((await provider.receivedMessages).first)
        #expect(firstCall.contains { $0.content?.contains("第一条") == true })
        #expect(firstCall.contains { $0.content?.contains("第二条") == true })
        #expect(firstCall.contains { $0.role == .system })

        try await waitUntil(timeout: 10) {
            await harness.hasAssistantMessage()
        }
    }

    @Test func newUserMessageInvalidatesInFlightGenerationAndDeliversOnlyNewReply() async throws {
        let blockingFactory = BlockingLLMServiceFactory()
        let harness = try await ConversationTestHarness.make(
            decision: .deliverNow(delay: 0.05),
            llmFactory: blockingFactory
        )
        let cm = harness.conversationManager
        let conversationId = UUID()

        let staleBatch = AccumulatedMessageBatch(
            conversationId: conversationId,
            messages: [AccumulatedMessage(content: "旧消息", timestamp: Date())],
            createdAt: Date()
        )
        let staleTask = Task { try? await cm.handleAccumulatedBatch(staleBatch) }

        // LLM call 1 (stale generation) is in flight and suspended.
        try await waitUntil(timeout: 5) {
            await blockingFactory.provider.callCount == 1
        }

        // New user message invalidates generation 0 and supersedes the reply.
        try await cm.sendMessage("新消息", conversationId: conversationId)

        // Release the stale LLM call — its task is cancelled, so it must throw
        // CancellationError and NOT deliver; the new batch proceeds instead.
        await blockingFactory.provider.release()

        try await waitUntil(timeout: 10) {
            await harness.hasAssistantMessage(containing: "新回复")
        }

        // Stale reply never delivered; stale LLM never completed a second turn.
        #expect(!(await harness.hasAssistantMessage(containing: "旧回复")))
        #expect(await blockingFactory.provider.callCount == 1)
        _ = await staleTask.value
    }

    @Test func typingDuringDeliveryWaitPausesAndResumesWithResidualDelay() async throws {
        // Huge status delay — delivery would take ~60s if not paused/resumed.
        let harness = try await ConversationTestHarness.make(decision: .deliverNow(delay: 60))
        let cm = harness.conversationManager
        let conversationId = UUID()

        try await cm.sendMessage("在吗", conversationId: conversationId)

        // LLM returns quickly; the delivery task is now sleeping ~60s.
        try await waitUntil(timeout: 5) {
            await harness.mockFactory?.createProviderCallCount == 1
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // User starts typing during the wait → delivery pauses (residual ≤1.5s).
        await cm.recordTypingActivity("在")
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Typing stops → resume → residual delay delivers quickly.
        await harness.typingMonitor.forceStopTyping()

        try await waitUntil(timeout: 8) {
            await harness.hasAssistantMessage()
        }
    }

    @Test func comeOnlineAndDeliverBringsCharacterOnlineExactlyOnce() async throws {
        let harness = try await ConversationTestHarness.make(
            decision: .comeOnlineAndDeliver(delay: 0.05)
        )
        let cm = harness.conversationManager
        let conversationId = UUID()

        try await cm.sendMessage("你好", conversationId: conversationId)

        try await waitUntil(timeout: 15) {
            await harness.stubStatus.comeOnlineCallCount >= 1
        }
        #expect(await harness.stubStatus.comeOnlineCallCount == 1)

        try await waitUntil(timeout: 15) {
            await harness.hasAssistantMessage()
        }
    }

    @Test func holdUntilOnlineParksResponseWithoutInsertingBubble() async throws {
        let harness = try await ConversationTestHarness.make(decision: .holdUntilOnline)
        let cm = harness.conversationManager
        let conversationId = UUID()

        try await cm.sendMessage("在吗", conversationId: conversationId)

        // Reply is parked in DelayedResponseManager (persisted PendingResponse).
        try await waitUntil(timeout: 5) {
            (try? await harness.store.pendingDelayedResponseCount()) ?? 0 >= 1
        }
        #expect((try? await harness.store.pendingDelayedResponseCount()) ?? 0 >= 1)

        // No assistant bubble inserted; state moved to followUp; UI told ready.
        #expect(!(await harness.hasAssistantMessage()))
        #expect(await cm.getConversationState() == .followUp)
        #expect(await harness.recorder.replyReadyCount >= 1)
    }
}
