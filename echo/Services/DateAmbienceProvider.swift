import Foundation

/// 结构化的日期氛围信息，用于按概率注入到 system prompt 中。
///
/// 设计目标：把"今天是周末/节日"这类信息从 *event 触发器* 降级为 *ambient context*，
/// 让 LLM 在自然对话中自己决定是否提及，而不是每次都强行发起一个"日期事件"对话。
struct DateAmbience: Sendable, Equatable {
    /// 今日日期类型标签，例如 "普通工作日"、"周末"、"法定节假日"、"调休工作日"
    let dateLabel: String
    /// 距离下一个特殊日子的天数（节日/生日），nil 表示无 upcoming
    let daysUntilSpecial: Int?
    /// 即将到来的特殊日子的描述，例如 "你的生日"、"国庆节"
    let upcomingSpecialLabel: String?
    /// 是否为用户的生日（当天）
    let isBirthdayToday: Bool

    init(
        dateLabel: String,
        daysUntilSpecial: Int?,
        upcomingSpecialLabel: String?,
        isBirthdayToday: Bool
    ) {
        self.dateLabel = dateLabel
        self.daysUntilSpecial = daysUntilSpecial
        self.upcomingSpecialLabel = upcomingSpecialLabel
        self.isBirthdayToday = isBirthdayToday
    }
}

/// 按概率生成日期氛围提示文本，用于注入 system prompt。
///
/// 注入策略：
/// - **生日当天**：100% 注入（强提示，但仍以 ambient 形式呈现，不发起独立 event）
/// - **节日当天**：约 60% 注入
/// - **周末**：约 35% 注入，且仅当距离上次提及 ≥ 6 小时
/// - **临近特殊日子（≤3 天）**：约 50% 注入倒计时提示
/// - **普通工作日 / 调休工作日**：不注入
struct DateAmbienceProvider: Sendable {
    private let dateContextManager: DateContextManager
    private let birthdayService: BirthdayDetectionService
    private let logger: LoggingProviding
    private let nowProvider: @Sendable () -> Date

    /// 注入概率配置（便于测试时固定）
    struct InjectionRates: Sendable {
        let holiday: Double
        let weekend: Double
        let upcomingSpecial: Double
        let weekendMentionCooldownHours: Int

        init(
            holiday: Double = 0.6,
            weekend: Double = 0.35,
            upcomingSpecial: Double = 0.5,
            weekendMentionCooldownHours: Int = 6
        ) {
            self.holiday = holiday
            self.weekend = weekend
            self.upcomingSpecial = upcomingSpecial
            self.weekendMentionCooldownHours = weekendMentionCooldownHours
        }
    }

    private let rates: InjectionRates
    private let rng: @Sendable () -> Double

    /// UserDefaults 键：记录上次"周末氛围"被注入的时间，避免短时间内重复提及
    private static let weekendLastMentionKey = "com.yourapp.dateambience.weekend.lastmention"

    init(
        dateContextManager: DateContextManager = .shared,
        birthdayService: BirthdayDetectionService = .shared,
        logger: LoggingProviding,
        rates: InjectionRates = InjectionRates(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        rng: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.dateContextManager = dateContextManager
        self.birthdayService = birthdayService
        self.logger = logger
        self.rates = rates
        self.nowProvider = nowProvider
        self.rng = rng
    }

    /// 构建当前日期氛围信息（不含概率逻辑，纯数据）
    func currentAmbience(userBirthday: Date?) -> DateAmbience {
        let now = nowProvider()
        let dateLabel = dateContextManager.getCurrentDateContextString()

        let isBirthdayToday: Bool = {
            guard let birthday = userBirthday else { return false }
            return birthdayService.isBirthday(birthday: birthday, date: now)
        }()

        // 临近特殊日子的倒计时（节日 / 生日），仅当 ≤3 天时返回
        let upcoming = upcomingSpecialWithinThreeDays(now: now, userBirthday: userBirthday)

        return DateAmbience(
            dateLabel: dateLabel,
            daysUntilSpecial: upcoming?.days,
            upcomingSpecialLabel: upcoming?.label,
            isBirthdayToday: isBirthdayToday
        )
    }

    /// 按概率决定是否将日期氛围注入到 system prompt。
    ///
    /// 返回 nil 表示本次不注入；返回非空字符串则应作为额外段落拼接到 system prompt。
    /// 调用方负责把返回值附加到 prompt 中（保持 PromptBuilder 的拼接职责单一）。
    func ambientPromptSnippet(userBirthday: Date?) -> String? {
        let ambience = currentAmbience(userBirthday: userBirthday)
        return snippet(for: ambience)
    }

    /// 纯函数：根据 ambience 和当前概率状态决定提示文本。便于测试。
    func snippet(for ambience: DateAmbience) -> String? {
        // 1. 生日当天：100% 注入
        if ambience.isBirthdayToday {
            return """
【今日特殊日子】
今天是她的生日。可以在合适的时候自然地送上祝福，但不要每条消息都提，更不要显得刻意或重复。
"""
        }

        // 2. 临近特殊日子（≤3 天）：按概率注入倒计时
        if let days = ambience.daysUntilSpecial,
           let label = ambience.upcomingSpecialLabel,
           days >= 1, days <= 3,
           rng() < rates.upcomingSpecial {
            return """
【日历提示】
再过\(days)天就是\(label)。如果对话自然涉及计划、休息、心情等话题，可以顺势提一句，不要生硬地"播报"。
"""
        }

        // 3. 节日当天：按概率注入
        if ambience.dateLabel == "法定节假日", rng() < rates.holiday {
            return """
【今日氛围】
今天是法定节假日。可以在合适的时候自然地体现节日氛围（比如问候、关心休息安排），但不要每条消息都强行关联，更不要重复"节日快乐"。
"""
        }

        // 4. 周末：按概率注入，且受冷却时间约束
        if ambience.dateLabel == "周末", rng() < rates.weekend {
            let now = nowProvider()
            if shouldSuppressWeekendMention(now: now) {
                return nil
            }
            markWeekendMentioned(now: now)
            return """
【今日氛围】
今天是周末。可以在合适的时候自然地体现周末的轻松感（比如聊聊休息、计划），但不要每条消息都强行关联"周末"这个词。
"""
        }

        return nil
    }

    // MARK: - 周末提及冷却

    private func shouldSuppressWeekendMention(now: Date) -> Bool {
        let last = UserDefaults.standard.object(forKey: Self.weekendLastMentionKey) as? Date
        guard let last else { return false }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < Double(rates.weekendMentionCooldownHours) * 3600
    }

    private func markWeekendMentioned(now: Date) {
        UserDefaults.standard.set(now, forKey: Self.weekendLastMentionKey)
    }

    // MARK: - 临近特殊日子的检测

    /// 返回 ≤3 天内的下一个特殊日子（仅生日）。
    /// 节日倒计时暂不在此处处理，因为 DateContextManager 不支持任意日期查询。
    private func upcomingSpecialWithinThreeDays(now: Date, userBirthday: Date?) -> (days: Int, label: String)? {
        // 生日倒计时：直接使用 daysUntilBirthday
        if let birthday = userBirthday {
            let days = birthdayService.daysUntilBirthday(birthday: birthday, date: now)
            if days >= 1, days <= 3 {
                return (days, "你的生日")
            }
        }
        return nil
    }
}
