import Foundation

/// Protocol for providing health data
protocol HealthDataProviding: Sendable {
    /// Get today's step count
    func getTodayStepCount() async throws -> Int

    /// Get per-day step totals for the past N days (today included)
    func getStepCounts(days: Int) async throws -> [DailyStepCount]
    
    /// Get sleep analysis for the past N days (stage-aware when HealthKit provides it)
    func getSleepAnalysis(days: Int) async throws -> [SleepDataV2]
    
    /// Get menstrual cycle prediction
    func getMenstrualCyclePrediction() async throws -> MenstrualCycleData?
    
    /// Get heart rate variability data
    func getHeartRateVariability() async throws -> [HRVData]
}

/// Per-day step total, used for the rolling activity-trend signal.
struct DailyStepCount: Codable, Sendable {
    let date: Date
    let steps: Int
}

/// Sleep data with optional per-stage breakdown (iOS 16+ staged samples when available)
struct SleepDataV2: Codable, Sendable {
    let date: Date
    /// Total actual sleep time (sum of asleep* stage values, excluding inBed/awake)
    let totalDurationMinutes: Int
    /// Deep sleep minutes; nil when staged data is unavailable (e.g. iOS 15 or non-staged sources)
    let deepSleepMinutes: Int?
    /// Core/light sleep minutes; nil when staged data is unavailable
    let coreSleepMinutes: Int?
    /// REM sleep minutes; nil when staged data is unavailable
    let remSleepMinutes: Int?
    /// Quality score 0–1; uses deep-sleep percentage when stages exist, otherwise duration-based estimate
    let qualityScore: Double?
}

/// HRV data structure
struct HRVData: Codable, Sendable {
    let timestamp: Date
    let value: Double
}

/// Menstrual cycle data
struct MenstrualCycleData: Codable, Sendable {
    let nextExpectedStartDate: Date
    let daysUntilStart: Int
    let cycleLength: Int
    /// False when cycle lengths are too variable or insufficient history exists for a confident forecast
    let isPredictionReliable: Bool
}
