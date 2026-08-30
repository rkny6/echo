import Foundation

/// Types of life events that trigger companion messages
enum CompanionEventType: String, Codable, CaseIterable {
    /// User went out
    case outing
    /// User had poor sleep
    case sleep
    /// User walked very little
    case lowSteps
    /// User walked a lot
    case highSteps
    /// User's heart rate variability is notably below their own recent baseline
    case lowHRV
    /// User's step count has been consistently healthy for several days
    case goodSteps
    /// User's HRV has been holding at/above their own recent baseline
    case goodHRV
    /// User is approaching menstrual cycle
    case menstrualCycle

    case birthday          // 用户生日
    case holiday           // 法定节假日
    case weekend           // 周末（普通周末）
    /// Character came online after a long silence and greets first.
    case onlineGreeting
    /// Evening light check-in after a long silence (not schedule-driven).
    case eveningCheckIn

    /// Default priority for event queue ordering (higher = more important)
    var defaultPriority: Int {
        switch self {
            case .menstrualCycle: return 10
            case .sleep: return 8
            case .outing: return 5
            case .lowSteps, .highSteps: return 3
            case .lowHRV: return 6
            case .goodSteps, .goodHRV: return 2

            case .birthday: return 11
            case .holiday, .weekend: return 7
            case .onlineGreeting: return 9
            // Below online greeting so schedule-driven online greets win if both race.
            case .eveningCheckIn: return 8
        }
    }
}
