import Foundation

// MARK: - 融合后的 DateContextManager

/// Thread-safe manager for holiday/workday context, now with birthday support via composition.
public final class DateContextManager: @unchecked Sendable {
    public static let shared = DateContextManager()
    public static let cacheKey = "com.yourapp.holiday.cache"  // 保留但不再使用
    
    private static let cacheExpirationInterval: TimeInterval = 86400
    private static let failureCooldownInterval: TimeInterval = 300
    
    private let userDefaults: UserDefaults
    private let session: URLSession
    private let nowProvider: @Sendable () -> Date
    private let birthdayService: BirthdayDetectionService   // 新增组合
    
    private let lock = NSLock()
    private var cache: HolidayCacheEnvelope
    private var isRefreshing = false
    private var failedYears: [Int: Date] = [:]
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    public init(
        userDefaults: UserDefaults = .standard,
        session: URLSession? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        autoRefresh: Bool = true,
        birthdayService: BirthdayDetectionService = .shared   // 新增注入参数
    ) {
        self.userDefaults = userDefaults
        self.session = session ?? Self.makeDefaultSession()
        self.nowProvider = nowProvider
        self.birthdayService = birthdayService
        self.cache = Self.loadCache()
        
        if autoRefresh {
            Task(priority: .utility) { [weak self] in
                await self?.refreshHolidayDataIfNeeded()
            }
        }
    }
    
    // MARK: - 原公开方法（保持不变）
    
    public func refreshHolidayDataIfNeeded() async {
        let now = nowProvider()
        let requiredYears = yearsToKeep(for: now)
        
        let refreshYears = lock.withLock { () -> [Int] in
            cache = cache.pruned(keeping: requiredYears)
            persistCacheLocked()
            guard !isRefreshing else { return [] }
            let years = yearsNeedingRefresh(for: now, in: requiredYears)
            if !years.isEmpty {
                isRefreshing = true
            }
            return years
        }
        
        guard !refreshYears.isEmpty else { return }
        
        defer {
            lock.withLock { isRefreshing = false }
        }
        
        var fetchedPayloads: [Int: HolidayYearCache] = [:]
        
        for year in refreshYears {
            do {
                let days = try await fetchHolidayMap(for: year)
                let payload = HolidayYearCache(fetchedAt: now, days: days)
                fetchedPayloads[year] = payload
                lock.withLock { failedYears.removeValue(forKey: year) }
            } catch {
                lock.withLock { failedYears[year] = now }
                continue
            }
        }
        
        guard !fetchedPayloads.isEmpty else { return }
        
        lock.withLock {
            for (year, payload) in fetchedPayloads {
                cache.years[year] = payload
            }
            cache = cache.pruned(keeping: requiredYears)
            persistCacheLocked()
        }
    }
    
    /// 返回当前日期的工作日/节假日中文标签（原方法保持不变）
    public func getCurrentDateContextString() -> String {
        triggerBackgroundRefreshIfNeeded()
        
        let currentDate = nowProvider()
        let dateKey = self.dateKey(for: currentDate)
        let cachedStatus = lock.withLock {
            cache.status(for: dateKey)
        }
        
        switch cachedStatus {
        case 0:
            return "调休工作日"
        case 1:
            return "法定节假日"
        default:
            return Calendar.current.isDateInWeekend(currentDate) ? "周末" : "普通工作日"
        }
    }
    
    // MARK: - 🎂 新增融合方法
    
    /// 返回完整的日期上下文描述（包含工作日/节假日 + 生日信息）
    /// - Parameter birthday: 用户的生日日期（可选），传入后会在结果中附加生日祝福或倒计时
    /// - Returns: 一段中文描述，例如 “今天（2026-07-07）是普通工作日，还有3天就是你的生日！🎂”
    public func getFullDateContextString(birthday: Date?) -> String {
        let dateLabel = getCurrentDateContextString()
        let now = nowProvider()
        let dateKey = self.dateKey(for: now)
        
        // 基础字符串
        var result = "今天（\(dateKey)）是\(dateLabel)"
        
        // 附加生日信息
        if let birthday = birthday,
           let birthdayInfo = birthdayService.checkBirthdayInfo(birthday: birthday, date: now) {
            result += "，\(birthdayInfo)"
        }
        
        return result
    }
    
    // MARK: - Private helpers（原封不动）
    
    private func triggerBackgroundRefreshIfNeeded() {
        let shouldRefresh = lock.withLock { () -> Bool in
            guard !isRefreshing else { return false }
            let now = nowProvider()
            let requiredYears = yearsToKeep(for: now)
            let years = yearsNeedingRefresh(for: now, in: requiredYears)
            return !years.isEmpty
        }
        guard shouldRefresh else { return }
        
        Task(priority: .utility) { [weak self] in
            await self?.refreshHolidayDataIfNeeded()
        }
    }
    
    private func yearsNeedingRefresh(for now: Date, in requiredYears: [Int]) -> [Int] {
        var refreshYears: [Int] = []
        for year in requiredYears {
            if let yearCache = cache.years[year] {
                if yearCache.fetchedAt.addingTimeInterval(Self.cacheExpirationInterval) <= now {
                    if let lastFail = failedYears[year],
                       lastFail.addingTimeInterval(Self.failureCooldownInterval) > now {
                        continue
                    }
                    refreshYears.append(year)
                }
            } else {
                if let lastFail = failedYears[year],
                   lastFail.addingTimeInterval(Self.failureCooldownInterval) > now {
                    continue
                }
                refreshYears.append(year)
            }
        }
        return refreshYears
    }
    
    private func fetchHolidayMap(for year: Int) async throws -> [String: Int] {
        guard let url = URL(string: "https://timor.tech/api/holiday/year/\(year)") else {
            throw DateContextError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw DateContextError.invalidResponse
        }
        
        let payload = try JSONDecoder().decode(TimorHolidayResponse.self, from: data)
        guard payload.code == 0 else {
            throw DateContextError.apiReturnedError
        }
        
        let mappedDays = payload.holiday.reduce(into: [String: Int]()) { partialResult, item in
            if item.value.work == true {
                partialResult[item.key] = 0
            } else if item.value.holiday == true {
                partialResult[item.key] = 1
            }
        }
        
        guard !mappedDays.isEmpty else {
            throw DateContextError.emptyHolidayData
        }
        
        return mappedDays
    }
    
    private func yearsToKeep(for date: Date) -> [Int] {
        let year = gregorianCalendar().component(.year, from: date)
        return [year, year + 1]
    }
    
    private func dateKey(for date: Date) -> String {
        lock.withLock {
            Self.dateFormatter.string(from: date)
        }
    }
    
    private func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
    
    // MARK: - Persistence (File-based)
    
    private static func cacheFileURL() -> URL {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("holiday_cache.json")
    }
    
    private func persistCacheLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let url = Self.cacheFileURL()
        try? data.write(to: url)
    }
    
    private static func loadCache() -> HolidayCacheEnvelope {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(HolidayCacheEnvelope.self, from: data) else {
            return HolidayCacheEnvelope()
        }
        return decoded
    }
    
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

// MARK: - Private Models（不变）

private extension DateContextManager {
    struct HolidayCacheEnvelope: Codable, Equatable {
        var years: [Int: HolidayYearCache] = [:]
        
        func pruned(keeping yearsToKeep: [Int]) -> HolidayCacheEnvelope {
            let keepSet = Set(yearsToKeep)
            return HolidayCacheEnvelope(
                years: years.filter { keepSet.contains($0.key) }
            )
        }
        
        func status(for dateKey: String) -> Int? {
            for yearCache in years.values {
                if let status = yearCache.days[dateKey] {
                    return status
                }
            }
            return nil
        }
    }
    
    struct HolidayYearCache: Codable, Equatable {
        let fetchedAt: Date
        let days: [String: Int]
    }
    
    struct TimorHolidayResponse: Decodable {
        let code: Int
        let holiday: [String: TimorHolidayEntry]
    }
    
    struct TimorHolidayEntry: Decodable {
        let holiday: Bool?
        let work: Bool?
    }
    
    enum DateContextError: Error {
        case invalidURL
        case invalidResponse
        case apiReturnedError
        case emptyHolidayData
    }
}

// MARK: - Lock Extension（不变）

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}