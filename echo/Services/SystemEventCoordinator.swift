import Foundation

@MainActor
final class SystemEventCoordinator {
    private let eventDetectionService: EventDetecting
    private let conversationManager: ConversationManaging
    private let locationService: LocationProviding
    private let diaryService: DiaryService
    private let healthProactiveCoordinator: HealthProactiveCoordinator
    private let healthObserverService = HealthObserverService()
    private let logger: LoggingProviding
    /// Serial online-greeting catch-up after health (injected from composition root).
    private var onlineGreetingCatchUp: (() async -> Void)?

    init(
        eventDetectionService: EventDetecting,
        conversationManager: ConversationManaging,
        locationService: LocationProviding,
        diaryService: DiaryService,
        healthProactiveCoordinator: HealthProactiveCoordinator,
        logger: LoggingProviding
    ) {
        self.eventDetectionService = eventDetectionService
        self.conversationManager = conversationManager
        self.locationService = locationService
        self.diaryService = diaryService
        self.healthProactiveCoordinator = healthProactiveCoordinator
        self.logger = logger
    }

    func setOnlineGreetingCatchUp(_ handler: @escaping () async -> Void) {
        onlineGreetingCatchUp = handler
    }

    func startMonitoring() async {
        locationService.setLocationEventHandler { [weak self] event in
            guard let self = self else { return }
            await self.handleLocationEvent(event)
        }
        await locationService.requestLocationUpdates()

        await healthObserverService.startObservers {
            // Process right away, using whatever execution budget this
            // background wake has — deferring entirely to a separately
            // scheduled BGProcessingTask (see below) meant delivery
            // depended on iOS granting *two* background opportunities in a
            // row, which in practice often meant nothing actually went out
            // until the user happened to open the app.
            await self.healthProactiveCoordinator.handleHealthTrigger(processImmediately: true)
        }

        await BackgroundTaskService.shared.configureRefreshHandler {
            // Serial: health first, then date/diary, then online-greeting catch-up.
            await self.healthProactiveCoordinator.handleHealthTrigger(processImmediately: true)
            await self.evaluateNonHealthTriggers()
            await self.diaryService.generateDiaryIfNeeded()
            await self.onlineGreetingCatchUp?()
        }
        await BackgroundTaskService.shared.configureHealthProcessingHandler {
            // Safety net for any job that didn't finish processing within
            // the window it was first enqueued in (e.g. ran out of time) —
            // not the primary delivery path anymore.
            await self.healthProactiveCoordinator.processPendingJobs()
        }
        await BackgroundTaskService.shared.configureDiaryHandler {
            // Dedicated ~23:30 slot: the day is essentially over, so write
            // *today's* entry directly rather than waiting for the
            // post-midnight "yesterday" backfill path.
            await self.diaryService.generateDiaryIfNeeded(bypassTimeGate: true)
        }
        await BackgroundTaskService.shared.scheduleAppRefresh()
        await BackgroundTaskService.shared.scheduleDiaryGeneration()
    }

    /// Foreground / manual evaluation: health uses LLM-first pipeline; other events use conversation manager.
    func evaluateSystemTriggers() async {
        await healthProactiveCoordinator.handleHealthTrigger(processImmediately: true)
        await evaluateNonHealthTriggers()
        await diaryService.generateDiaryIfNeeded()
        await onlineGreetingCatchUp?()
    }

    private func evaluateNonHealthTriggers() async {
        do {
            let events = try await eventDetectionService.detectEvents()
            let nonHealth = events.filter { !Self.isHealthEvent($0) }
            if nonHealth.isEmpty {
                await logger.log("No non-health system events detected", level: .debug)
                return
            }

            await logger.log("Detected \(nonHealth.count) non-health events", level: .debug)
            let sorted = nonHealth.sorted { $0.priority > $1.priority }
            for event in sorted {
                try await conversationManager.handleIncomingEvent(event)
            }
        } catch {
            await logger.log("Non-health trigger evaluation failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleLocationEvent(_ event: CompanionEvent) async {
        await logger.log("Location event detected: \(event.type.rawValue)", level: .info)
        try? await conversationManager.handleIncomingEvent(event)
    }

    private static func isHealthEvent(_ event: CompanionEvent) -> Bool {
        switch event.type {
        case .sleep, .lowSteps, .highSteps, .lowHRV, .goodSteps, .goodHRV, .menstrualCycle:
            return true
        case .outing, .birthday, .weekend, .holiday, .onlineGreeting, .eveningCheckIn:
            return false
        }
    }
}
