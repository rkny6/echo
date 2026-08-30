import Foundation
import CoreLocation
import SwiftData

// MARK: - Mock Health Data Service

actor MockHealthDataService: HealthDataProviding {
    func getTodayStepCount() async throws -> Int {
        // Return random steps between 0 and 15000
        return Int.random(in: 0...15000)
    }

    func getStepCounts(days: Int) async throws -> [DailyStepCount] {
        (0..<days).reversed().map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            return DailyStepCount(date: date, steps: Int.random(in: 0...15000))
        }
    }
    
    func getSleepAnalysis(days: Int) async throws -> [SleepDataV2] {
        var sleepData: [SleepDataV2] = []
        for i in (0..<days).reversed() {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: Date())!
            let duration = Int.random(in: 360...480) // 6-8 hours
            let deep = Int.random(in: 60...100)
            let core = duration - deep - Int.random(in: 60...90)
            let rem = max(0, duration - deep - core)
            let quality = Double.random(in: 0.4...1.0)
            sleepData.append(
                SleepDataV2(
                    date: date,
                    totalDurationMinutes: duration,
                    deepSleepMinutes: deep,
                    coreSleepMinutes: core,
                    remSleepMinutes: rem,
                    qualityScore: quality
                )
            )
        }
        return sleepData
    }
    
    func getMenstrualCyclePrediction() async throws -> MenstrualCycleData? {
        return MenstrualCycleData(
            nextExpectedStartDate: Date().addingTimeInterval(3 * 24 * 3600),
            daysUntilStart: 3,
            cycleLength: 28,
            isPredictionReliable: true
        )
    }
    
    func getHeartRateVariability() async throws -> [HRVData] {
        return (0..<10).map { i in
            let timestamp = Date().addingTimeInterval(-Double(i) * 3600)
            let value = Double.random(in: 20...100)
            return HRVData(timestamp: timestamp, value: value)
        }
    }
}

// MARK: - Mock Location Service

actor MockLocationService: LocationProviding {
    nonisolated var currentLocation: CLLocationCoordinate2D? {
        return nil
    }
    
    func requestLocationUpdates() async {}
    
    nonisolated func stopLocationUpdates() {}
    
    func isUserOut() async -> Bool {
        return Bool.random()
    }
    
    nonisolated func setLocationEventHandler(_ handler: @escaping (CompanionEvent) async -> Void) {}
}

// MARK: - Mock Event Detection Service

actor MockEventDetectionService: EventDetecting {
    init() {}
    
    func detectEvents() async throws -> [CompanionEvent] {
        // Return a random event for testing
        let types: [CompanionEventType] = [.outing, .sleep, .lowSteps, .highSteps, .menstrualCycle]
        let randomType = types.randomElement() ?? .outing
        
        return [
            CompanionEvent(
                type: randomType,
                metadata: ["source": "mock"]
            )
        ]
    }
    
    func detectExtremeHealthEvents() async throws -> [CompanionEvent] {
        []
    }
    
    func triggerEventForTesting(_ type: CompanionEventType) async throws {
        // Do nothing in mock
    }
    
    // 新增：协议要求的日期事件检测方法
    func detectDateBasedEvents() async throws -> [CompanionEvent] {
        // 返回空数组（Mock 不模拟日期事件）
        return []
    }
}

// MARK: - Mock Prompt Builder

actor MockPromptBuilder: PromptBuilding {
    nonisolated func buildSystemPrompt(
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        longTermSummary: String?,
        userProfile: [String: String]?,
        dailyContext: String?,
        characterStatus: CharacterOnlineStatus?,
        statusContext: String?,
        localTimeString: String?,
        dateAmbience: String? = nil,
        weatherAmbience: String? = nil,
        sleepAmbience: String? = nil,
        diaryMemory: String? = nil,
        conversationGap: String? = nil
    ) async throws -> String {
        return "你是一个男性虚拟伴侣。默认用户是女性。请友好、关心地与她互动。"
    }
    
    nonisolated func buildEventPrompt(
        event: CompanionEvent,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        recentMessages: [ChatMessageSnapshot],
        longTermSummary: String?
    ) async throws -> String {
        return "根据发生的事件 \(event.type.rawValue)，请与用户对话。"
    }
    
    nonisolated func buildConversationPrompt(
        userMessage: String,
        character: CharacterProfileSnapshot,
        user: UserProfileSnapshot,
        recentMessages: [ChatMessageSnapshot],
        longTermSummary: String?
    ) -> String {
        return "用户消息: \(userMessage)"
    }
}

// MARK: - Mock Settings Service

actor MockSettingsService: SettingsProviding {
    private var settings = AppSettings.default
    
    func getSettings() async throws -> AppSettings {
        return settings
    }
    
    func updateSettings(_ newSettings: AppSettings) async throws {
        self.settings = newSettings
    }
    
    func getSetting<T>(_ key: String) async throws -> T? {
        return nil
    }
    
    func setSetting<T>(_ key: String, value: T) async throws {}
}

// MARK: - Mock Keychain Service

actor MockKeychainService: KeychainProviding {
    private var storage: [String: String] = [:]
    
    func store(_ value: String, for key: String) async throws {
        storage[key] = value
    }
    
    func retrieve(_ key: String) async throws -> String? {
        return storage[key]
    }
    
    func delete(_ key: String) async throws {
        storage.removeValue(forKey: key)
    }
}

// MARK: - Mock Logger Service

actor MockLoggerService: LoggingProviding {
    private let maxEntries: Int
    private var logs: [LogEntry] = []

    init(maxEntries: Int = LoggerService.defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    func log(_ message: String, level: LogLevel) async {
        let entry = LogEntry(id: UUID(), timestamp: Date(), level: level, message: message)
        logs.append(entry)
        let overflow = logs.count - maxEntries
        if overflow > 0 {
            logs.removeFirst(overflow)
        }
        print("[\(level.rawValue.uppercased())] \(message)")
    }

    func getLogs() async -> [LogEntry] {
        return logs
    }

    func clearLogs() async throws {
        logs.removeAll(keepingCapacity: true)
    }
}

// MARK: - Mock Notification Service

actor MockNotificationService: NotificationScheduling {
    func scheduleNotification(
        title: String,
        body: String,
        delay: TimeInterval,
        metadata: [String: String]? = nil,
        identifier: String = UUID().uuidString
    ) async throws {
        print("📱 Mock notification: \(title) - \(body) (delay: \(delay)s, id: \(identifier))")
    }
    
    func cancelNotification(identifier: String) async throws {
        print("🔕 Mock: notification \(identifier) cancelled")
    }
    
    func cancelAllNotifications() async throws {
        print("🔕 Mock: All notifications cancelled")
    }
    
    func requestAuthorization() async throws -> Bool {
        print("✅ Mock: Notification authorization requested")
        return true
    }
}

// MARK: - Mock Time Zone Awareness Provider
class MockTimeZoneAwarenessProvider: TimeZoneAwarenessProvider {
    override init(logger: LoggingProviding) {
        super.init(logger: logger)
    }
    
    override func getLocalTimeString(for date: Date = Date()) -> String {
        return "2026年06月16日 14:30 (周二) UTC+8 北京"
    }
}

// MARK: - Mock LLM Provider

/// Error thrown by `MockLLMProvider` when its script is empty.
enum LLMMockError: LocalizedError {
    case emptyScript

    var errorDescription: String? {
        "MockLLMProvider script is empty"
    }
}

/// Scriptable LLM provider for previews and tests. Pops results from a
/// script in order; the last result repeats once the script is exhausted.
/// Records every received message array / tool set so tests can assert
/// tool-call round trips.
actor MockLLMProvider: LLMProviderService {
    private var script: [LLMGenerationResult]
    private var index = 0
    private let connectionResult: Bool
    private(set) var receivedMessages: [[LLMMessage]] = []
    private(set) var receivedTools: [[LLMToolDefinition]?] = []

    init(
        script: [LLMGenerationResult] = [],
        testConnectionResult: Bool = true
    ) {
        self.script = script
        self.connectionResult = testConnectionResult
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMGenerationResult {
        receivedMessages.append(messages)
        receivedTools.append(tools)
        guard !script.isEmpty else {
            throw LLMMockError.emptyScript
        }
        let result = script[min(index, script.count - 1)]
        index += 1
        return result
    }

    func testConnection() async throws -> Bool {
        connectionResult
    }

    /// Number of `generate` calls made so far.
    var callCount: Int {
        index
    }
}

// MARK: - Mock LLM Service Factory

/// Scriptable `LLMServiceFactoryProviding` for tests — returns a fresh
/// `MockLLMProvider` per `createProvider` call and records the call count.
actor MockLLMServiceFactory: LLMServiceFactoryProviding {
    private let script: [LLMGenerationResult]
    private let testConnectionResult: Bool
    private(set) var createProviderCallCount = 0
    private(set) var lastProvider: MockLLMProvider?

    init(script: [LLMGenerationResult] = [], testConnectionResult: Bool = true) {
        self.script = script
        self.testConnectionResult = testConnectionResult
    }

    func createProvider(settings: AppSettings) async throws -> LLMProviderService {
        createProviderCallCount += 1
        let provider = MockLLMProvider(script: script, testConnectionResult: testConnectionResult)
        lastProvider = provider
        return provider
    }
}

// MARK: - Mock Character Status Manager

/// Deterministic `CharacterStatusManaging` fake — returns a fixed delivery
/// decision and online status, and records interactions for assertions.
actor MockCharacterStatusManager: CharacterStatusManaging {
    private var decision: ResponseDeliveryDecision
    private var status: CharacterOnlineStatus
    private var onStatusChange: (@Sendable (CharacterOnlineStatus, OnlineTransitionReason?) async -> Void)?
    private(set) var comeOnlineCallCount = 0
    private(set) var userSentMessageCallCount = 0
    private(set) var conversationActiveStates: [Bool] = []

    init(
        decision: ResponseDeliveryDecision = .deliverNow(delay: 0.1),
        status: CharacterOnlineStatus = .online
    ) {
        self.decision = decision
        self.status = status
    }

    func setDecision(_ decision: ResponseDeliveryDecision) {
        self.decision = decision
    }

    func setOnStatusChange(_ handler: @escaping @Sendable (CharacterOnlineStatus, OnlineTransitionReason?) async -> Void) async {
        onStatusChange = handler
    }

    func initializeStatus(for date: Date) async throws {
        await onStatusChange?(status, nil)
    }

    func userSentMessage() async throws {
        userSentMessageCallCount += 1
    }

    func decideResponseDelivery() async -> ResponseDeliveryDecision {
        decision
    }

    func comeOnline() async {
        comeOnlineCallCount += 1
        status = .online
    }

    func setConversationActive(_ active: Bool) async {
        conversationActiveStates.append(active)
    }

    func hasReachedPlannedOnlineWindow(at date: Date) async -> Bool {
        status == .online
    }

    func getScheduleDebugInfo(at date: Date) async -> CharacterScheduleDebugInfo {
        CharacterScheduleDebugInfo(
            currentStatus: status,
            isConversationActive: conversationActiveStates.last == true,
            lastOnlineWasEarly: false,
            dayStart: Calendar.current.startOfDay(for: date),
            windows: [],
            totalOnlineSeconds: 0,
            nextTransition: nil,
            nextOnline: nil,
            capturedAt: date
        )
    }

    func regenerateScheduleForDebug(at date: Date) async -> CharacterScheduleDebugInfo {
        await getScheduleDebugInfo(at: date)
    }
}
