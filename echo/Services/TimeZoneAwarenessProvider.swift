import Foundation

/// Provides time zone awareness functionality including local time string generation
/// and time zone change detection
class TimeZoneAwarenessProvider: @unchecked Sendable {
    private let logger: LoggingProviding
    
    // UserDefaults keys
    private let lastKnownTimeZoneKey = "LastKnownTimeZone"
    private var defaults: UserDefaults { UserDefaults.standard }
    
    // Notification observation
    private var timeZoneObserver: NSObjectProtocol?
    
    init(logger: LoggingProviding) {
        self.logger = logger
        startObservingTimeZoneChanges()
    }
    
    deinit {
        stopObservingTimeZoneChanges()
    }
    
    // MARK: - Public API
    
    /// Generate formatted local time string in Chinese
    func getLocalTimeString(for date: Date = Date()) -> String {
        let timeZone = TimeZone.current
        let calendar = Calendar.current
        
        // Date components
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let weekday = calendar.component(.weekday, from: date)
        
        // Weekday in Chinese
        let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayString = weekdayNames[weekday - 1]
        
        // Time zone offset
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let offsetHours = offsetSeconds / 3600
        let offsetMinutes = abs((offsetSeconds % 3600) / 60)
        let offsetString: String
        if offsetMinutes == 0 {
            offsetString = String(format: "UTC%+d", offsetHours)
        } else {
            offsetString = String(format: "UTC%+d:%02d", offsetHours, offsetMinutes)
        }
        
        // Time zone city
        let cityString = getTimeZoneCityName(timeZone: timeZone)
        
        // Format final string
        return String(
            format: "%04d年%02d月%02d日 %02d:%02d (%@) %@ %@",
            year, month, day, hour, minute,
            weekdayString, offsetString, cityString
        )
    }
    
    /// Get last known time zone identifier
    var lastKnownTimeZone: String? {
        defaults.string(forKey: lastKnownTimeZoneKey)
    }
    
    /// Check if time zone has changed since last check
    func hasTimeZoneChanged() -> Bool {
        guard let last = lastKnownTimeZone else {
            updateLastKnownTimeZone()
            return false
        }
        return last != TimeZone.current.identifier
    }
    
    /// Update last known time zone to current
    func updateLastKnownTimeZone() {
        defaults.set(TimeZone.current.identifier, forKey: lastKnownTimeZoneKey)
    }
    
    // MARK: - Time Zone Change Observation
    
    private func startObservingTimeZoneChanges() {
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleTimeZoneChange()
            }
        }
    }
    
    private func stopObservingTimeZoneChanges() {
        if let observer = timeZoneObserver {
            NotificationCenter.default.removeObserver(observer)
            timeZoneObserver = nil
        }
    }
    
    private func handleTimeZoneChange() {
        Task { [weak self] in
            guard let self = self else { return }
            await self.logger.log("Time zone changed from \(self.lastKnownTimeZone ?? "unknown") to \(TimeZone.current.identifier)", level: .info)
            
            // Invalidate daily context cache
            self.invalidateDailyContextCache()
            
            // Update last known time zone
            self.updateLastKnownTimeZone()
        }
    }
    
    private func invalidateDailyContextCache() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "DailyContext")
        defaults.removeObject(forKey: "DailyContextDate")
        Task { [weak self] in
            await self?.logger.log("Daily context cache invalidated due to time zone change", level: .info)
        }
    }
    
    // MARK: - Private Helpers
    
    private func getTimeZoneCityName(timeZone: TimeZone) -> String {
        let identifier = timeZone.identifier
        
        // Common city mappings
        let cityMappings: [String: String] = [
            "Asia/Shanghai": "北京",
            "Asia/Hong_Kong": "香港",
            "Asia/Tokyo": "东京",
            "Asia/Seoul": "首尔",
            "Asia/Singapore": "新加坡",
            "America/New_York": "纽约",
            "America/Los_Angeles": "洛杉矶",
            "America/Chicago": "芝加哥",
            "Europe/London": "伦敦",
            "Europe/Paris": "巴黎",
            "Europe/Berlin": "柏林",
            "Australia/Sydney": "悉尼",
            "Pacific/Auckland": "奥克兰"
        ]
        
        if let city = cityMappings[identifier] {
            return city
        }
        
        // Fallback: extract city from identifier
        let components = identifier.split(separator: "/")
        if components.count >= 2 {
            let cityPart = components.last!
            return cityPart.replacingOccurrences(of: "_", with: " ")
        }
        
        return identifier
    }
}
