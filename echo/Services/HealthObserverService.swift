import Foundation
import HealthKit

final class HealthObserverService {
    private let healthStore = HKHealthStore()
    private var triggerHandler: (() async -> Void)?

    func startObservers(triggerHandler: @escaping () async -> Void) async {
        self.triggerHandler = triggerHandler
        do {
            try await requestHealthKitAuthorization()
        } catch {
            AppLog.error("HealthObserver", "HealthKit authorization failed: \(error.localizedDescription)")
            return
        }
        registerObserver(for: HKQuantityType.quantityType(forIdentifier: .stepCount)!, sourceName: "stepCount")
        registerObserver(for: HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!, sourceName: "sleepAnalysis")
        registerObserver(for: HKCategoryType.categoryType(forIdentifier: .menstrualFlow)!, sourceName: "menstrualFlow")
        registerObserver(for: HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!, sourceName: "heartRateVariability")
    }

    func stopObservers() {
        // HealthKit observer queries continue to run under the same HKHealthStore instance.
        // There is currently no explicit query cancellation logic needed here.
        triggerHandler = nil
    }

    private func registerObserver(for sampleType: HKSampleType, sourceName: String) {
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                AppLog.error(
                    "HealthObserver",
                    "Observer query failed for \(sourceName): \(error!.localizedDescription)"
                )
                completionHandler()
                return
            }

            guard let self = self, let handler = self.triggerHandler else {
                completionHandler()
                return
            }

            Task {
                // Only tell HealthKit we're done once the actual work
                // (health check, possibly an LLM call and notification)
                // has finished — calling completionHandler() any earlier
                // signals iOS it's free to suspend us right away, which
                // was cutting the in-flight work off before it could
                // actually deliver anything.
                await handler()
                completionHandler()
            }
        }

        healthStore.execute(query)
        healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
            if let error = error {
                AppLog.error("HealthObserverService", "Failed background delivery for \(sourceName): \(error.localizedDescription)")
            } else if success {
                AppLog.debug("HealthObserverService", "Background delivery enabled for \(sourceName)")
            } else {
                AppLog.debug("HealthObserverService", "Background delivery not enabled for \(sourceName)")
            }
        }
    }

    private func requestHealthKitAuthorization() async throws {
        let typesToRead: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKCategoryType.categoryType(forIdentifier: .menstrualFlow)!,
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        ]

        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
    }
}
