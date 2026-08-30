import Foundation

extension CompanionEventType {
    /// 判断是否为健康事件类型
    var isHealthEventType: Bool {
        switch self {
        case .sleep, .lowSteps, .highSteps, .lowHRV, .goodSteps, .goodHRV, .outing, .menstrualCycle:
            return true
        case .birthday, .holiday, .weekend, .onlineGreeting, .eveningCheckIn:
            return false
        }
    }
}