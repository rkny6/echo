import Foundation

// MARK: - 原 BirthdayDetectionService（去除 @MainActor，使其与锁兼容）

/// 生日检测服务 - 仅提供日期（月/日）相关功能（线程安全）
public final class BirthdayDetectionService: Sendable {
    public static let shared = BirthdayDetectionService()
    
    private init() {}
    
    // 注意：所有方法都只使用 Calendar.current，它是线程安全的（在 Foundation 中，Calendar 是不可变对象）
    
    /// 检查指定日期是否是生日（仅比较月/日）
    public func isBirthday(birthday: Date, date: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let birthdayComponents = calendar.dateComponents([.month, .day], from: birthday)
        let checkComponents = calendar.dateComponents([.month, .day], from: date)
        return birthdayComponents.month == checkComponents.month &&
               birthdayComponents.day == checkComponents.day
    }
    
    /// 返回生日提示信息（如果是今天或即将到来），否则返回 nil
    public func checkBirthdayInfo(birthday: Date?, date: Date = Date()) -> String? {
        guard let birthday = birthday else { return nil }
        if isBirthday(birthday: birthday, date: date) {
            return "今天就是你的生日！🎂🎉"
        }
        let days = daysUntilBirthday(birthday: birthday, date: date)
        if days <= 7 && days > 0 {
            return "还有\(days)天就是你的生日了！🎂"
        }
        return nil
    }
    
    /// 计算距离下个生日还有多少天（今天返回0，生日已过则计算到明年）
    public func daysUntilBirthday(birthday: Date, date: Date = Date()) -> Int {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: date)
        let birthdayComponents = calendar.dateComponents([.month, .day], from: birthday)
        
        guard let thisYearBirthday = calendar.date(
            from: DateComponents(year: currentYear,
                                 month: birthdayComponents.month,
                                 day: birthdayComponents.day)
        ) else {
            return Int.max
        }
        
        let comparison = calendar.compare(thisYearBirthday, to: date, toGranularity: .day)
        if comparison == .orderedSame {
            return 0
        } else if comparison == .orderedAscending {
            guard let nextYearBirthday = calendar.date(
                from: DateComponents(year: currentYear + 1,
                                     month: birthdayComponents.month,
                                     day: birthdayComponents.day)
            ) else {
                return Int.max
            }
            let days = calendar.dateComponents([.day], from: date, to: nextYearBirthday).day ?? Int.max
            return max(0, days)
        } else {
            let days = calendar.dateComponents([.day], from: date, to: thisYearBirthday).day ?? Int.max
            return max(0, days)
        }
    }
}