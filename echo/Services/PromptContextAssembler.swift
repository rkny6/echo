import Foundation

/// Everything a system prompt needs about "the current situation" — daily
/// context, character status, memory, local time, and the three ambience
/// snippets (date/weather/sleep) plus the long-silence "conversation gap"
/// framing.
///
/// Pulled out of `ConversationManager`, which previously assembled this
/// exact same bundle twice — once in `startConversation` (event-triggered
/// replies) and once in `processAccumulatedBatch` (user-message replies) —
/// via two independently-maintained, near-identical blocks of code. This is
/// a pure extraction: the computations are unchanged, just centralized in
/// one place so there's one call site instead of two to keep in sync.
struct PromptSituationalContext: Sendable {
    let dailyContext: String?
    let characterStatus: CharacterOnlineStatus
    let memoryContext: (globalSummary: String, userProfile: [String: String], recentMessages: [ChatMessageSnapshot])
    let localTimeString: String
    let dateAmbience: String?
    let weatherAmbience: String?
    let sleepAmbience: String?
    let conversationGap: String?
}

actor PromptContextAssembler {
    private let dailyContextManager: DailyContextManager
    private let characterStatusManager: CharacterStatusManager
    private let memoryManager: MemoryManaging
    private let timeZoneAwarenessProvider: TimeZoneAwarenessProvider
    private let dateAmbienceProvider: DateAmbienceProvider
    private let weatherAmbienceProvider: WeatherAmbienceProvider
    private let sleepAmbienceProvider: SleepAmbienceProvider
    private let locationProvider: LocationProviding
    /// Only needed for `conversationGapDescription()`'s last-activity lookup.
    private let chatMessageStore: ChatMessageStore

    init(
        dailyContextManager: DailyContextManager,
        characterStatusManager: CharacterStatusManager,
        memoryManager: MemoryManaging,
        timeZoneAwarenessProvider: TimeZoneAwarenessProvider,
        dateAmbienceProvider: DateAmbienceProvider,
        weatherAmbienceProvider: WeatherAmbienceProvider,
        sleepAmbienceProvider: SleepAmbienceProvider,
        locationProvider: LocationProviding,
        chatMessageStore: ChatMessageStore
    ) {
        self.dailyContextManager = dailyContextManager
        self.characterStatusManager = characterStatusManager
        self.memoryManager = memoryManager
        self.timeZoneAwarenessProvider = timeZoneAwarenessProvider
        self.dateAmbienceProvider = dateAmbienceProvider
        self.weatherAmbienceProvider = weatherAmbienceProvider
        self.sleepAmbienceProvider = sleepAmbienceProvider
        self.locationProvider = locationProvider
        self.chatMessageStore = chatMessageStore
    }

    /// Same fields, same order of calls, that both call sites in
    /// `ConversationManager` used to compute independently.
    func assembleContext(
        userName: String,
        characterName: String,
        userBirthday: Date?
    ) async -> PromptSituationalContext {
        let dailyContext = await dailyContextManager.getCurrentDailyContextString()
        let characterStatus = await characterStatusManager.getCurrentStatus()

        let memoryContext = await memoryManager.getMemoryContext(
            userName: userName,
            characterName: characterName
        )

        let localTimeString = timeZoneAwarenessProvider.getLocalTimeString()
        let dateAmbience = dateAmbienceProvider.ambientPromptSnippet(userBirthday: userBirthday)
        let weatherAmbience = await weatherAmbienceProvider.ambientPromptSnippet(
            location: locationProvider.currentLocation
        )
        let sleepAmbience = await sleepAmbienceProvider.ambientPromptSnippet()
        let conversationGap = await conversationGapDescription()

        return PromptSituationalContext(
            dailyContext: dailyContext,
            characterStatus: characterStatus,
            memoryContext: memoryContext,
            localTimeString: localTimeString,
            dateAmbience: dateAmbience,
            weatherAmbience: weatherAmbience,
            sleepAmbience: sleepAmbience,
            conversationGap: conversationGap
        )
    }

    /// Moved verbatim from `ConversationManager.makeConversationGapDescription()`.
    private func conversationGapDescription() async -> String? {
        let snapshot = await chatMessageStore.loadConversationSnapshot()
        let lastActivity = snapshot.lastActivityAt
        let metrics = ContactSilenceMetrics(lastContactAt: lastActivity)

        // 小于 30 分钟不提示，避免频繁打扰
        guard metrics.wallClockHours * 3600 >= 30 * 60 else { return nil }

        let hours = Int(metrics.wallClockHours)
        let minutes = Int((metrics.wallClockHours * 3600).truncatingRemainder(dividingBy: 3600) / 60)

        let intervalText: String
        let openingHint: String
        switch metrics.careTone {
        case .multiDay where metrics.allowsMultiDayLanguage:
            intervalText = "\(max(metrics.calendarDaysApart, 2))天左右"
            openingHint = "可以说有点久没聊，但不要指责；不要夸张成更久"
        case .overnight:
            intervalText = "一夜/正常睡眠空档（墙钟约\(max(hours, 1))小时，不等于被冷落）"
            openingHint = "像睡醒或新的一天打招呼；禁止「几天」「很久没见」「好久不见」"
        case .sameDayLong:
            intervalText = hours >= 1 ? "同一天里约\(hours)小时（清醒时段约\(Int(metrics.awakeHours))小时）" : "\(minutes)分钟"
            openingHint = "可随口问在忙什么；禁止「几天」「很久」"
        case .light, .multiDay:
            if hours >= 3 {
                intervalText = "约\(hours)个多小时"
            } else if hours >= 1 {
                intervalText = "约\(hours)小时"
            } else {
                intervalText = "约\(minutes)分钟"
            }
            openingHint = "轻松接话即可；禁止「几天」「很久没见」"
        }

        return """
【时间感知】
距离上次对话大约\(intervalText)。请自然地意识到这一点——如果之前的话题已经过时（比如午饭、午休），不要继续追问，而是主动转换到新话题。\(openingHint)。夜间睡眠空档不是冷落。
"""
    }
}
