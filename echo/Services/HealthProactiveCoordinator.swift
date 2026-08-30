import Foundation
import SwiftData

/// Shared entry point for health proactive delivery (foreground, HealthKit wake, BG tasks).
///
/// Constructed once in the composition root (`VirtualCompanionApp`) and
/// passed into every consumer's initializer (`AppViewModel`,
/// `SystemEventCoordinator`) — never reached via a global. That way a
/// consumer either has a working reference or fails to compile; it can't
/// silently no-op because something ran before a global got assigned.
actor HealthProactiveCoordinator {
    private var deliveryService: HealthProactiveDeliveryService?

    func configure(
        deliveryService: HealthProactiveDeliveryService
    ) async {
        self.deliveryService = deliveryService
    }

    func setOnMessageInserted(_ handler: @escaping @Sendable () async -> Void) async {
        await deliveryService?.setOnMessageInserted(handler)
    }

    func handleHealthTrigger(processImmediately: Bool) async {
        guard let deliveryService else {
            AppLog.debug("HealthProactiveCoordinator", "Not configured; skipping health trigger")
            return
        }

        AppLog.debug(
            "HealthProactiveCoordinator",
            "handleHealthTrigger processImmediately=\(processImmediately)"
        )
        await deliveryService.evaluateAndEnqueue(
            processImmediately: processImmediately
        )
    }


    func healthCareStoryState() async -> HealthCareStoryState {
        guard let deliveryService else { return .none }
        return await deliveryService.healthCareStoryState()
    }

    func processPendingJobs() async {
        guard let deliveryService else { return }
        await deliveryService.processPendingJobs()
    }
}
