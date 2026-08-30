import Foundation

/// "近期睡得不错" 氛围信息。
///
/// 这个信号故意走 ambience 模式，而不是像 lowSteps/sleep(过少过多) 那样触发
/// 一条专门的 proactive event/通知：那些是急性、需要及时关心的异常，而"最近
/// 一直睡得不错"是一个正向、不紧急的长期趋势观察，更适合角色在合适的话题里
/// 自然带一句（比如夸夸对方气色/作息），而不是专门为此打断对话发一条消息。
struct SleepAmbienceProvider: Sendable {
    private let healthDataService: HealthDataProviding
    private let logger: LoggingProviding
    private let nowProvider: @Sendable () -> Date
    private let rng: @Sendable () -> Double
    private let rates: InjectionRates

    struct InjectionRates: Sendable {
        let injectionProbability: Double
        let mentionCooldownDays: Int

        init(injectionProbability: Double = 0.3, mentionCooldownDays: Int = 5) {
            self.injectionProbability = injectionProbability
            self.mentionCooldownDays = mentionCooldownDays
        }
    }

    private static let lastMentionKey = "com.echo.sleepambience.lastmention"

    init(
        healthDataService: HealthDataProviding,
        logger: LoggingProviding,
        rates: InjectionRates = InjectionRates(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        rng: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.healthDataService = healthDataService
        self.logger = logger
        self.rates = rates
        self.nowProvider = nowProvider
        self.rng = rng
    }

    /// 按概率决定是否将"近期睡眠不错"氛围注入到 system prompt。
    /// 返回 nil 表示本次不注入（数据不足、趋势没有达标、或没抽中概率/在冷却期内）。
    func ambientPromptSnippet() async -> String? {
        guard await hasRecentGoodSleepStreak() == true else { return nil }
        guard rng() < rates.injectionProbability else { return nil }

        let now = nowProvider()
        guard !isWithinCooldown(now: now) else { return nil }
        markMentioned(now: now)

        return """
        【睡眠状态】
        她最近这段时间睡眠时长和质量一直比较稳定、不错。
        如果对话自然涉及状态、精神、作息这类话题，可以顺势提一句，比如夸夸她最近气色/作息不错；不需要每次都提，也不要生硬地报睡眠数据。
        """
    }

    /// Long-term / rolling sleep quality signal, distinct from the single-night
    /// extreme-alert check in EventDetectionService.extremeSleepEvent.
    /// - Returns: `true` if the trailing window has enough data and all of it
    ///   clears the "good" bar; `false` if there's enough data but it doesn't;
    ///   `nil` if there isn't enough recent data to draw a conclusion.
    func hasRecentGoodSleepStreak() async -> Bool? {
        guard let nights = try? await healthDataService.getSleepAnalysis(
            days: HealthProactiveThresholds.sleepTrendWindowDays
        ) else { return nil }

        let nightsWithData = nights.filter { $0.totalDurationMinutes > 0 }
        guard nightsWithData.count >= HealthProactiveThresholds.sleepTrendMinNightsWithData else {
            return nil
        }

        return nightsWithData.allSatisfy { night in
            night.totalDurationMinutes >= HealthProactiveThresholds.sleepTrendGoodMinDurationMinutes
                && (night.qualityScore ?? 0) >= HealthProactiveThresholds.sleepTrendGoodQualityThreshold
        }
    }

    // MARK: - Mention cooldown

    private func isWithinCooldown(now: Date) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastMentionKey) as? Date else { return false }
        return now.timeIntervalSince(last) < Double(rates.mentionCooldownDays) * 24 * 3600
    }

    private func markMentioned(now: Date) {
        UserDefaults.standard.set(now, forKey: Self.lastMentionKey)
    }
}
