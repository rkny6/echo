import Foundation
import Testing
@testable import echo

struct ContactSilenceMetricsTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)! // Asia/Shanghai-like fixed
        return cal
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        comps.minute = min
        return calendar.date(from: comps)!
    }

    @Test func overnightSleepIsNotMultiDayNeglect() {
        // Last chat 23:30, next morning 08:30 → wall ~9h, mostly sleep window.
        let last = date(2026, 7, 23, 23, 30)
        let now = date(2026, 7, 24, 8, 30)
        let metrics = ContactSilenceMetrics(
            lastContactAt: last,
            now: now,
            calendar: calendar
        )

        #expect(metrics.calendarDaysApart == 1)
        #expect(metrics.allowsMultiDayLanguage == false)
        #expect(metrics.careTone == .overnight)
        // Awake hours should be far below wall-clock (most of gap is 23–08 sleep).
        #expect(metrics.awakeHours < metrics.wallClockHours)
        #expect(metrics.awakeHours < 2.5)
    }

    @Test func multiDaySilenceAllowsMultiDayLanguage() {
        let last = date(2026, 7, 21, 20, 0)
        let now = date(2026, 7, 24, 9, 0)
        let metrics = ContactSilenceMetrics(
            lastContactAt: last,
            now: now,
            calendar: calendar
        )

        #expect(metrics.calendarDaysApart >= 2)
        #expect(metrics.allowsMultiDayLanguage == true)
        #expect(metrics.careTone == .multiDay)
    }

    @Test func sameDayLongGapDoesNotUseDaysLanguage() {
        let last = date(2026, 7, 24, 8, 0)
        let now = date(2026, 7, 24, 21, 0)
        let metrics = ContactSilenceMetrics(
            lastContactAt: last,
            now: now,
            calendar: calendar
        )

        #expect(metrics.calendarDaysApart == 0)
        #expect(metrics.allowsMultiDayLanguage == false)
        #expect(metrics.careTone == .sameDayLong || metrics.careTone == .light)
        #expect(metrics.awakeHours >= 12) // no sleep window mid-day 08–21
    }

    @Test func eventDescriptionOvernightForbidsDaysWording() {
        let last = date(2026, 7, 23, 23, 0)
        let now = date(2026, 7, 24, 8, 0)
        let metrics = ContactSilenceMetrics(lastContactAt: last, now: now, calendar: calendar)
        let event = CompanionEvent(
            type: .onlineGreeting,
            metadata: metrics.eventMetadata.merging(["source": "online_greeting"]) { _, n in n }
        )
        let text = EventMessageService.describe(event)
        #expect(text.contains("睡眠") || text.contains("夜间"))
        #expect(!text.contains("跨过至少两天"))
        #expect(text.contains("禁止") || text.contains("不是被冷落"))
    }

    @Test func eveningDescriptionMultiDayOnlyWhenAllowed() {
        let last = date(2026, 7, 21, 12, 0)
        let now = date(2026, 7, 24, 21, 30)
        let metrics = ContactSilenceMetrics(lastContactAt: last, now: now, calendar: calendar)
        let event = CompanionEvent(
            type: .eveningCheckIn,
            metadata: metrics.eventMetadata.merging(["source": "evening_check_in"]) { _, n in n }
        )
        let text = EventMessageService.describe(event)
        #expect(metrics.allowsMultiDayLanguage)
        #expect(text.contains("跨过至少两天") || text.contains("两天"))
    }
}
