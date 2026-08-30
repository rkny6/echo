import Foundation

/// Shared silence metrics for proactive care + conversation gap prompts.
///
/// Wall-clock hours alone exaggerate overnight sleep as "cold-shouldering".
/// This type separates:
/// - wall-clock elapsed
/// - awake-window elapsed (typical night sleep subtracted)
/// - calendar days apart (for multi-day language gates)
struct ContactSilenceMetrics: Sendable, Equatable {
    /// Local quiet hours treated as normal sleep, not intentional silence.
    /// Interval is half-open: [nightStartHour, nightEndHour) wrapping midnight.
    static let defaultNightStartHour = 23
    static let defaultNightEndHour = 8

    let lastContactAt: Date
    let now: Date
    /// Full wall-clock hours since last user contact.
    let wallClockHours: Double
    /// Hours of silence outside the typical sleep window.
    let awakeHours: Double
    /// `0` same calendar day, `1` next day, `2+` multi-day.
    let calendarDaysApart: Int
    let nightStartHour: Int
    let nightEndHour: Int

    /// True only when silence truly spans multiple calendar days (at least 2 day boundaries).
    var allowsMultiDayLanguage: Bool { calendarDaysApart >= 2 }

    /// Overnight-only gap: last contact yesterday (or earlier same sleep cycle), not multi-day neglect.
    var isOvernightGap: Bool {
        calendarDaysApart == 1 && !allowsMultiDayLanguage
    }

    enum CareTone: String, Sendable {
        /// Short / same-day light contact.
        case light
        /// Same day but long awake gap.
        case sameDayLong
        /// Crossed one midnight; sleep window dominates — not 冷落.
        case overnight
        /// Real multi-day absence; multi-day wording allowed.
        case multiDay
    }

    var careTone: CareTone {
        if calendarDaysApart >= 2 || awakeHours >= 36 {
            return .multiDay
        }
        if calendarDaysApart >= 1 {
            // Next calendar day: treat as overnight/rest unless awake hours are huge.
            return awakeHours >= 20 ? .multiDay : .overnight
        }
        if awakeHours >= 10 || wallClockHours >= 12 {
            return .sameDayLong
        }
        return .light
    }

    init(
        lastContactAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        nightStartHour: Int = ContactSilenceMetrics.defaultNightStartHour,
        nightEndHour: Int = ContactSilenceMetrics.defaultNightEndHour
    ) {
        self.lastContactAt = lastContactAt
        self.now = now
        self.nightStartHour = nightStartHour
        self.nightEndHour = nightEndHour

        let wallSeconds = max(0, now.timeIntervalSince(lastContactAt))
        self.wallClockHours = wallSeconds / 3600

        let startDay = calendar.startOfDay(for: lastContactAt)
        let endDay = calendar.startOfDay(for: now)
        self.calendarDaysApart = max(
            0,
            calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        )

        self.awakeHours = Self.awakeSilenceHours(
            from: lastContactAt,
            to: now,
            calendar: calendar,
            nightStartHour: nightStartHour,
            nightEndHour: nightEndHour
        ) / 3600
    }

    /// Metadata for CompanionEvent / logs / prompt builders.
    var eventMetadata: [String: String] {
        [
            "hoursSinceContact": String(format: "%.1f", wallClockHours),
            "awakeHoursSinceContact": String(format: "%.1f", awakeHours),
            "calendarDaysApart": String(calendarDaysApart),
            "careTone": careTone.rawValue,
            "allowsMultiDayLanguage": allowsMultiDayLanguage ? "1" : "0"
        ]
    }

    // MARK: - Awake interval math

    /// Seconds of [from, to] that fall outside the nightly sleep window.
    static func awakeSilenceHours(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current,
        nightStartHour: Int = defaultNightStartHour,
        nightEndHour: Int = defaultNightEndHour
    ) -> TimeInterval {
        guard end > start else { return 0 }

        var totalAwake: TimeInterval = 0
        var cursor = start
        // Walk day-by-day; subtract sleep slices.
        while cursor < end {
            guard let nextMidnight = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: cursor)
            ) else { break }

            let sliceEnd = min(end, nextMidnight)
            let sleepInSlice = sleepOverlapSeconds(
                from: cursor,
                to: sliceEnd,
                calendar: calendar,
                nightStartHour: nightStartHour,
                nightEndHour: nightEndHour
            )
            let sliceLength = sliceEnd.timeIntervalSince(cursor)
            totalAwake += max(0, sliceLength - sleepInSlice)
            cursor = sliceEnd
        }
        return totalAwake
    }

    /// Sleep seconds inside [from, to] for the local night window.
    /// Night wraps midnight: e.g. 23:00–08:00 → [23:00, 24:00) ∪ [00:00, 08:00).
    static func sleepOverlapSeconds(
        from: Date,
        to: Date,
        calendar: Calendar,
        nightStartHour: Int,
        nightEndHour: Int
    ) -> TimeInterval {
        guard to > from else { return 0 }
        let dayStart = calendar.startOfDay(for: from)

        func date(hour: Int, dayOffset: Int = 0) -> Date {
            var comps = calendar.dateComponents([.year, .month, .day], from: dayStart)
            comps.hour = hour
            comps.minute = 0
            comps.second = 0
            let base = calendar.date(from: comps) ?? dayStart
            return calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        }

        // Two segments relative to `from`'s calendar day:
        // 1) early morning sleep of this day: [00:00, nightEnd)
        // 2) late night sleep starting this evening: [nightStart, next 00:00)
        // Plus early morning of next day if the slice crosses midnight — handled by day walk.
        var overlap: TimeInterval = 0

        let morningSleepStart = date(hour: 0)
        let morningSleepEnd = date(hour: nightEndHour)
        overlap += intervalOverlap(from, to, morningSleepStart, morningSleepEnd)

        let eveningSleepStart = date(hour: nightStartHour)
        let eveningSleepEnd = date(hour: 0, dayOffset: 1)
        overlap += intervalOverlap(from, to, eveningSleepStart, eveningSleepEnd)

        return overlap
    }

    private static func intervalOverlap(
        _ aStart: Date,
        _ aEnd: Date,
        _ bStart: Date,
        _ bEnd: Date
    ) -> TimeInterval {
        let start = max(aStart, bStart)
        let end = min(aEnd, bEnd)
        return max(0, end.timeIntervalSince(start))
    }
}
