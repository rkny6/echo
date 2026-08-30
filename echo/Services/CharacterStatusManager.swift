import Foundation

/// How a generated assistant reply should be paced / gated by online status.
enum ResponseDeliveryDecision: Sendable {
    /// Character is already online — deliver after a short human-like delay.
    case deliverNow(delay: TimeInterval)
    /// Character is offline but will come online early for this reply.
    /// Caller must invoke `comeOnline()` so UI status updates before delivery.
    case comeOnlineAndDeliver(delay: TimeInterval)
    /// Stay offline; park the reply until the next scheduled online window.
    case holdUntilOnline
}

/// Why the character transitioned to online.
enum OnlineTransitionReason: Sendable, Equatable {
    /// Entered a planned daily online window (or day-rollover into a window).
    case scheduledWindow
    /// Temporary online inserted to answer the user while otherwise offline.
    case earlyOnline
}

/// One online window for debug UI.
struct CharacterScheduleWindowDebug: Sendable, Identifiable, Equatable {
    let start: Date
    let end: Date
    let isActiveNow: Bool

    var id: String {
        "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    }
}

/// Snapshot of today's online schedule for the debug panel.
struct CharacterScheduleDebugInfo: Sendable, Equatable {
    let currentStatus: CharacterOnlineStatus
    let isConversationActive: Bool
    let lastOnlineWasEarly: Bool
    let dayStart: Date
    let windows: [CharacterScheduleWindowDebug]
    /// Sum of planned online windows (including temporary keep-online slices).
    let totalOnlineSeconds: TimeInterval
    let nextTransition: Date?
    let nextOnline: Date?
    let capturedAt: Date
}

/// A contiguous online period on the daily schedule.
struct OnlineWindow: Codable, Sendable, Equatable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// One calendar day's planned online windows (plus any temporary early-online windows).
struct DailyOnlineSchedule: Codable, Sendable, Equatable {
    /// Start of the calendar day this schedule belongs to.
    var dayStart: Date
    var windows: [OnlineWindow]

    func status(at date: Date) -> CharacterOnlineStatus {
        windows.contains { $0.contains(date) } ? .online : .offline
    }

    /// Next moment the online/offline state should flip after `date`, if any.
    func nextTransition(after date: Date) -> Date? {
        var candidates: [Date] = []
        for window in windows {
            if date < window.start {
                candidates.append(window.start)
            }
            if date < window.end {
                candidates.append(window.end)
            }
        }
        return candidates.min()
    }

    mutating func insertTemporaryWindow(start: Date, duration: TimeInterval) {
        let end = start.addingTimeInterval(duration)
        guard end > start else { return }
        windows.append(OnlineWindow(start: start, end: end))
        windows = Self.normalize(windows)
    }

    /// Sort, drop invalid, and merge overlapping / touching windows.
    static func normalize(_ windows: [OnlineWindow]) -> [OnlineWindow] {
        let valid = windows
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard var current = valid.first else { return [] }

        var merged: [OnlineWindow] = []
        for window in valid.dropFirst() {
            if window.start <= current.end {
                current.end = max(current.end, window.end)
            } else {
                merged.append(current)
                current = window
            }
        }
        merged.append(current)
        return merged
    }
}

actor CharacterStatusManager: CharacterStatusManaging {
    private let logger: LoggingProviding
    private var currentStatus: CharacterOnlineStatus = .offline
    private var schedule: DailyOnlineSchedule?
    private var transitionTask: Task<Void, Never>?
    private var onStatusChange: (@Sendable (CharacterOnlineStatus, OnlineTransitionReason?) async -> Void) = { _, _ in }
    /// True while the latest online state was caused by `comeOnline()` (temporary window).
    private var lastOnlineWasEarly: Bool = false
    /// Conversation is non-idle (user chat / reactive / follow-up).
    /// While true, schedule offline boundaries are soft-extended so the character
    /// does not suddenly drop offline mid-chat.
    private var isConversationActive = false

    /// Chance that an offline character comes online early just to answer.
    private static let earlyOnlineProbability: Double = 0.4
    /// Planned active day window (local time). Outside this is normally offline.
    private static let activeDayStartHour = 7
    private static let activeDayEndHour = 23
    private static let activeDayEndMinute = 30
    /// Temporary online duration after early-online for a reply.
    private static let earlyOnlineDurationRange: ClosedRange<TimeInterval> = (15 * 60)...(40 * 60)
    /// Soft keep-online slices while a conversation is still active past a window end.
    /// Re-armed at each boundary until the conversation returns to idle.
    private static let activeChatKeepOnlineRange: ClosedRange<TimeInterval> = (8 * 60)...(15 * 60)
    /// If chat is already active but character is offline, re-appear quickly.
    private static let activeChatReOnlineDelayRange: ClosedRange<TimeInterval> = 3...12

    private let defaults = UserDefaults.standard
    /// Bumped when generation policy changes so sparse/legacy day plans are discarded.
    private let scheduleKey = "CharacterDailyOnlineSchedule.v4"
    /// Previous schedule keys — cleared so stale short-day plans cannot linger.
    private let legacyScheduleKeys = [
        "CharacterDailyOnlineSchedule.v1",
        "CharacterDailyOnlineSchedule.v2",
        "CharacterDailyOnlineSchedule.v3"
    ]
    /// Legacy keys from the previous random/timer implementation — cleared on init.
    private let legacyStatusKey = "CharacterStatus"
    private let legacyStatusDateKey = "CharacterStatusDate"

    init(
        logger: LoggingProviding
    ) {
        self.logger = logger
        // Drop obsolete persistence from the pre-schedule system.
        defaults.removeObject(forKey: legacyStatusKey)
        defaults.removeObject(forKey: legacyStatusDateKey)
        for key in legacyScheduleKeys {
            defaults.removeObject(forKey: key)
        }

        if let loaded = Self.loadSchedule(from: defaults, key: scheduleKey),
           Calendar.current.isDateInToday(loaded.dayStart) {
            self.schedule = loaded
            self.currentStatus = loaded.status(at: Date())
        } else {
            let generated = Self.generateSchedule(for: Date())
            self.schedule = generated
            self.currentStatus = generated.status(at: Date())
            Self.saveSchedule(generated, to: defaults, key: scheduleKey)
        }
    }

    func setOnStatusChange(
        _ handler: @escaping @Sendable (CharacterOnlineStatus, OnlineTransitionReason?) async -> Void
    ) {
        onStatusChange = handler
    }

    func getCurrentStatus() async -> CharacterOnlineStatus {
        await ensureScheduleForToday()
        await syncStatusWithSchedule(reason: "getCurrentStatus")
        return currentStatus
    }

    /// Load/create today's schedule, publish current status, and arm boundary timers.
    func initializeStatus(for date: Date = Date()) async throws {
        await ensureScheduleForToday(reference: date)
        await syncStatusWithSchedule(reason: "initialize")
        await logScheduleSummary()
        await scheduleNextTransition()
        // Cold start: report current status without treating it as a fresh
        // offline→online jump (no online-greeting on launch).
        await onStatusChange(currentStatus, nil)
    }

    /// User activity no longer mutates the planned day schedule.
    /// Online/offline remains driven by windows; held replies flush on the next window.
    func userSentMessage() async throws {
        await ensureScheduleForToday()
        await syncStatusWithSchedule(reason: "userSentMessage")
        // Keep the transition timer healthy after long backgrounding.
        await scheduleNextTransition()
    }

    /// Keep CharacterStatusManager aware of non-idle conversation.
    /// Planned windows stay authoritative; this only soft-extends / quick-returns
    /// online while chat is active, then resumes the schedule on idle.
    func setConversationActive(_ active: Bool) async {
        let wasActive = isConversationActive
        isConversationActive = active
        guard wasActive != active else { return }

        await ensureScheduleForToday()

        if active {
            // Chat started while schedule says offline → re-online quickly
            // (do not wait for the next planned window).
            if schedule?.status(at: Date()) != .online {
                await extendOnlineForActiveChat(reason: "conversationBecameActive")
                await syncStatusWithSchedule(
                    reason: "conversationBecameActive",
                    forcedOnlineReason: .earlyOnline
                )
            } else {
                await syncStatusWithSchedule(reason: "conversationBecameActive")
            }
            await scheduleNextTransition()
            await logger.log("Conversation active: soft keep-online armed", level: .debug)
        } else {
            // Chat ended — allow schedule to take effect (may go offline now).
            await syncStatusWithSchedule(reason: "conversationBecameIdle")
            await scheduleNextTransition()
            await logger.log("Conversation idle: resumed pure schedule status", level: .debug)
        }
    }

    /// Decide how the just-generated assistant reply should be delivered.
    func decideResponseDelivery() async -> ResponseDeliveryDecision {
        await ensureScheduleForToday()
        await syncStatusWithSchedule(reason: "decideResponseDelivery")

        switch currentStatus {
        case .online:
            let delay = Double.random(in: 1...5)
            return .deliverNow(delay: delay)

        case .offline:
            // Mid-chat must not park the reply until a far-away planned window.
            if isConversationActive {
                let delay = Double.random(in: Self.activeChatReOnlineDelayRange)
                await logger.log(
                    "Delivery decision: active chat → quick early online after \(Int(delay))s",
                    level: .debug
                )
                return .comeOnlineAndDeliver(delay: delay)
            }

            if Double.random(in: 0...1) < Self.earlyOnlineProbability {
                let delay = Double.random(in: 20...120)
                await logger.log(
                    "Delivery decision: early online after \(Int(delay))s",
                    level: .debug
                )
                return .comeOnlineAndDeliver(delay: delay)
            }

            if let next = await nextOnlineDate() {
                await logger.log(
                    "Delivery decision: hold until next online at \(next)",
                    level: .debug
                )
            }
            return .holdUntilOnline
        }
    }

    /// Early-online path: insert a temporary online window starting now, update UI status.
    func comeOnline() async {
        await ensureScheduleForToday()
        let now = Date()
        let duration = Double.random(in: Self.earlyOnlineDurationRange)

        if var schedule {
            schedule.insertTemporaryWindow(start: now, duration: duration)
            self.schedule = schedule
            Self.saveSchedule(schedule, to: defaults, key: scheduleKey)
            await logger.log(
                "Inserted temporary online window for \(Int(duration))s (early online)",
                level: .debug
            )
        }

        lastOnlineWasEarly = true
        await syncStatusWithSchedule(reason: "comeOnline", forcedOnlineReason: .earlyOnline)
        await scheduleNextTransition()
    }

    /// Force offline now by closing any windows that currently cover `now`.
    func setOffline() async {
        await ensureScheduleForToday()
        let now = Date()
        guard var schedule else { return }

        var changed = false
        schedule.windows = schedule.windows.compactMap { window in
            guard window.contains(now) else { return window }
            changed = true
            // Truncate the active window so it ends immediately.
            if window.start < now {
                return OnlineWindow(start: window.start, end: now)
            }
            return nil
        }
        schedule.windows = DailyOnlineSchedule.normalize(schedule.windows)

        if changed {
            self.schedule = schedule
            Self.saveSchedule(schedule, to: defaults, key: scheduleKey)
            await logger.log("Forced offline by truncating active windows", level: .info)
        }

        await syncStatusWithSchedule(reason: "setOffline")
        await scheduleNextTransition()
    }

    /// True when today already entered (or is inside) a planned online window.
    /// Used by online-greeting catch-up when the process missed the live transition.
    /// Temporary early-online windows count once they exist on the schedule (persisted).
    func hasReachedPlannedOnlineWindow(at date: Date = Date()) async -> Bool {
        await ensureScheduleForToday(reference: date)
        guard let schedule else { return false }

        if schedule.status(at: date) == .online {
            return true
        }
        // Any window that has already started today (including finished ones).
        return schedule.windows.contains { $0.start <= date }
    }

    /// Next planned online start (for diagnostics / future UI).
    func nextOnlineDate(from date: Date = Date()) async -> Date? {
        await ensureScheduleForToday(reference: date)
        guard let schedule else { return nil }

        if let upcoming = schedule.windows
            .map(\.start)
            .filter({ $0 > date })
            .min() {
            return upcoming
        }

        // No more windows today — estimate tomorrow morning; exact windows are
        // generated when the day rolls over.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: schedule.dayStart)
            ?? date.addingTimeInterval(24 * 60 * 60)
        return Calendar.current.date(
            bySettingHour: Self.activeDayStartHour,
            minute: Int.random(in: 0...40),
            second: 0,
            of: tomorrow
        )
    }

    /// Debug panel: current status + today's online windows (including temporary keep-alive slices).
    func getScheduleDebugInfo(at date: Date = Date()) async -> CharacterScheduleDebugInfo {
        await ensureScheduleForToday(reference: date)
        // Do not call syncStatusWithSchedule here — reading should be side-effect free
        // for the debug UI (no keep-online extension purely from opening the panel).
        let schedule = self.schedule
        let rawWindows = schedule?.windows ?? []
        let windows = rawWindows.map { window in
            CharacterScheduleWindowDebug(
                start: window.start,
                end: window.end,
                isActiveNow: window.contains(date)
            )
        }
        let totalOnline = rawWindows.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return CharacterScheduleDebugInfo(
            currentStatus: currentStatus,
            isConversationActive: isConversationActive,
            lastOnlineWasEarly: lastOnlineWasEarly,
            dayStart: schedule?.dayStart ?? Calendar.current.startOfDay(for: date),
            windows: windows,
            totalOnlineSeconds: totalOnline,
            nextTransition: schedule?.nextTransition(after: date),
            nextOnline: await nextOnlineDate(from: date),
            capturedAt: date
        )
    }

    /// Debug-only: discard today's plan and roll a fresh schedule under current policy.
    func regenerateScheduleForDebug(at date: Date = Date()) async -> CharacterScheduleDebugInfo {
        let generated = Self.generateSchedule(for: date)
        schedule = generated
        Self.saveSchedule(generated, to: defaults, key: scheduleKey)
        // Re-evaluate status against the new plan (may flip online/offline).
        await syncStatusWithSchedule(reason: "debugRegenerate")
        await scheduleNextTransition()
        await logScheduleSummary()
        await logger.log(
            "Debug regenerated daily online schedule: \(generated.windows.count) window(s)",
            level: .info
        )
        return await getScheduleDebugInfo(at: date)
    }

    // MARK: - Schedule lifecycle

    private func ensureScheduleForToday(reference: Date = Date()) async {
        let dayStart = Calendar.current.startOfDay(for: reference)
        if let schedule, Calendar.current.isDate(schedule.dayStart, inSameDayAs: dayStart) {
            return
        }

        // Crossing midnight (or first load after a stale day): build a fresh day plan.
        let generated = Self.generateSchedule(for: reference)
        self.schedule = generated
        Self.saveSchedule(generated, to: defaults, key: scheduleKey)
        await logger.log(
            "Generated daily online schedule for \(dayStart): \(generated.windows.count) window(s)",
            level: .debug
        )
    }

    private func syncStatusWithSchedule(
        reason: String,
        forcedOnlineReason: OnlineTransitionReason? = nil
    ) async {
        guard schedule != nil else { return }

        // Active chat: never flip offline at a planned boundary. Insert a short
        // temporary online slice (schedule stays correct; idle resumes pure plan).
        var computed = schedule?.status(at: Date()) ?? .offline
        if computed == .offline && isConversationActive {
            await extendOnlineForActiveChat(reason: reason)
            computed = schedule?.status(at: Date()) ?? .online
            await logger.log(
                "Suppressed offline while conversation active (\(reason)); temporary online extended",
                level: .info
            )
        }

        guard computed != currentStatus else { return }

        let previous = currentStatus
        currentStatus = computed

        let transitionReason: OnlineTransitionReason?
        if computed == .online {
            if let forcedOnlineReason {
                transitionReason = forcedOnlineReason
                lastOnlineWasEarly = forcedOnlineReason == .earlyOnline
            } else if lastOnlineWasEarly {
                // Schedule still covers us because of a temporary window we just inserted.
                transitionReason = .earlyOnline
            } else if isConversationActive && previous == .offline {
                // Re-online purely to keep chatting — not a planned window greeting.
                transitionReason = .earlyOnline
                lastOnlineWasEarly = true
            } else {
                transitionReason = .scheduledWindow
                lastOnlineWasEarly = false
            }
        } else {
            transitionReason = nil
            lastOnlineWasEarly = false
        }

        await logger.log(
            "Character status changed: \(previous.rawValue) -> \(computed.rawValue) (\(reason)\(transitionReason.map { ", \($0)" } ?? ""))",
            level: .info
        )
        await onStatusChange(computed, transitionReason)
    }

    /// Append a short temporary online window starting now.
    /// Does not rewrite planned windows — only merges a keep-alive slice.
    private func extendOnlineForActiveChat(reason: String) async {
        let duration = Double.random(in: Self.activeChatKeepOnlineRange)
        guard var schedule else { return }
        let now = Date()
        schedule.insertTemporaryWindow(start: now, duration: duration)
        self.schedule = schedule
        Self.saveSchedule(schedule, to: defaults, key: scheduleKey)
        await logger.log(
            "Active-chat keep-online: +\(Int(duration / 60))m (reason=\(reason))",
            level: .debug
        )
    }

    private func scheduleNextTransition() async {
        transitionTask?.cancel()

        guard let schedule else { return }
        let now = Date()

        // If the day rolled over while we were sleeping, rebuild first.
        if !Calendar.current.isDateInToday(schedule.dayStart) {
            await ensureScheduleForToday()
            await syncStatusWithSchedule(reason: "dayRollover")
        }

        guard let currentSchedule = self.schedule else { return }

        let transitionDate: Date
        if let next = currentSchedule.nextTransition(after: now) {
            transitionDate = next
        } else {
            // Past the last boundary today — wake near tomorrow morning and
            // generate that day's schedule then (so we don't persist a peek).
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: currentSchedule.dayStart)
                ?? now.addingTimeInterval(24 * 60 * 60)
            transitionDate = Calendar.current.date(
                bySettingHour: Self.activeDayStartHour,
                minute: 0,
                second: 0,
                of: tomorrow
            ) ?? tomorrow
        }

        let delay = max(0.5, transitionDate.timeIntervalSince(now))

        await logger.log(
            "Next status transition in \(Int(delay))s at \(transitionDate) (currently \(currentStatus.rawValue))",
            level: .debug
        )

        transitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.handleTransitionFire()
        }
    }

    private func handleTransitionFire() async {
        await ensureScheduleForToday()
        await syncStatusWithSchedule(reason: "scheduleTransition")
        // If chat is still active we may have just appended a keep-online slice;
        // re-read schedule so the next timer lands on the new boundary.
        await scheduleNextTransition()
    }

    private func logScheduleSummary() async {
        guard let schedule else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let parts = schedule.windows.map {
            "\(formatter.string(from: $0.start))-\(formatter.string(from: $0.end))"
        }
        await logger.log(
            "Daily online schedule: [\(parts.joined(separator: ", "))] current=\(currentStatus.rawValue)",
            level: .debug
        )
    }

    // MARK: - Schedule generation

    /// Build 3–4 non-overlapping online windows inside 07:00–23:30 local time.
    ///
    /// Policy (v4): aim for **at least ~12h** total online (target 12–14h) across
    /// 3–4 blocks (~2.5–5h each), spread through the day with evening coverage
    /// so the character is present most of the active day.
    nonisolated private static func generateSchedule(for date: Date) -> DailyOnlineSchedule {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)

        guard
            let activeStart = calendar.date(bySettingHour: activeDayStartHour, minute: 0, second: 0, of: dayStart),
            let activeEnd = calendar.date(bySettingHour: activeDayEndHour, minute: activeDayEndMinute, second: 0, of: dayStart)
        else {
            return DailyOnlineSchedule(dayStart: dayStart, windows: [])
        }

        let activeDuration = activeEnd.timeIntervalSince(activeStart) // 16.5h (07:00–23:30)
        let windowCount = Int.random(in: 3...4)

        let minWindow: TimeInterval = 2.5 * 60 * 60     // 2.5h
        let maxWindow: TimeInterval = 5 * 60 * 60       // 5h (supports ≥12h totals)
        let minGap: TimeInterval = 15 * 60
        let maxGap: TimeInterval = 45 * 60

        // Leave slack for lead-in / trailing offline + inter-window gaps.
        let maxFeasibleOnline = max(
            minWindow * Double(windowCount),
            activeDuration - Double(windowCount - 1) * minGap - 20 * 60
        )
        // Prefer ≥12h online (up to ~14h); never request more than the day can hold.
        let minTotal = min(12 * 60 * 60, maxFeasibleOnline)
        let maxTotal = min(14 * 60 * 60, maxFeasibleOnline)
        let low = Int(minTotal)
        let high = max(low, Int(maxTotal))
        let targetTotal = TimeInterval(Int.random(in: low...high))

        // Split target across windows, then clamp per-window bounds.
        var durations = Array(repeating: targetTotal / Double(windowCount), count: windowCount)
        if windowCount > 1 {
            for i in 0..<(windowCount - 1) {
                let maxShift = durations[i] * 0.22
                let shiftBound = max(0, Int(maxShift))
                let shift = TimeInterval(Int.random(in: -shiftBound...shiftBound))
                durations[i] += shift
                durations[i + 1] -= shift
            }
        }
        durations = durations.map { min(maxWindow, max(minWindow, $0)) }

        // Scale to stay near target / feasible budget after clamping.
        var onlineSum = durations.reduce(0, +)
        if onlineSum > maxFeasibleOnline, onlineSum > 0 {
            let scale = maxFeasibleOnline / onlineSum
            durations = durations.map { max(minWindow, min(maxWindow, $0 * scale)) }
            onlineSum = durations.reduce(0, +)
        } else if onlineSum < minTotal, onlineSum > 0 {
            // Pull up toward at least ~12h when clamp left us short.
            let scale = min(maxFeasibleOnline, minTotal) / onlineSum
            durations = durations.map { min(maxWindow, max(minWindow, $0 * scale)) }
            onlineSum = durations.reduce(0, +)
        }

        // Offline budget = active day − online. Use part of it as lead-in + inter-gaps.
        let offlineBudget = max(Double(max(0, windowCount - 1)) * minGap, activeDuration - onlineSum)

        var interGaps: [TimeInterval] = []
        if windowCount > 1 {
            // ~45% of offline time sits between blocks so they don't all clump morning.
            var gapPool = max(Double(windowCount - 1) * minGap, offlineBudget * 0.45)
            for i in 0..<(windowCount - 1) {
                let gapsLeft = (windowCount - 1) - i
                if gapsLeft == 1 {
                    interGaps.append(min(maxGap, max(minGap, gapPool)))
                } else {
                    let maxThis = min(maxGap, gapPool - Double(gapsLeft - 1) * minGap)
                    let upper = max(Int(minGap), Int(maxThis))
                    let gap = TimeInterval(Int.random(in: Int(minGap)...upper))
                    interGaps.append(gap)
                    gapPool -= gap
                }
            }
        }

        let usedGaps = interGaps.reduce(0, +)
        // Keep lead-in modest so a 12h+ plan still reaches evening.
        let leadCap = max(0, min(45 * 60, offlineBudget - usedGaps - 10 * 60))
        let leadIn = TimeInterval(Int.random(in: 0...max(0, Int(leadCap))))

        var windows: [OnlineWindow] = []
        var cursor = activeStart.addingTimeInterval(leadIn)
        for i in 0..<windowCount {
            if cursor >= activeEnd.addingTimeInterval(-40 * 60) { break }
            let end = min(cursor.addingTimeInterval(durations[i]), activeEnd)
            if end.timeIntervalSince(cursor) >= 60 * 60 {
                windows.append(OnlineWindow(start: cursor, end: end))
            }
            if i < interGaps.count {
                cursor = end.addingTimeInterval(interGaps[i])
            } else {
                cursor = end
            }
        }

        // Hard fallback: three solid blocks totaling ≥12h if generation failed.
        if windows.isEmpty {
            let block: TimeInterval = 4 * 60 * 60
            let gap: TimeInterval = 30 * 60
            var t = activeStart.addingTimeInterval(15 * 60)
            for _ in 0..<3 {
                let end = min(t.addingTimeInterval(block), activeEnd)
                if end > t { windows.append(OnlineWindow(start: t, end: end)) }
                t = end.addingTimeInterval(gap)
                if t >= activeEnd { break }
            }
        }

        // If the day still ends before 18:00, append an evening presence block so
        // "next online" is not immediately tomorrow for most of the afternoon.
        if let last = windows.last,
           let eveningGate = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: dayStart),
           last.end < eveningGate {
            let eveningLead = TimeInterval(Int.random(in: 0...(30 * 60)))
            let eveningDuration = TimeInterval(Int.random(in: Int(2.5 * 60 * 60)...Int(3.5 * 60 * 60)))
            var eveningStart = eveningGate.addingTimeInterval(eveningLead)
            // Keep a small offline gap after the previous window when possible.
            if eveningStart < last.end.addingTimeInterval(15 * 60) {
                eveningStart = last.end.addingTimeInterval(15 * 60)
            }
            let eveningEnd = min(eveningStart.addingTimeInterval(eveningDuration), activeEnd)
            if eveningEnd.timeIntervalSince(eveningStart) >= 60 * 60 {
                windows.append(OnlineWindow(start: eveningStart, end: eveningEnd))
            }
        }

        // Final floor: if total online is still under 12h and the day has room,
        // extend the last window toward activeEnd (keeps policy promise).
        let floorOnline: TimeInterval = 12 * 60 * 60
        let totalAfter = windows.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        if totalAfter < floorOnline, var last = windows.last {
            let need = floorOnline - totalAfter
            let room = activeEnd.timeIntervalSince(last.end)
            if room > 0 {
                last.end = last.end.addingTimeInterval(min(need, room))
                windows[windows.count - 1] = last
            }
        }

        return DailyOnlineSchedule(
            dayStart: dayStart,
            windows: DailyOnlineSchedule.normalize(windows)
        )
    }

    // MARK: - Persistence

    nonisolated private static func loadSchedule(from defaults: UserDefaults, key: String) -> DailyOnlineSchedule? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DailyOnlineSchedule.self, from: data)
    }

    nonisolated private static func saveSchedule(_ schedule: DailyOnlineSchedule, to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults.set(data, forKey: key)
    }
}
