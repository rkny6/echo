import Foundation
import SwiftData

/// Primary event source for the conversation-first companion.
///
/// This actor is now the single event detection entrypoint for the app.
actor EventDetectionService: EventDetecting {
    private let healthDataService: HealthDataProviding
    private let locationService: LocationProviding
    private let profileService: any ProfileProviding
    private let dateContextManager: DateContextManager
    private let healthLLMService: HealthLLMGenerationService
    private let dateEventService: DateEventService   // 新增日期事件服务
    private let logger: LoggingProviding

    // UserDefaults 键名常量
    private static let birthdayTriggeredPrefix = "com.yourapp.birthday.triggered.year."
    private static let dateEventTriggeredKey = "com.yourapp.dateevent.triggered.today"

    init(
        healthDataService: HealthDataProviding,
        locationService: LocationProviding,
        profileService: any ProfileProviding,
        dateContextManager: DateContextManager = .shared,
        llmServiceFactory: LLMServiceFactory,
        promptBuilder: PromptBuilding,
        settingsService: SettingsProviding,
        chatMessageStore: ChatMessageStore,
        logger: LoggingProviding,
        timeZoneAwarenessProvider: TimeZoneAwarenessProvider
    ) {
        self.healthDataService = healthDataService
        self.locationService = locationService
        self.profileService = profileService
        self.dateContextManager = dateContextManager
        self.logger = logger
        
        self.healthLLMService = HealthLLMGenerationService(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: logger,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            profileService: profileService
        )
        
        self.dateEventService = DateEventService(
            llmServiceFactory: llmServiceFactory,
            promptBuilder: promptBuilder,
            settingsService: settingsService,
            chatMessageStore: chatMessageStore,
            logger: logger,
            timeZoneAwarenessProvider: timeZoneAwarenessProvider,
            profileService: profileService
        )
    }

    func detectEvents() async throws -> [CompanionEvent] {
        var events: [CompanionEvent] = []

        // ---- 原有事件检测（不变） ----
        // Detect outing
        if await locationService.isUserOut() {
            let event = CompanionEvent(
                type: .outing,
                priority: CompanionEventType.outing.defaultPriority,
                metadata: ["source": "location_change"]
            )
            events.append(event)
        }

        // Detect steps
        let stepCount = try await healthDataService.getTodayStepCount()
        if stepCount < 2000 {
            let event = CompanionEvent(
                type: .lowSteps,
                priority: CompanionEventType.lowSteps.defaultPriority,
                metadata: ["steps": String(stepCount)]
            )
            events.append(event)
        } else if stepCount > 10000 {
            let event = CompanionEvent(
                type: .highSteps,
                priority: CompanionEventType.highSteps.defaultPriority,
                metadata: ["steps": String(stepCount)]
            )
            events.append(event)
        }

        // Detect sleep issues
        let sleepData = try await healthDataService.getSleepAnalysis(days: 1)
        if let lastNight = sleepData.last,
           let quality = lastNight.qualityScore,
           quality < 0.5 {
            let event = CompanionEvent(
                type: .sleep,
                priority: CompanionEventType.sleep.defaultPriority,
                metadata: [
                    "quality": String(quality),
                    "duration": String(lastNight.totalDurationMinutes),
                    "deepSleep": String(lastNight.deepSleepMinutes ?? 0)
                ]
            )
            events.append(event)
        }

        // Detect menstrual cycle
        if let cycleData = try await healthDataService.getMenstrualCyclePrediction(),
           cycleData.isPredictionReliable,
           cycleData.daysUntilStart >= 0,
           cycleData.daysUntilStart <= HealthProactiveThresholds.menstrualApproachWindowDays {
            let event = CompanionEvent(
                type: .menstrualCycle,
                priority: CompanionEventType.menstrualCycle.defaultPriority,
                metadata: ["daysUntilStart": String(cycleData.daysUntilStart)]
            )
            events.append(event)
        }

        // ---- 新增：日期事件检测 ----
        let dateEvents = try await detectDateBasedEvents()
        events.append(contentsOf: dateEvents)

        return events
    }

    /// Health-only detection with extreme thresholds for proactive LLM notifications.
    func detectExtremeHealthEvents() async throws -> [CompanionEvent] {
        var events: [CompanionEvent] = []

        let stepCount = try await healthDataService.getTodayStepCount()
        let hour = Calendar.current.component(.hour, from: Date())
        await logger.log(
            "Health detect start hour=\(hour) steps=\(stepCount)",
            level: .debug
        )

        if hour >= HealthProactiveThresholds.stepsEvaluationHour,
           stepCount < HealthProactiveThresholds.stepsExtremelyLow {
            events.append(
                CompanionEvent(
                    type: .lowSteps,
                    priority: CompanionEventType.lowSteps.defaultPriority,
                    metadata: [
                        "steps": String(stepCount),
                        "severity": "extreme",
                        "source": "health_proactive"
                    ]
                )
            )
            await logger.log(
                "Health hit lowSteps extreme steps=\(stepCount) (<\(HealthProactiveThresholds.stepsExtremelyLow))",
                level: .debug
            )
        } else if stepCount > HealthProactiveThresholds.stepsExtremelyHigh {
            events.append(
                CompanionEvent(
                    type: .highSteps,
                    priority: CompanionEventType.highSteps.defaultPriority,
                    metadata: [
                        "steps": String(stepCount),
                        "severity": "extreme",
                        "source": "health_proactive"
                    ]
                )
            )
            await logger.log(
                "Health hit highSteps extreme steps=\(stepCount) (>\(HealthProactiveThresholds.stepsExtremelyHigh))",
                level: .debug
            )
        } else if hour < HealthProactiveThresholds.stepsEvaluationHour {
            await logger.log(
                "Health skip lowSteps: before evaluation hour (\(hour)<\(HealthProactiveThresholds.stepsEvaluationHour))",
                level: .debug
            )
        } else {
            await logger.log(
                "Health skip steps extreme: steps=\(stepCount) not outside [\(HealthProactiveThresholds.stepsExtremelyLow), \(HealthProactiveThresholds.stepsExtremelyHigh)]",
                level: .debug
            )
        }

        // Sleep: extreme (deterministic, after sync-safe hour) OR soft morning
        // care (pre-noon, probabilistic + multi-day cooldown — not every day).
        if hour < HealthProactiveThresholds.sleepSoftCareStartHour {
            await logger.log(
                "Health skip sleep: before soft window (\(hour)<\(HealthProactiveThresholds.sleepSoftCareStartHour))",
                level: .debug
            )
        } else {
            let sleepData = try await healthDataService.getSleepAnalysis(days: 1)
            if let lastNight = sleepData.last, lastNight.totalDurationMinutes > 0 {
                let quality = lastNight.qualityScore.map { String(format: "%.2f", $0) } ?? "nil"
                let deep = lastNight.deepSleepMinutes.map(String.init) ?? "nil"
                await logger.log(
                    "Health sleep night duration=\(lastNight.totalDurationMinutes)m quality=\(quality) deep=\(deep)m",
                    level: .debug
                )

                if hour >= HealthProactiveThresholds.sleepEvaluationHour {
                    if let sleepEvent = extremeSleepEvent(from: lastNight) {
                        events.append(sleepEvent)
                        await logger.log(
                            "Health hit sleep extreme reason=\(sleepEvent.metadata["reason"] ?? "?") duration=\(lastNight.totalDurationMinutes)m",
                            level: .debug
                        )
                    } else {
                        await logger.log(
                            "Health skip sleep extreme: night within extreme bars duration=\(lastNight.totalDurationMinutes)m quality=\(quality)",
                            level: .debug
                        )
                    }
                }

                // Soft care: morning window only; never replaces a hit extreme above.
                if hour < HealthProactiveThresholds.sleepSoftCareEndHour,
                   !events.contains(where: { $0.type == .sleep }) {
                    if let softEvent = softMorningSleepEvent(from: lastNight) {
                        events.append(softEvent)
                        await logger.log(
                            "Health hit sleep soft reason=\(softEvent.metadata["reason"] ?? "?") duration=\(lastNight.totalDurationMinutes)m",
                            level: .debug
                        )
                    }
                    // softMorningSleepEvent logs its own skip reasons (cooldown / lottery / bars).
                }
            } else {
                await logger.log("Health skip sleep: no last-night samples", level: .debug)
            }
        }

        if let hrvEvent = try? await extremeHRVEvent() {
            events.append(hrvEvent)
            await logger.log(
                "Health hit lowHRV ratio=\(hrvEvent.metadata["ratio"] ?? "?") today=\(hrvEvent.metadata["todayAverage"] ?? "?") baseline=\(hrvEvent.metadata["baselineAverage"] ?? "?")",
                level: .debug
            )
        } else {
            await logger.log("Health skip lowHRV: no sample or not below baseline bar", level: .debug)
        }

        if let goodStepsEvent = try? await goodStepsEvent() {
            events.append(goodStepsEvent)
            await logger.log(
                "Health hit goodSteps avg=\(goodStepsEvent.metadata["averageSteps"] ?? "?") days=\(goodStepsEvent.metadata["daysConsidered"] ?? "?")",
                level: .debug
            )
        } else {
            await logger.log("Health skip goodSteps: cooldown or trend bar not met", level: .debug)
        }

        if let goodHRVEvent = try? await goodHRVEvent() {
            events.append(goodHRVEvent)
            await logger.log(
                "Health hit goodHRV today=\(goodHRVEvent.metadata["todayAverage"] ?? "?") baseline=\(goodHRVEvent.metadata["baselineAverage"] ?? "?")",
                level: .debug
            )
        } else {
            await logger.log("Health skip goodHRV: cooldown or trend bar not met", level: .debug)
        }

        // Menstrual: reliable forecast only, approach window (days 0...N).
        // Once-per-cycle delivery is enforced via cycle-keyed HealthAlertDedup
        // (not daily), so the multi-day window cannot re-spam.
        if let menstrualEvent = try? await menstrualProactiveEvent() {
            events.append(menstrualEvent)
            await logger.log(
                "Health hit menstrualCycle daysUntil=\(menstrualEvent.metadata["daysUntilStart"] ?? "?") cycleKey=\(menstrualEvent.metadata["cycleKey"] ?? "?")",
                level: .debug
            )
        } else {
            await logger.log(
                "Health skip menstrualCycle: no reliable forecast or outside approach window",
                level: .debug
            )
        }

        if events.isEmpty {
            await logger.log("Health detect done: no candidates", level: .debug)
        } else {
            let summary = events
                .map { event in
                    let severity = event.metadata["severity"] ?? "-"
                    return "\(event.type.rawValue)(\(severity),p=\(event.priority))"
                }
                .joined(separator: ", ")
            await logger.log(
                "Health detect done: \(events.count) candidate(s): \(summary)",
                level: .debug
            )
        }

        return events
    }

    /// Proactive menstrual care for the health LLM pipeline (not the chat event path).
    /// Requires a reliable cycle forecast and fires only when the next period is
    /// within `menstrualApproachWindowDays` (including predicted start day = 0).
    private func menstrualProactiveEvent() async throws -> CompanionEvent? {
        guard let cycleData = try await healthDataService.getMenstrualCyclePrediction(),
              cycleData.isPredictionReliable else {
            return nil
        }

        let days = cycleData.daysUntilStart
        guard days >= 0,
              days <= HealthProactiveThresholds.menstrualApproachWindowDays else {
            return nil
        }

        let cycleKey = Self.menstrualCycleKey(for: cycleData.nextExpectedStartDate)

        return CompanionEvent(
            type: .menstrualCycle,
            priority: CompanionEventType.menstrualCycle.defaultPriority,
            metadata: [
                "daysUntilStart": String(days),
                "cycleLength": String(cycleData.cycleLength),
                "cycleKey": cycleKey,
                "severity": "care",
                "source": "health_proactive"
            ]
        )
    }

    /// Stable id for one predicted period (start-of-day of next expected start).
    private static func menstrualCycleKey(for nextExpectedStart: Date) -> String {
        let day = Calendar.current.startOfDay(for: nextExpectedStart)
        return String(Int(day.timeIntervalSince1970))
    }

    // MARK: - Positive trend detection ("looking good lately")
    //
    // Unlike the extreme-bad checks above, these fire on a positive,
    // non-urgent observation — so in addition to the normal per-day dedup
    // (HealthAlertRecord), they also check their own longer-lived cooldown
    // via UserDefaults, so "you've been doing great" doesn't repeat every
    // single day the streak continues.

    private static let goodStepsLastMentionKey = "com.echo.event.goodSteps.lastmention"
    private static let goodHRVLastMentionKey = "com.echo.event.goodHRV.lastmention"

    private func isWithinGoodTrendCooldown(
        key: String,
        days: Int = HealthProactiveThresholds.goodTrendMentionCooldownDays
    ) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return false }
        return Date().timeIntervalSince(last) < Double(days) * 24 * 3600
    }

    private func markGoodTrendMentioned(key: String) {
        UserDefaults.standard.set(Date(), forKey: key)
    }

    private func goodStepsEvent() async throws -> CompanionEvent? {
        guard !isWithinGoodTrendCooldown(key: Self.goodStepsLastMentionKey) else { return nil }

        let days = try await healthDataService.getStepCounts(days: HealthProactiveThresholds.stepsTrendWindowDays)
        let daysWithData = days.filter { $0.steps > 0 }
        guard daysWithData.count >= HealthProactiveThresholds.stepsTrendMinDaysWithData,
              daysWithData.allSatisfy({ $0.steps >= HealthProactiveThresholds.stepsTrendGoodMinSteps }) else {
            return nil
        }

        markGoodTrendMentioned(key: Self.goodStepsLastMentionKey)
        let averageSteps = daysWithData.map(\.steps).reduce(0, +) / daysWithData.count
        return CompanionEvent(
            type: .goodSteps,
            priority: CompanionEventType.goodSteps.defaultPriority,
            metadata: [
                "averageSteps": String(averageSteps),
                "daysConsidered": String(daysWithData.count),
                "source": "health_proactive"
            ]
        )
    }

    private func goodHRVEvent() async throws -> CompanionEvent? {
        guard !isWithinGoodTrendCooldown(key: Self.goodHRVLastMentionKey) else { return nil }

        let samples = try await healthDataService.getHeartRateVariability()
        guard !samples.isEmpty else { return nil }

        let calendar = Calendar.current
        let todaySamples = samples.filter { calendar.isDateInToday($0.timestamp) }
        let baselineSamples = samples.filter { !calendar.isDateInToday($0.timestamp) }
        guard !todaySamples.isEmpty,
              baselineSamples.count >= HealthProactiveThresholds.hrvMinBaselineSamples else {
            return nil
        }

        let todayAverage = todaySamples.map(\.value).reduce(0, +) / Double(todaySamples.count)
        let baselineAverage = baselineSamples.map(\.value).reduce(0, +) / Double(baselineSamples.count)
        guard baselineAverage > 0, (todayAverage / baselineAverage) >= HealthProactiveThresholds.hrvGoodRatioThreshold else {
            return nil
        }

        markGoodTrendMentioned(key: Self.goodHRVLastMentionKey)
        return CompanionEvent(
            type: .goodHRV,
            priority: CompanionEventType.goodHRV.defaultPriority,
            metadata: [
                "todayAverage": String(format: "%.1f", todayAverage),
                "baselineAverage": String(format: "%.1f", baselineAverage),
                "source": "health_proactive"
            ]
        )
    }

    /// Compares today's average HRV against this person's own trailing
    /// baseline (see HealthProactiveThresholds' HRV section for why an
    /// absolute threshold doesn't work here). Returns nil when there isn't
    /// enough data yet, or when today's value doesn't clear the "notably
    /// low" bar.
    private func extremeHRVEvent() async throws -> CompanionEvent? {
        let samples = try await healthDataService.getHeartRateVariability()
        guard !samples.isEmpty else { return nil }

        let calendar = Calendar.current
        let todaySamples = samples.filter { calendar.isDateInToday($0.timestamp) }
        let baselineSamples = samples.filter { !calendar.isDateInToday($0.timestamp) }

        guard !todaySamples.isEmpty,
              baselineSamples.count >= HealthProactiveThresholds.hrvMinBaselineSamples else {
            return nil
        }

        let todayAverage = todaySamples.map(\.value).reduce(0, +) / Double(todaySamples.count)
        let baselineAverage = baselineSamples.map(\.value).reduce(0, +) / Double(baselineSamples.count)
        guard baselineAverage > 0 else { return nil }

        let ratio = todayAverage / baselineAverage
        guard ratio <= HealthProactiveThresholds.hrvLowRatioThreshold else { return nil }

        return CompanionEvent(
            type: .lowHRV,
            priority: CompanionEventType.lowHRV.defaultPriority,
            metadata: [
                "todayAverage": String(format: "%.1f", todayAverage),
                "baselineAverage": String(format: "%.1f", baselineAverage),
                "ratio": String(format: "%.2f", ratio),
                "severity": "extreme",
                "source": "health_proactive"
            ]
        )
    }

    private static let softSleepLastMentionKey = "com.echo.event.softSleep.lastmention"

    private func extremeSleepEvent(from lastNight: SleepDataV2) -> CompanionEvent? {
        guard let assessment = assessSleepNight(
            lastNight,
            durationLow: HealthProactiveThresholds.sleepDurationExtremelyLowMinutes,
            durationHigh: HealthProactiveThresholds.sleepDurationExtremelyHighMinutes,
            qualityLow: HealthProactiveThresholds.sleepQualityExtremelyLow,
            deepPercentLow: HealthProactiveThresholds.deepSleepPercentExtremelyLow
        ) else {
            return nil
        }

        return CompanionEvent(
            type: .sleep,
            priority: CompanionEventType.sleep.defaultPriority,
            metadata: [
                "quality": String(assessment.quality),
                "duration": String(assessment.totalMinutes),
                "deepSleep": String(lastNight.deepSleepMinutes ?? 0),
                "severity": "extreme",
                "source": "health_proactive",
                "reason": assessment.reason
            ]
        )
    }

    /// Pre-noon, non-urgent sleep care when last night was imperfect but not extreme.
    /// Lottery + multi-day cooldown so it raises morning hit rate without daily spam.
    private func softMorningSleepEvent(from lastNight: SleepDataV2) -> CompanionEvent? {
        if isWithinGoodTrendCooldown(
            key: Self.softSleepLastMentionKey,
            days: HealthProactiveThresholds.sleepSoftCareCooldownDays
        ) {
            AppLog.debug(
                "EventDetection",
                "Health skip sleep soft: within \(HealthProactiveThresholds.sleepSoftCareCooldownDays)d cooldown"
            )
            return nil
        }

        // Never soft-care on a night that already qualifies as extreme — that
        // path is handled separately once sleepEvaluationHour is reached.
        if assessSleepNight(
            lastNight,
            durationLow: HealthProactiveThresholds.sleepDurationExtremelyLowMinutes,
            durationHigh: HealthProactiveThresholds.sleepDurationExtremelyHighMinutes,
            qualityLow: HealthProactiveThresholds.sleepQualityExtremelyLow,
            deepPercentLow: HealthProactiveThresholds.deepSleepPercentExtremelyLow
        ) != nil {
            AppLog.debug(
                "EventDetection",
                "Health skip sleep soft: night already qualifies as extreme (deferred to extreme path)"
            )
            return nil
        }

        guard let assessment = assessSleepNight(
            lastNight,
            durationLow: HealthProactiveThresholds.sleepDurationSoftLowMinutes,
            durationHigh: HealthProactiveThresholds.sleepDurationSoftHighMinutes,
            qualityLow: HealthProactiveThresholds.sleepQualitySoftLow,
            deepPercentLow: HealthProactiveThresholds.deepSleepPercentSoftLow
        ) else {
            AppLog.debug(
                "EventDetection",
                "Health skip sleep soft: within soft bars duration=\(lastNight.totalDurationMinutes)m"
            )
            return nil
        }

        let roll = Double.random(in: 0...1)
        guard roll < HealthProactiveThresholds.sleepSoftCareProbability else {
            AppLog.debug(
                "EventDetection",
                "Health skip sleep soft: lottery miss roll=\(String(format: "%.2f", roll)) p=\(HealthProactiveThresholds.sleepSoftCareProbability)"
            )
            return nil
        }

        // Burn cooldown when we decide to offer care (same pattern as goodSteps/goodHRV).
        markGoodTrendMentioned(key: Self.softSleepLastMentionKey)

        return CompanionEvent(
            type: .sleep,
            // Slightly below extreme sleep so true extremes still win if both appear.
            priority: max(1, CompanionEventType.sleep.defaultPriority - 1),
            metadata: [
                "quality": String(assessment.quality),
                "duration": String(assessment.totalMinutes),
                "deepSleep": String(lastNight.deepSleepMinutes ?? 0),
                "severity": "soft",
                "source": "health_proactive",
                "reason": assessment.reason
            ]
        )
    }

    private struct SleepNightAssessment {
        let totalMinutes: Int
        let quality: Double
        let reason: String
    }

    /// Shared duration / quality / deep-sleep checks for extreme and soft bars.
    private func assessSleepNight(
        _ lastNight: SleepDataV2,
        durationLow: Int,
        durationHigh: Int,
        qualityLow: Double,
        deepPercentLow: Double
    ) -> SleepNightAssessment? {
        let total = lastNight.totalDurationMinutes
        let quality = lastNight.qualityScore ?? 1.0

        let durationTooLow = total < durationLow
        let durationTooHigh = total > durationHigh
        let qualityTooLow = quality < qualityLow

        var deepPercentTooLow = false
        if let deep = lastNight.deepSleepMinutes, total > 0 {
            let deepPercent = Double(deep) / Double(total) * 100.0
            deepPercentTooLow = deepPercent < deepPercentLow
        }

        guard durationTooLow || durationTooHigh || qualityTooLow || deepPercentTooLow else {
            return nil
        }

        let reason: String
        if durationTooHigh {
            reason = "oversleep"
        } else if durationTooLow {
            reason = "undersleep"
        } else if qualityTooLow {
            reason = "low_quality"
        } else {
            reason = "low_deep"
        }

        return SleepNightAssessment(
            totalMinutes: total,
            quality: quality,
            reason: reason
        )
    }

    // MARK: - 事件处理（新增）

    /// 根据事件类型选择合适的服务生成消息。返回 nil 表示 LLM 调用失败，应跳过、不发送任何消息。
    func generateMessage(for event: CompanionEvent) async -> String? {
        // 健康事件使用健康服务，其余非健康事件走日期事件服务。
        if event.type.isHealthEventType {
            return await healthLLMService.generateMessage(for: event)
        } else {
            return await dateEventService.generateMessage(for: event)
        }
    }

    // MARK: - 日期事件检测（新增）

    /// 检测生日等日期相关事件。
    ///
    /// 设计变更（2026-07）：周末 / 法定节假日 不再作为独立 event 触发，
    /// 而是通过 `DateAmbienceProvider` 按概率注入到 system prompt 中，
    /// 让 LLM 在自然对话中自己决定是否提及，避免每天一次的"硬触发"对话。
    /// 生日因为一年一次、情感意义强，仍保留为独立 event。
    internal func detectDateBasedEvents() async throws -> [CompanionEvent] {
        let now = Date()
        let calendar = Calendar.current
        let todayKey = Self.dateEventTriggeredKey

        // 检查今天是否已经触发过日期事件（避免重复）
        if UserDefaults.standard.bool(forKey: todayKey) {
            return []  // 今天已触发过，不再重复生成
        }

        var events: [CompanionEvent] = []

        // 1. 生日检测（一年一次，仍作为独立 event）
        if let birthday = try await fetchUserBirthday() {
            let birthdayService = BirthdayDetectionService.shared
            if birthdayService.isBirthday(birthday: birthday, date: now) {
                let year = calendar.component(.year, from: now)
                let birthdayKey = Self.birthdayTriggeredPrefix + String(year)

                // 检查今年是否已经触发过生日事件
                if !UserDefaults.standard.bool(forKey: birthdayKey) {
                    let event = CompanionEvent(
                        type: .birthday,
                        priority: CompanionEventType.birthday.defaultPriority,
                        metadata: ["source": "birthday_detection"]
                    )
                    events.append(event)

                    // 标记今年生日已触发
                    UserDefaults.standard.set(true, forKey: birthdayKey)
                }
            }
        }

        // 2. 节假日 / 周末不再作为独立 event 触发
        // 这些信息已通过 DateAmbienceProvider 按概率注入到 system prompt 中，
        // 让 LLM 在自然对话中决定是否提及。详见 DateAmbienceProvider。

        // 如果有任何日期事件被触发，标记今天已处理（防止同一天重复触发）
        if !events.isEmpty {
            UserDefaults.standard.set(true, forKey: todayKey)
        }

        return events
    }

    /// 从 ProfileService 获取用户生日
    internal func fetchUserBirthday() async throws -> Date? {
        await profileService.userBirthday()
    }

    // MARK: - 测试方法（不变）

    func triggerEventForTesting(_ type: CompanionEventType) async throws {
        let _ = CompanionEvent(
            type: type,
            metadata: ["source": "manual_test"]
        )
        // Event would be persisted elsewhere
    }
}