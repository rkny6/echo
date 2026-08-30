import Foundation
import BackgroundTasks

@MainActor
final class BackgroundTaskService {
    static let shared = BackgroundTaskService()

    private let refreshTaskIdentifier = "com.echo.app.refresh"
    private let healthProcessingTaskIdentifier = "com.echo.app.health-processing"
    private let diaryTaskIdentifier = "com.echo.app.diary-refresh"
    // NOTE: this used to be a single `(() async -> Void)?` that got overwritten
    // every time `configureRefreshHandler` was called. Multiple call sites
    // (e.g. SystemEventCoordinator for health + other system-event checks) may
    // each register a handler; accumulating them here lets every registered
    // check run during a background wake-up.
    private var refreshHandlers: [() async -> Void] = []
    private var healthProcessingHandler: (() async -> Void)?
    /// Runs at the dedicated ~23:30 diary slot (see `scheduleDiaryGeneration`).
    /// Kept separate from `refreshHandlers` since it has its own schedule
    /// (next 23:30) rather than the "15 minutes from now" cadence used for
    /// general refresh checks.
    private var diaryHandler: (() async -> Void)?
    private var isRegistered = false

    private init() {}

    func registerBackgroundTasks() {
        guard !isRegistered else { return }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: healthProcessingTaskIdentifier, using: nil) { task in
            self.handleHealthProcessing(task: task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: diaryTaskIdentifier, using: nil) { task in
            self.handleDiaryRefresh(task: task as! BGAppRefreshTask)
        }

        isRegistered = true
    }

    func configureRefreshHandler(_ handler: @escaping () async -> Void) {
        refreshHandlers.append(handler)
    }

    func configureHealthProcessingHandler(_ handler: @escaping () async -> Void) {
        healthProcessingHandler = handler
    }

    func configureDiaryHandler(_ handler: @escaping () async -> Void) {
        diaryHandler = handler
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.error("BackgroundTaskService", "Failed to schedule app refresh: \(error.localizedDescription)")
        }
    }

    /// Schedules the diary-generation task for the next upcoming local
    /// 23:30 (today's if it hasn't passed yet, otherwise tomorrow's).
    /// Call this at app launch/foreground and again after every run so
    /// there's always a pending request for the *next* day's slot.
    ///
    /// Caveat: `earliestBeginDate` is a lower bound, not a guarantee — iOS
    /// decides the actual fire time based on device state and usage
    /// patterns, so this is a best-effort "around 23:30", not exact. The
    /// foreground catch-up (`generateDiaryIfNeeded()` on app activation)
    /// is the safety net for days this task doesn't fire at all.
    func scheduleDiaryGeneration() {
        let request = BGAppRefreshTaskRequest(identifier: diaryTaskIdentifier)
        request.earliestBeginDate = Self.nextDiaryGenerationDate()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.error("BackgroundTaskService", "Failed to schedule diary generation: \(error.localizedDescription)")
        }
    }

    static func nextDiaryGenerationDate(from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 23
        components.minute = 30
        components.second = 0

        guard let todayAt2330 = calendar.date(from: components) else {
            return now.addingTimeInterval(60 * 60)
        }
        if todayAt2330 > now {
            return todayAt2330
        }
        // Already past 23:30 today — target tomorrow's slot instead.
        return calendar.date(byAdding: .day, value: 1, to: todayAt2330)
            ?? now.addingTimeInterval(24 * 60 * 60)
    }

    func scheduleHealthProcessing() {
        let request = BGProcessingTaskRequest(identifier: healthProcessingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)

        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.debug("BackgroundTaskService", "Scheduled health processing task")
        } catch {
            AppLog.error("BackgroundTaskService", "Failed to schedule health processing: \(error.localizedDescription)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()

        let runningTask = Task {
            // Run every registered check concurrently so a slow one (e.g. an LLM
            // call) doesn't block the others from getting
            // a chance to run inside the ~30s background execution budget.
            await withTaskGroup(of: Void.self) { group in
                for handler in refreshHandlers {
                    group.addTask { await handler() }
                }
            }
        }

        task.expirationHandler = {
            runningTask.cancel()
            task.setTaskCompleted(success: false)
        }

        Task {
            await runningTask.value
            task.setTaskCompleted(success: true)
        }
    }

    private func handleDiaryRefresh(task: BGAppRefreshTask) {
        // Reschedule immediately for the next day's 23:30 slot regardless of
        // this run's outcome, so an expired/failed run doesn't leave diary
        // generation permanently unscheduled.
        scheduleDiaryGeneration()

        let runningTask = Task {
            await diaryHandler?()
        }

        task.expirationHandler = {
            runningTask.cancel()
            task.setTaskCompleted(success: false)
        }

        Task {
            await runningTask.value
            task.setTaskCompleted(success: true)
        }
    }

    private func handleHealthProcessing(task: BGProcessingTask) {
        scheduleHealthProcessing()
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task {
            if let handler = healthProcessingHandler {
                await handler()
                task.setTaskCompleted(success: true)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
    }
}
