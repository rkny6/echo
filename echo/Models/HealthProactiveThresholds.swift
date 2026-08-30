import Foundation

/// Thresholds for extreme health events that qualify for proactive LLM notifications.
enum HealthProactiveThresholds {
    /// Only evaluate low-step alerts after this hour (local time).
    static let stepsEvaluationHour = 18

    static let stepsExtremelyLow = 1500
    static let stepsExtremelyHigh = 18000

    /// Extreme short-sleep bar (~6.5h).
    static let sleepDurationExtremelyLowMinutes = 390
    static let sleepDurationExtremelyHighMinutes = 600
    static let sleepQualityExtremelyLow = 0.35
    static let deepSleepPercentExtremelyLow = 5.0
    /// Only evaluate sleep-extreme alerts after this hour (local time). Apple
    /// Watch syncs sleep samples incrementally overnight (the sleepAnalysis
    /// HealthKit observer fires with frequency: .immediate), so without this
    /// gate a partial, still-in-progress sleep session (e.g. 90 minutes
    /// logged by 1am) reads as "extremely low duration" and can trigger a
    /// false "you slept too little" alert while the user is still asleep.
    static let sleepEvaluationHour = 10

    // MARK: - Soft morning sleep care (pre-noon, non-daily)
    //
    // Milder than the extreme thresholds above: raises the chance of a
    // morning "how did you sleep" proactive when last night was imperfect but
    // not extreme. Gated to the morning window + lottery + multi-day cooldown
    // so it does not fire every day.

    /// Local hour (inclusive) when soft morning sleep care may start evaluating.
    static let sleepSoftCareStartHour = 8
    /// Soft care only before this local hour (exclusive) — morning only.
    static let sleepSoftCareEndHour = 12
    /// Mild short-sleep bar (~7.5h). Stricter extreme is 6.5h.
    static let sleepDurationSoftLowMinutes = 450
    /// Mild long-sleep bar (~9h). Extreme is 10h.
    static let sleepDurationSoftHighMinutes = 540
    /// Mild quality bar. Extreme is 0.35.
    static let sleepQualitySoftLow = 0.50
    /// Mild deep-sleep share (%). Extreme is 5%.
    static let deepSleepPercentSoftLow = 10.0
    /// Probability of offering soft sleep care when thresholds match and cooldown is clear.
    static let sleepSoftCareProbability = 0.40
    /// Minimum days between soft (non-extreme) sleep proactive messages.
    static let sleepSoftCareCooldownDays = 3

    /// Trailing window used for the long-term / rolling sleep quality signal
    /// (as opposed to the single-night extreme check above).
    static let sleepTrendWindowDays = 7
    /// Minimum number of nights with actual data in the trailing window
    /// before we're willing to call it a "good sleep streak" — avoids
    /// drawing a conclusion from 1-2 nights of data.
    static let sleepTrendMinNightsWithData = 5
    static let sleepTrendGoodQualityThreshold = 0.65
    static let sleepTrendGoodMinDurationMinutes = 360 // 6 hours

    // MARK: - HRV
    //
    // HRV has huge person-to-person variation (a healthy resting SDNN can be
    // anywhere from ~20ms to ~100+ms depending on age/fitness/genetics), so
    // unlike steps there's no meaningful universal absolute threshold. Both
    // the extreme-low alert and the "trend looks good" ambience below judge
    // today's value against *this person's own* recent baseline instead.

    /// Trailing lookback for the HRV baseline (matches getHeartRateVariability()'s window).
    static let hrvBaselineWindowDays = 7
    /// Minimum number of prior-day samples needed before we trust the baseline enough to alert on it.
    static let hrvMinBaselineSamples = 3
    /// Today's average HRV at or below this fraction of the personal baseline counts as "notably low".
    static let hrvLowRatioThreshold = 0.70
    /// Today's average HRV at or above this fraction of the personal baseline counts as "holding up well".
    static let hrvGoodRatioThreshold = 0.95

    // MARK: - Activity trend (steps), for the "recent activity has been good" ambience
    static let stepsTrendWindowDays = 7
    static let stepsTrendMinDaysWithData = 5
    static let stepsTrendGoodMinSteps = 6000

    /// goodSteps/goodHRV are "the streak is holding" observations, not
    /// one-off happenings — HealthAlertRecord's per-day dedup alone would
    /// still let them re-fire every single day the streak continues, which
    /// gets repetitive fast. This is a separate, longer cooldown checked
    /// inside the detection functions themselves.
    static let goodTrendMentionCooldownDays = 4

    // MARK: - Menstrual proactive
    //
    // Unlike sleep/steps (daily observations), menstrual care is once per
    // predicted cycle. Detection uses a reliable forecast and the approach
    // window; delivery dedup is keyed by predicted period start day so the
    // 1–3 day window cannot fire again on later days of the same cycle.

    /// Care when next period is this many days away (inclusive of 0 = day-of).
    static let menstrualApproachWindowDays = 3

    static let maxLLMRetries = 3
    static let llmMaxTokens = 80
    static let llmTimeoutSeconds: TimeInterval = 25
}

enum HealthAlertDedup {
    /// Default per-calendar-day key for one-shot daily health alerts.
    static func key(for eventType: CompanionEventType, date: Date = Date()) -> String {
        let day = Calendar.current.startOfDay(for: date)
        return "\(eventType.rawValue)_\(Int(day.timeIntervalSince1970))"
    }

    /// Event-aware key. Menstrual uses predicted cycle start (`cycleKey` metadata)
    /// so care fires at most once per cycle, not once per day in the approach window.
    static func key(for event: CompanionEvent, date: Date = Date()) -> String {
        if event.type == .menstrualCycle,
           let cycleKey = event.metadata["cycleKey"],
           !cycleKey.isEmpty {
            return "\(event.type.rawValue)_cycle_\(cycleKey)"
        }
        return key(for: event.type, date: date)
    }
}
