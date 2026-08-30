import Foundation

/// Decides *when* to proactively reach out — online-window greetings and
/// long-silence evening check-ins — and drives the health/diary catch-up
/// pipeline on cold start, foreground, and background refresh.
///
/// Extracted from `AppViewModel`, where this ~350-line block of pure timing
/// logic lived alongside `@Published` UI state despite never mutating any of
/// it directly (it only *reads* `proactiveCaringEnabled` / the character
/// name, both passed in as parameters here rather than read from a shared
/// `AppViewModel` reference — see the two `guard`/`characterName` sites
/// below).
///
/// Hard limits — once-a-day caps, "don't interrupt an active chat", the
/// governor's cooldowns — are unconditional and unchanged regardless of the
/// `useLLMProactiveJudgment` setting below; they gate *whether this fires at
/// all*, same UserDefaults keys, same call order as the original extraction.
/// What *can* change is the soft judgment inside those limits — "is this
/// silence actually worth a message, and if so what should it say" — which
/// `resolveSilence` / `resolveMessage` delegate to `ProactiveIntentDecider`
/// when that setting is on, instead of the fixed `silenceThresholdHours` /
/// 21–23 window rule.
actor ProactiveEngagementCoordinator {
    private let chatMessageStore: ChatMessageStore
    private let conversationManager: ConversationManaging
    private let onlineGreetingService: OnlineGreetingService
    private let healthProactiveCoordinator: HealthProactiveCoordinator
    private let diaryService: DiaryService
    private let logger: LoggingProviding
    private let settingsService: SettingsProviding
    /// Optional: when present *and* `AppSettings.useLLMProactiveJudgment` is
    /// on, this replaces the fixed `silenceThresholdHours` / evening-window
    /// check with a single structured LLM judgment (see that type's doc
    /// comment). `nil` — or the setting being off — falls back to the
    /// original rule-based path unchanged, so this is a strict opt-in.
    private let intentDecider: ProactiveIntentDecider?

    private let governor = NotificationGovernor()

    // MARK: - UserDefaults keys (unchanged from AppViewModel extraction)
    private let lastOnlineGreetingTimeKey = "lastOnlineGreetingTime"
    private let lastOnlineGreetingDayStartKey = "lastOnlineGreetingDayStart"
    private let lastEveningCheckInDayStartKey = "lastEveningCheckInDayStart"

    /// Minimum silence (awake hours) before online greeting fires.
    /// Used verbatim when `useLLMProactiveJudgment` is off. When it's on,
    /// this instead acts as a cheap floor to avoid spending an LLM call on
    /// silences too short to plausibly warrant outreach either way.
    private static let silenceThresholdHours: Double = 3.0
    private static let llmJudgmentFloorHours: Double = 1.0

    init(
        chatMessageStore: ChatMessageStore,
        conversationManager: ConversationManaging,
        onlineGreetingService: OnlineGreetingService,
        healthProactiveCoordinator: HealthProactiveCoordinator,
        diaryService: DiaryService,
        logger: LoggingProviding,
        settingsService: SettingsProviding,
        intentDecider: ProactiveIntentDecider? = nil
    ) {
        self.chatMessageStore = chatMessageStore
        self.conversationManager = conversationManager
        self.onlineGreetingService = onlineGreetingService
        self.healthProactiveCoordinator = healthProactiveCoordinator
        self.diaryService = diaryService
        self.logger = logger
        self.settingsService = settingsService
        self.intentDecider = intentDecider
    }

    // MARK: - Public API (called from AppViewModel)

    /// Serial proactive pipeline for cold start / foreground / BG:
    /// health first, then online-greeting catch-up, then evening long-silence care.
    func runProactiveCatchUp(
        source: String,
        proactiveCaringEnabled: Bool,
        characterName: String,
        debugFastMode: Bool
    ) async {
        await logger.log("ProactiveCatchUp(\(source)): start", level: .debug)

        // 1. Health trigger + process
        await healthProactiveCoordinator.handleHealthTrigger(processImmediately: true)

        // 2. Diary generation (background also does this)
        await diaryService.generateDiaryIfNeeded()

        // 3. Online greeting catch-up
        await maybeCatchUpOnlineGreeting(
            source: source,
            proactiveCaringEnabled: proactiveCaringEnabled,
            characterName: characterName,
            debugFastMode: debugFastMode
        )

        // 4. Evening check-in
        await maybeCatchUpEveningCheckIn(
            source: source,
            proactiveCaringEnabled: proactiveCaringEnabled,
            characterName: characterName,
            debugFastMode: debugFastMode
        )

        await logger.log("ProactiveCatchUp(\(source)): done", level: .debug)
    }

    /// Live schedule transition: planned offline→online (not early-online / cold start).
    func handleScheduledOnline(
        proactiveCaringEnabled: Bool,
        characterName: String,
        debugFastMode: Bool
    ) async {
        await attemptOnlineGreeting(
            source: "scheduledOnline",
            requirePlannedWindowReached: false,
            proactiveCaringEnabled: proactiveCaringEnabled,
            characterName: characterName,
            debugFastMode: debugFastMode
        )
    }

    /// Missed transition recovery: only if today's plan has already reached an online window.
    func maybeCatchUpOnlineGreeting(
        source: String,
        proactiveCaringEnabled: Bool,
        characterName: String,
        debugFastMode: Bool
    ) async {
        await attemptOnlineGreeting(
            source: source,
            requirePlannedWindowReached: true,
            proactiveCaringEnabled: proactiveCaringEnabled,
            characterName: characterName,
            debugFastMode: debugFastMode
        )
    }

    /// Long-silence evening care: 21:00–23:00 local, independent of online-window transition.
    func maybeCatchUpEveningCheckIn(
        source: String,
        proactiveCaringEnabled: Bool,
        characterName: String,
        debugFastMode: Bool
    ) async {
        guard proactiveCaringEnabled else { return }

        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 21 && hour < 23 else {
            await logger.log("EveningCheckIn(\(source)): outside 21–23 window (hour=\(hour))", level: .debug)
            return
        }

        // Once per day
        let dayStart = Calendar.current.startOfDay(for: Date())
        if let lastDayStart = UserDefaults.standard.object(forKey: lastEveningCheckInDayStartKey) as? Date,
           lastDayStart >= dayStart {
            await logger.log("EveningCheckIn(\(source)): already done today", level: .debug)
            return
        }

        // Conversation must be idle
        let state = await conversationManager.getConversationState()
        guard state == .idle else {
            await logger.log("EveningCheckIn(\(source)): conversation not idle (\(state))", level: .debug)
            return
        }

        // Health story wins
        let healthState = await healthProactiveCoordinator.healthCareStoryState()
        if healthState.hasStory {
            await logger.log("EveningCheckIn(\(source)): health story active (\(healthState.rawValue)), skipping", level: .debug)
            return
        }

        // Silence check (floor only when the LLM will make the real call;
        // full fixed threshold otherwise — see resolveSilence doc comment)
        guard let silence = await resolveSilence(logTag: "EveningCheckIn(\(source))") else {
            return
        }

        // Governor
        let lastUserMsg = await chatMessageStore.lastUserMessageAt()
        let decision = governor.shouldSendProactive(
            source: .eveningCheckIn,
            lastUserMessageDate: lastUserMsg,
            debugFastMode: debugFastMode
        )
        guard decision.allowed else {
            await logger.log("EveningCheckIn(\(source)): governor blocked — \(decision.reason)", level: .debug)
            return
        }

        // Generate — LLM-judged path (opt-in) or the original fixed-window path
        guard let message = await resolveMessage(
            kind: .eveningCheckIn,
            silence: silence,
            characterName: characterName,
            logTag: "EveningCheckIn(\(source))"
        ) else {
            return
        }

        // Schedule via conversation manager
        do {
            let conversationId = await conversationManager.getCurrentConversationId() ?? UUID()
            try await conversationManager.scheduleProactiveAssistantResponse(
                content: message,
                conversationId: conversationId,
                eventType: .eveningCheckIn,
                characterName: characterName,
                delay: Double.random(in: 2...6)
            )
            governor.recordSend(source: .eveningCheckIn)
            UserDefaults.standard.set(dayStart, forKey: lastEveningCheckInDayStartKey)
            await logger.log("EveningCheckIn(\(source)): scheduled", level: .info)
        } catch {
            await logger.log("EveningCheckIn(\(source)): schedule failed — \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Private

    private func attemptOnlineGreeting(
        source: String,
        requirePlannedWindowReached: Bool,
        proactiveCaringEnabled: Bool,
        characterName: String,
        debugFastMode: Bool
    ) async {
        guard proactiveCaringEnabled else { return }

        // Once per day
        let dayStart = Calendar.current.startOfDay(for: Date())
        if let lastDayStart = UserDefaults.standard.object(forKey: lastOnlineGreetingDayStartKey) as? Date,
           lastDayStart >= dayStart {
            await logger.log("OnlineGreeting(\(source)): already done today", level: .debug)
            return
        }

        // Conversation must be idle
        let state = await conversationManager.getConversationState()
        guard state == .idle else {
            await logger.log("OnlineGreeting(\(source)): conversation not idle (\(state))", level: .debug)
            return
        }

        // Health story wins
        let healthState = await healthProactiveCoordinator.healthCareStoryState()
        if healthState.hasStory {
            await logger.log("OnlineGreeting(\(source)): health story active (\(healthState.rawValue)), skipping", level: .debug)
            return
        }

        // Silence check (floor only when the LLM will make the real call;
        // full fixed threshold otherwise — see resolveSilence doc comment)
        guard let silence = await resolveSilence(logTag: "OnlineGreeting(\(source))") else {
            return
        }

        // Governor
        let lastUserMsg = await chatMessageStore.lastUserMessageAt()
        let decision = governor.shouldSendProactive(
            source: .onlineGreeting,
            lastUserMessageDate: lastUserMsg,
            debugFastMode: debugFastMode
        )
        guard decision.allowed else {
            await logger.log("OnlineGreeting(\(source)): governor blocked — \(decision.reason)", level: .debug)
            return
        }

        // Generate — LLM-judged path (opt-in) or the original fixed-window path
        guard let message = await resolveMessage(
            kind: .onlineGreeting,
            silence: silence,
            characterName: characterName,
            logTag: "OnlineGreeting(\(source))"
        ) else {
            return
        }

        // Schedule via conversation manager
        do {
            let conversationId = await conversationManager.getCurrentConversationId() ?? UUID()
            try await conversationManager.scheduleProactiveAssistantResponse(
                content: message,
                conversationId: conversationId,
                eventType: .onlineGreeting,
                characterName: characterName,
                delay: Double.random(in: 2...6)
            )
            governor.recordSend(source: .onlineGreeting)
            UserDefaults.standard.set(Date(), forKey: lastOnlineGreetingTimeKey)
            UserDefaults.standard.set(dayStart, forKey: lastOnlineGreetingDayStartKey)
            await logger.log("OnlineGreeting(\(source)): scheduled", level: .info)
        } catch {
            await logger.log("OnlineGreeting(\(source)): schedule failed — \(error.localizedDescription)", level: .error)
        }
    }

    private func computeSilence() async -> ContactSilenceMetrics? {
        guard let lastContact = await chatMessageStore.lastUserMessageAt() else {
            return nil
        }
        return ContactSilenceMetrics(lastContactAt: lastContact)
    }

    private func useLLMJudgment() async -> Bool {
        guard intentDecider != nil else { return false }
        let settings = (try? await settingsService.getSettings()) ?? .default
        return settings.useLLMProactiveJudgment
    }

    /// Silence gate before we even consider generating anything.
    ///
    /// - Rule-based mode (`useLLMProactiveJudgment` off): the original fixed
    ///   `silenceThresholdHours` bar — silence below it is disqualifying.
    /// - LLM-judged mode: a much lower floor (`llmJudgmentFloorHours`). The
    ///   real "is this actually worth reaching out over" call is delegated to
    ///   the model in `resolveMessage`; this floor only exists so a silence
    ///   of a few minutes never even reaches an LLM call.
    private func resolveSilence(logTag: String) async -> ContactSilenceMetrics? {
        guard let silence = await computeSilence() else {
            await logger.log("\(logTag): no prior user message, skipping", level: .debug)
            return nil
        }
        let floor = await useLLMJudgment() ? Self.llmJudgmentFloorHours : Self.silenceThresholdHours
        guard silence.awakeHours >= floor else {
            await logger.log("\(logTag): insufficient silence (\(String(format: "%.1f", silence.awakeHours))h < \(floor)h)", level: .debug)
            return nil
        }
        return silence
    }

    /// Produces the message to send, or `nil` if nothing should be sent.
    /// Routes to `ProactiveIntentDecider` when LLM judgment is on and
    /// available; otherwise generates unconditionally via
    /// `OnlineGreetingService`, exactly as before this feature existed.
    private func resolveMessage(
        kind: ProactiveJudgmentKind,
        silence: ContactSilenceMetrics,
        characterName: String,
        logTag: String
    ) async -> String? {
        if await useLLMJudgment(), let intentDecider {
            guard let decision = await intentDecider.decide(
                kind: kind,
                silence: silence,
                characterName: characterName
            ) else {
                await logger.log("\(logTag): intent decider unavailable, skipping", level: .warning)
                return nil
            }
            guard decision.shouldSend, let message = decision.message else {
                await logger.log("\(logTag): model decided not to send — \(decision.reason)", level: .debug)
                return nil
            }
            return message
        }

        let message: String?
        switch kind {
        case .onlineGreeting:
            message = await onlineGreetingService.generateMessage(silence: silence)
        case .eveningCheckIn:
            message = await onlineGreetingService.generateEveningCheckInMessage(silence: silence)
        }
        if message == nil {
            await logger.log("\(logTag): LLM returned nil", level: .warning)
        }
        return message
    }
}
