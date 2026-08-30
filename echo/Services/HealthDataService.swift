import Foundation
import HealthKit

/// Service for reading health data from HealthKit
actor HealthDataService: HealthDataProviding {
    private let healthStore = HKHealthStore()
    
    // MARK: - Menstrual cycle tuning constants
    
    /// Historical lookback for fetching menstrual flow samples (1 year)
    private static let menstrualHistoryMonths = 12
    /// Window used when evaluating cycle-length variability
    private static let menstrualVariabilityMonths = 6
    /// Max standard deviation (days) across recent cycles to treat a prediction as reliable
    private static let maxCycleLengthStdDevDays = 5.0
    /// Minimum gap between period start dates when clustering flow days into cycles
    private static let minDaysBetweenPeriodStarts = 15
    /// Valid cycle length range (days) for inclusion in averages
    private static let validCycleLengthRange = 15...40
    /// Default luteal phase length used when refining prediction from ovulation tests
    private static let defaultLutealPhaseDays = 14
    
    init() {}
    
    // MARK: - Health Data Queries
    
    func getTodayStepCount() async throws -> Int {
        try await requestHealthKitAuthorization()
        
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)

        AppLog.debug("HealthDataService", "Reading today step count from HealthKit from \(startOfDay) to \(now)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepsType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error = error {
                    AppLog.error("HealthDataService", "Failed to read today step count: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let result = result else {
                    AppLog.debug("HealthDataService", "No step count result returned, defaulting to 0")
                    continuation.resume(returning: 0)
                    return
                }
                
                let steps = Int(result.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0)
                AppLog.debug("HealthDataService", "Read today step count: \(steps)")
                continuation.resume(returning: steps)
            }
            healthStore.execute(query)
        }
    }
    
    /// Per-day step totals for the past N days (today included), used for the
    /// rolling activity-trend ambience signal — distinct from
    /// getTodayStepCount()'s single-day read.
    func getStepCounts(days: Int) async throws -> [DailyStepCount] {
        try await requestHealthKitAuthorization()

        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)

        AppLog.debug("HealthDataService", "Reading step counts from HealthKit from \(startDate) to \(now)")

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepsType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: startDate,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, error in
                if let error = error {
                    AppLog.error("HealthDataService", "Failed to read step counts: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                guard let results = results else {
                    continuation.resume(returning: [])
                    return
                }
                var dailyCounts: [DailyStepCount] = []
                results.enumerateStatistics(from: startDate, to: now) { statistics, _ in
                    let steps = Int(statistics.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0)
                    dailyCounts.append(DailyStepCount(date: statistics.startDate, steps: steps))
                }
                AppLog.debug("HealthDataService", "Fetched \(dailyCounts.count) daily step total(s)")
                continuation.resume(returning: dailyCounts)
            }
            healthStore.execute(query)
        }
    }

    /// Reads sleep analysis samples and aggregates per wake-day with optional stage breakdown.
    ///
    /// On iOS 16+, `HKCategoryValueSleepAnalysis` exposes deep/core/REM stages.
    /// On earlier OS versions only `.asleep` and `.inBed` are available; stage fields are nil
    /// and quality falls back to the duration-based heuristic.
    func getSleepAnalysis(days: Int) async throws -> [SleepDataV2] {
        try await requestHealthKitAuthorization()

        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now)!
        AppLog.debug("HealthDataService", "Reading staged sleep analysis for the last \(days) day(s) from \(startDate) to \(now)")
        
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            AppLog.debug("HealthDataService", "sleepAnalysis type unavailable; returning empty sleep data")
            return []
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        let samples = try await fetchCategorySamples(type: sleepType, predicate: predicate, sortDescriptors: [sortDescriptor])
        AppLog.debug("HealthDataService", "Fetched \(samples.count) sleep analysis sample(s)")
        
        // Aggregate by wake day (calendar day of sample end) so overnight sessions map to the morning date.
        var dailyStages: [Date: SleepStageAccumulator] = [:]
        var hasStagedSamples = false
        
        for sample in samples {
            let wakeDay = calendar.startOfDay(for: sample.endDate)
            let durationMinutes = max(0, Int(sample.endDate.timeIntervalSince(sample.startDate) / 60))
            var accumulator = dailyStages[wakeDay] ?? SleepStageAccumulator()
            
            if #available(iOS 16.0, *) {
                switch sample.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    accumulator.deep += durationMinutes
                    accumulator.asleepTotal += durationMinutes
                    hasStagedSamples = true
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                    accumulator.core += durationMinutes
                    accumulator.asleepTotal += durationMinutes
                    hasStagedSamples = true
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    accumulator.rem += durationMinutes
                    accumulator.asleepTotal += durationMinutes
                    hasStagedSamples = true
                case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                    accumulator.unspecifiedAsleep += durationMinutes
                    accumulator.asleepTotal += durationMinutes
                case HKCategoryValueSleepAnalysis.awake.rawValue:
                    break // awake intervals are not counted toward total sleep
                case HKCategoryValueSleepAnalysis.inBed.rawValue:
                    break // inBed is not actual sleep
                default:
                    break
                }
            } else {
                switch sample.value {
                case HKCategoryValueSleepAnalysis.asleep.rawValue:
                    accumulator.unspecifiedAsleep += durationMinutes
                    accumulator.asleepTotal += durationMinutes
                case HKCategoryValueSleepAnalysis.awake.rawValue, HKCategoryValueSleepAnalysis.inBed.rawValue:
                    break
                default:
                    break
                }
            }
            
            dailyStages[wakeDay] = accumulator
        }
        
        AppLog.debug(
            "HealthDataService",
            "Sleep aggregation: \(dailyStages.count) wake-day bucket(s), staged samples present: \(hasStagedSamples)"
        )
        
        // Build one entry per day in the requested range (ascending) for stable `.last` semantics.
        var results: [SleepDataV2] = []
        for dayOffset in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now)) else {
                continue
            }
            let accumulator = dailyStages[day] ?? SleepStageAccumulator()
            let totalMinutes = accumulator.asleepTotal
            
            let deepMinutes: Int?
            let coreMinutes: Int?
            let remMinutes: Int?
            
            if hasStagedSamples {
                deepMinutes = accumulator.deep
                coreMinutes = accumulator.core + accumulator.unspecifiedAsleep
                remMinutes = accumulator.rem
            } else {
                deepMinutes = nil
                coreMinutes = nil
                remMinutes = nil
            }
            
            let quality = Self.qualityScore(
                totalMinutes: totalMinutes,
                deepMinutes: hasStagedSamples ? accumulator.deep : nil
            )
            
            if totalMinutes > 0 {
                AppLog.debug(
                    "HealthDataService",
                    "Sleep \(day): total=\(totalMinutes)m deep=\(deepMinutes.map(String.init) ?? "n/a") " +
                    "core=\(coreMinutes.map(String.init) ?? "n/a") rem=\(remMinutes.map(String.init) ?? "n/a") " +
                    "quality=\(String(format: "%.2f", quality ?? 0))"
                )
            }
            
            results.append(
                SleepDataV2(
                    date: day,
                    totalDurationMinutes: totalMinutes,
                    deepSleepMinutes: deepMinutes,
                    coreSleepMinutes: coreMinutes,
                    remSleepMinutes: remMinutes,
                    qualityScore: quality
                )
            )
        }
        
        return results
    }
    
    /// Predicts the next menstrual period start from historical flow data (up to 1 year),
    /// optionally refined by ovulation-test results. Returns nil when the user has never logged flow.
    func getMenstrualCyclePrediction() async throws -> MenstrualCycleData? {
        try await requestHealthKitAuthorization()
        
        guard let menstrualFlowType = HKCategoryType.categoryType(forIdentifier: .menstrualFlow) else {
            AppLog.debug("HealthDataService", "menstrualFlow type unavailable")
            return nil
        }
        
        let calendar = Calendar.current
        let now = Date()
        let historyStart = calendar.date(byAdding: .month, value: -Self.menstrualHistoryMonths, to: now)!
        let variabilityStart = calendar.date(byAdding: .month, value: -Self.menstrualVariabilityMonths, to: now)!
        
        AppLog.debug(
            "HealthDataService",
            "Reading menstrual flow from \(historyStart) (variability window from \(variabilityStart))"
        )
        
        let predicate = HKQuery.predicateForSamples(withStart: historyStart, end: now)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        
        let samples = try await fetchCategorySamples(
            type: menstrualFlowType,
            predicate: predicate,
            sortDescriptors: [sortDescriptor]
        )
        
        guard !samples.isEmpty else {
            AppLog.debug("HealthDataService", "No menstrual flow samples found; user has not logged periods")
            return nil
        }
        
        let periodStarts = Self.clusterPeriodStarts(from: samples, calendar: calendar)
        guard let lastPeriodStart = periodStarts.last else {
            AppLog.debug("HealthDataService", "Could not derive any period start dates from flow samples")
            return nil
        }
        
        let allCycleLengths = Self.cycleLengths(
            from: periodStarts,
            calendar: calendar,
            within: historyStart...now
        )
        let recentCycleLengths = Self.cycleLengths(
            from: periodStarts,
            calendar: calendar,
            within: variabilityStart...now
        )
        
        AppLog.debug(
            "HealthDataService",
            "Menstrual history: \(periodStarts.count) period start(s), " +
            "\(allCycleLengths.count) total cycle length(s), " +
            "\(recentCycleLengths.count) in variability window"
        )
        
        // Need at least one completed cycle to predict the next start.
        guard !allCycleLengths.isEmpty else {
            AppLog.debug("HealthDataService", "Insufficient cycle history for prediction (only one period logged)")
            return nil
        }
        
        let averageCycleLength = Int(
            round(Double(allCycleLengths.reduce(0, +)) / Double(allCycleLengths.count))
        )
        
        let stdDev = Self.standardDeviation(recentCycleLengths.isEmpty ? allCycleLengths : recentCycleLengths)
        let isReliable = recentCycleLengths.count >= 2 && stdDev <= Self.maxCycleLengthStdDevDays
        
        AppLog.debug(
            "HealthDataService",
            "Cycle stats: avg=\(averageCycleLength)d stdDev=\(String(format: "%.1f", stdDev))d reliable=\(isReliable)"
        )
        
        // Base prediction: last period start + average cycle length
        var nextExpectedStartDate = calendar.date(
            byAdding: .day,
            value: averageCycleLength,
            to: lastPeriodStart
        ) ?? now
        
        // Optional refinement: positive ovulation test in the current cycle (~14-day luteal phase)
        if let ovulationRefinedDate = try await ovulationRefinedNextPeriodDate(
            afterPeriodStart: lastPeriodStart,
            before: now,
            calendar: calendar
        ) {
            AppLog.debug(
                "HealthDataService",
                "Refining prediction using ovulation test data: \(ovulationRefinedDate)"
            )
            nextExpectedStartDate = ovulationRefinedDate
        }
        
        let daysUntilStart = max(
            0,
            calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: nextExpectedStartDate)).day ?? 0
        )
        
        let prediction = MenstrualCycleData(
            nextExpectedStartDate: nextExpectedStartDate,
            daysUntilStart: daysUntilStart,
            cycleLength: averageCycleLength,
            isPredictionReliable: isReliable
        )
        
        AppLog.debug(
            "HealthDataService",
            "Menstrual prediction: next=\(nextExpectedStartDate), daysUntil=\(daysUntilStart), reliable=\(isReliable)"
        )
        
        return prediction
    }
    
    func getHeartRateVariability() async throws -> [HRVData] {
        try await requestHealthKitAuthorization()
        
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            AppLog.debug("HealthDataService", "heartRateVariabilitySDNN type unavailable; returning empty array")
            return []
        }
        
        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -7, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        AppLog.debug("HealthDataService", "Reading heart rate variability from HealthKit from \(startDate) to \(now)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: hrvType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, samples, error in
                if let error = error {
                    AppLog.error("HealthDataService", "Failed to read heart rate variability: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let quantitySamples = samples as? [HKQuantitySample] else {
                    AppLog.debug("HealthDataService", "No heart rate variability samples returned")
                    continuation.resume(returning: [])
                    return
                }
                
                let hrvData: [HRVData] = quantitySamples.map { sample in
                    let value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                    return HRVData(timestamp: sample.startDate, value: value)
                }
                
                AppLog.debug("HealthDataService", "Fetched \(hrvData.count) heart rate variability sample(s)")
                for data in hrvData.prefix(10) {
                    AppLog.debug("HealthDataService", "HRV sample: timestamp=\(data.timestamp), value=\(String(format: "%.2f", data.value))ms")
                }
                if hrvData.count > 10 {
                    AppLog.debug("HealthDataService", "... and \(hrvData.count - 10) more HRV samples")
                }
                
                continuation.resume(returning: hrvData)
            }
            healthStore.execute(query)
        }
    }
    
    // MARK: - Authorization
    
    private func requestHealthKitAuthorization() async throws {
        var typesToRead: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKCategoryType.categoryType(forIdentifier: .menstrualFlow)!
        ]
        
        // Optional types used to refine menstrual predictions when the user has logged them.
        if let ovulationType = HKCategoryType.categoryType(forIdentifier: .ovulationTestResult) {
            typesToRead.insert(ovulationType)
        }
        if let bbtType = HKQuantityType.quantityType(forIdentifier: .basalBodyTemperature) {
            typesToRead.insert(bbtType)
        }
        
        AppLog.debug(
            "HealthDataService",
            "Requesting HealthKit authorization for read types: stepCount, HRV, sleepAnalysis, " +
            "menstrualFlow, ovulationTestResult, basalBodyTemperature"
        )
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
        AppLog.debug("HealthDataService", "HealthKit authorization completed")
    }
    
    // MARK: - Menstrual helpers
    
    /// Clusters daily flow samples into distinct period start dates.
    private static func clusterPeriodStarts(from samples: [HKCategorySample], calendar: Calendar) -> [Date] {
        let uniqueFlowDays = Array(
            Set(samples.map { calendar.startOfDay(for: $0.startDate) })
        ).sorted()
        
        var periodStarts: [Date] = []
        for day in uniqueFlowDays {
            if let lastStart = periodStarts.last {
                let daysSinceLastStart = calendar.dateComponents([.day], from: lastStart, to: day).day ?? 0
                if daysSinceLastStart >= Self.minDaysBetweenPeriodStarts {
                    periodStarts.append(day)
                }
            } else {
                periodStarts.append(day)
            }
        }
        return periodStarts
    }
    
    private static func cycleLengths(
        from periodStarts: [Date],
        calendar: Calendar,
        within range: ClosedRange<Date>
    ) -> [Int] {
        guard periodStarts.count >= 2 else { return [] }
        
        var lengths: [Int] = []
        for index in 1..<periodStarts.count {
            let start = periodStarts[index - 1]
            let end = periodStarts[index]
            guard range.contains(end) else { continue }
            
            let length = calendar.dateComponents([.day], from: start, to: end).day ?? 0
            if Self.validCycleLengthRange.contains(length) {
                lengths.append(length)
            }
        }
        return lengths
    }
    
    private static func standardDeviation(_ values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = Double(values.reduce(0, +)) / Double(values.count)
        let variance = values
            .map { pow(Double($0) - mean, 2) }
            .reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }
    
    /// Uses the most recent positive ovulation test after `afterPeriodStart` to estimate the next period.
    private func ovulationRefinedNextPeriodDate(
        afterPeriodStart: Date,
        before end: Date,
        calendar: Calendar
    ) async throws -> Date? {
        guard let ovulationType = HKCategoryType.categoryType(forIdentifier: .ovulationTestResult) else {
            return nil
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: afterPeriodStart, end: end)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples = try await fetchCategorySamples(
            type: ovulationType,
            predicate: predicate,
            sortDescriptors: [sortDescriptor]
        )
        
        let positiveSample = samples.first { sample in
            Self.isPositiveOvulationResult(sample.value)
        }
        
        if let ovulationSample = positiveSample {
            let lutealDays = try await estimatedLutealPhaseDays(
                afterOvulation: ovulationSample.startDate,
                periodStart: afterPeriodStart,
                calendar: calendar
            )
            return calendar.date(byAdding: .day, value: lutealDays, to: ovulationSample.startDate)
        }
        
        // Fallback: look for a basal-body-temperature rise as a weak ovulation signal.
        return try await bbtRefinedNextPeriodDate(
            afterPeriodStart: afterPeriodStart,
            before: end,
            calendar: calendar
        )
    }
    
    private static func isPositiveOvulationResult(_ rawValue: Int) -> Bool {
        if #available(iOS 15.0, *) {
            return rawValue == HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue
        }
        return rawValue == HKCategoryValueOvulationTestResult.luteinizingHormoneSurge.rawValue
    }
    
    /// Estimates luteal phase length from historical BBT rise → next period pairs, else defaults to 14 days.
    private func estimatedLutealPhaseDays(
        afterOvulation ovulationDate: Date,
        periodStart: Date,
        calendar: Calendar
    ) async throws -> Int {
        guard let bbtType = HKQuantityType.quantityType(forIdentifier: .basalBodyTemperature) else {
            return Self.defaultLutealPhaseDays
        }
        
        let lookbackStart = calendar.date(byAdding: .month, value: -Self.menstrualHistoryMonths, to: ovulationDate)!
        let predicate = HKQuery.predicateForSamples(withStart: lookbackStart, end: ovulationDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples = try await fetchQuantitySamples(
            type: bbtType,
            predicate: predicate,
            sortDescriptors: [sortDescriptor]
        )
        
        guard samples.count >= 7 else {
            return Self.defaultLutealPhaseDays
        }
        
        // Simple rise detection: first day after period where temp exceeds prior 6-day average by 0.2 °C.
        let readings = samples.map {
            (date: $0.startDate, celsius: $0.quantity.doubleValue(for: HKUnit.degreeCelsius()))
        }
        
        for index in 6..<readings.count {
            let prior = readings[(index - 6)..<index]
            let priorAvg = prior.map(\.celsius).reduce(0, +) / Double(prior.count)
            if readings[index].celsius >= priorAvg + 0.2, readings[index].date >= periodStart {
                let days = calendar.dateComponents([.day], from: readings[index].date, to: ovulationDate).day ?? Self.defaultLutealPhaseDays
                if (10...18).contains(days) {
                    AppLog.debug("HealthDataService", "BBT-derived luteal phase: \(days) day(s)")
                    return days
                }
                break
            }
        }
        
        return Self.defaultLutealPhaseDays
    }
    
    /// Detects a post-ovulation BBT rise in the current cycle and projects the next period from it.
    private func bbtRefinedNextPeriodDate(
        afterPeriodStart: Date,
        before end: Date,
        calendar: Calendar
    ) async throws -> Date? {
        guard let bbtType = HKQuantityType.quantityType(forIdentifier: .basalBodyTemperature) else {
            return nil
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: afterPeriodStart, end: end)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples = try await fetchQuantitySamples(
            type: bbtType,
            predicate: predicate,
            sortDescriptors: [sortDescriptor]
        )
        
        guard samples.count >= 7 else { return nil }
        
        let readings = samples.map {
            (date: $0.startDate, celsius: $0.quantity.doubleValue(for: HKUnit.degreeCelsius()))
        }
        
        for index in 6..<readings.count {
            let prior = readings[(index - 6)..<index]
            let priorAvg = prior.map(\.celsius).reduce(0, +) / Double(prior.count)
            if readings[index].celsius >= priorAvg + 0.2 {
                let ovulationEstimate = readings[index].date
                AppLog.debug("HealthDataService", "BBT rise detected at \(ovulationEstimate); using for prediction")
                return calendar.date(byAdding: .day, value: Self.defaultLutealPhaseDays, to: ovulationEstimate)
            }
        }
        
        return nil
    }
    
    // MARK: - Sleep helpers
    
    private struct SleepStageAccumulator {
        var deep = 0
        var core = 0
        var rem = 0
        var unspecifiedAsleep = 0
        var asleepTotal = 0
    }
    
    /// Deep-sleep percentage (15–25% is ideal) when stages exist; otherwise duration-based heuristic.
    private static func qualityScore(totalMinutes: Int, deepMinutes: Int?) -> Double? {
        guard totalMinutes > 0 else { return nil }
        
        if let deep = deepMinutes {
            let deepPercent = Double(deep) / Double(totalMinutes) * 100.0
            let idealPercent = 20.0
            let deviation = abs(deepPercent - idealPercent)
            // Full score inside 15–25%, linear falloff beyond that band.
            return max(0.0, min(1.0, 1.0 - deviation / 25.0))
        }
        
        // Legacy fallback: peak quality around 8 hours (480 minutes).
        return max(0.0, min(1.0, 1.0 - abs(Double(totalMinutes - 480) / 240.0)))
    }
    
    // MARK: - Generic HealthKit fetch helpers
    
    private func fetchCategorySamples(
        type: HKCategoryType,
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor]
    ) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error = error {
                    AppLog.error("HealthDataService", "Category query failed for \(type.identifier): \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                let categorySamples = (samples as? [HKCategorySample]) ?? []
                AppLog.debug("HealthDataService", "Fetched \(categorySamples.count) category sample(s) for \(type.identifier)")
                continuation.resume(returning: categorySamples)
            }
            healthStore.execute(query)
        }
    }
    
    private func fetchQuantitySamples(
        type: HKQuantityType,
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor]
    ) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sortDescriptors
            ) { _, samples, error in
                if let error = error {
                    AppLog.error("HealthDataService", "Quantity query failed for \(type.identifier): \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                AppLog.debug("HealthDataService", "Fetched \(quantitySamples.count) quantity sample(s) for \(type.identifier)")
                continuation.resume(returning: quantitySamples)
            }
            healthStore.execute(query)
        }
    }
}
