import Foundation
import CoreLocation

/// 天气氛围信息，用于按概率注入到 system prompt 中。
///
/// 设计上完全参照 DateAmbienceProvider 的思路：把"今天天气如何"从一个需要
/// LLM 每次都提及的硬性事实，降级为 *ambient context* —— 提供给 LLM，
/// 由它自己判断对话里提不提、怎么提，而不是通过独立的 event 或强制指令
/// 逼它每句话都聊天气。
struct WeatherAmbience: Sendable, Equatable {
    /// 例如 "多云，18°C 到 26°C"
    let summary: String
}

struct WeatherAmbienceProvider: Sendable {
    private let weatherFetcher: DailyWeatherFetcher
    private let logger: LoggingProviding
    private let nowProvider: @Sendable () -> Date
    private let rng: @Sendable () -> Double

    /// 天气比"今天是不是周末"更百搭、更常在日常聊天里自然出现（穿衣、出门、心情），
    /// 所以注入概率给得比周末氛围（35%）更高；但仍然设置冷却时间，避免同一天内
    /// 反复被塞进 prompt，导致 LLM 看起来像是在"播报天气预报"。
    struct InjectionRates: Sendable {
        let injectionProbability: Double
        let mentionCooldownHours: Int

        init(injectionProbability: Double = 0.55, mentionCooldownHours: Int = 8) {
            self.injectionProbability = injectionProbability
            self.mentionCooldownHours = mentionCooldownHours
        }
    }

    private let rates: InjectionRates

    private static let cacheSummaryKey = "com.echo.weatherambience.summary"
    private static let cacheDateKey = "com.echo.weatherambience.date"
    private static let cacheLocationKey = "com.echo.weatherambience.location"
    private static let lastMentionKey = "com.echo.weatherambience.lastmention"
    /// 失败冷却：Open-Meteo 源站 TLS 失败时，避免每条消息都重试刷屏。
    private static let lastFailureAtKey = "com.echo.weatherambience.lastfailureat"
    private static let lastFailureReasonKey = "com.echo.weatherambience.lastfailurereason"
    private static let failureCooldownSeconds: TimeInterval = 30 * 60

    // Weather is "close enough" to not bother refetching if the last fix was
    // within roughly this distance — avoids refetching on every small SLC
    // nudge within the same city.
    private static let refetchDistanceThresholdMeters: CLLocationDistance = 15_000

    init(
        weatherFetcher: DailyWeatherFetcher = DailyWeatherFetcher(),
        logger: LoggingProviding,
        rates: InjectionRates = InjectionRates(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        rng: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.weatherFetcher = weatherFetcher
        self.logger = logger
        self.rates = rates
        self.nowProvider = nowProvider
        self.rng = rng
    }

    /// 按概率决定是否将天气氛围注入到 system prompt。
    /// 返回 nil 表示本次不注入（没有定位、请求失败、或没抽中概率）。
    func ambientPromptSnippet(location: CLLocationCoordinate2D?) async -> String? {
        guard let location else { return nil }
        guard let weather = await fetchOrLoadCachedWeather(location: location) else { return nil }
        guard rng() < rates.injectionProbability else { return nil }

        let now = nowProvider()
        guard !isWithinCooldown(now: now) else { return nil }
        markMentioned(now: now)

        let low = Int(weather.minTemp.rounded())
        let high = Int(weather.maxTemp.rounded())
        return """
        【天气信息】
        今天\(weather.weatherDescription)，气温大约\(low)°C到\(high)°C。
        如果对话自然涉及天气、穿衣、出门计划等话题，可以顺势提一句（比如提醒注意保暖/带伞），不要每条消息都主动提天气，更不要生硬地报数据。
        """
    }

    // MARK: - Caching

    private func fetchOrLoadCachedWeather(location: CLLocationCoordinate2D) async -> DailyWeather? {
        let defaults = UserDefaults.standard
        let now = nowProvider()

        if let cached = loadFreshCache(for: location, defaults: defaults) {
            return cached
        }

        // 成功缓存未命中时，若仍在失败冷却窗口内，优先返回“过期但仍可用”的缓存，
        // 否则直接跳过网络，避免 SSL 失败日志被每条消息刷爆。
        if let lastFailure = defaults.object(forKey: Self.lastFailureAtKey) as? Date,
           now.timeIntervalSince(lastFailure) < Self.failureCooldownSeconds {
            if let stale = loadAnyCachedWeather(defaults: defaults) {
                await logger.log(
                    "Weather fetch skipped (failure cooldown); using stale cache",
                    level: .debug
                )
                return stale
            }
            return nil
        }

        do {
            let weather = try await weatherFetcher.fetchDailyWeather(
                latitude: location.latitude,
                longitude: location.longitude
            )
            cache(weather, location: location)
            clearFailureCooldown()
            await logger.log(
                "天气数据获取成功: \(weather.weatherDescription) \(Int(weather.minTemp.rounded()))~\(Int(weather.maxTemp.rounded()))°C",
                level: .debug
            )
            return weather
        } catch {
            markFailure(error, at: now)

            // 网络/TLS 失败时尽量回退到任意已有缓存，保证氛围能力降级而不是全灭。
            if let stale = loadAnyCachedWeather(defaults: defaults) {
                let detail = (error as? WeatherError)?.debugDescription ?? error.localizedDescription
                await logger.log(
                    "天气数据获取失败，使用旧缓存: \(detail)",
                    level: .warning
                )
                return stale
            }

            let detail = (error as? WeatherError)?.debugDescription ?? error.localizedDescription
            await logger.log("天气数据获取失败: \(detail)", level: .warning)
            return nil
        }
    }

    private func loadFreshCache(for location: CLLocationCoordinate2D, defaults: UserDefaults) -> DailyWeather? {
        guard let cachedDateString = defaults.string(forKey: Self.cacheDateKey),
              let cachedSummary = defaults.string(forKey: Self.cacheSummaryKey),
              Calendar.current.isDateInToday(dateFromCacheString(cachedDateString) ?? .distantPast),
              let cachedLocationString = defaults.string(forKey: Self.cacheLocationKey),
              let cachedLocation = decodeLocation(cachedLocationString),
              distanceMeters(cachedLocation, location) < Self.refetchDistanceThresholdMeters else {
            return nil
        }
        return decodeCachedWeather(summary: cachedSummary, date: cachedDateString)
    }

    private func loadAnyCachedWeather(defaults: UserDefaults) -> DailyWeather? {
        guard let cachedSummary = defaults.string(forKey: Self.cacheSummaryKey) else { return nil }
        let date = defaults.string(forKey: Self.cacheDateKey) ?? ""
        return decodeCachedWeather(summary: cachedSummary, date: date)
    }

    private func cache(_ weather: DailyWeather, location: CLLocationCoordinate2D) {
        let defaults = UserDefaults.standard
        defaults.set(weather.date, forKey: Self.cacheDateKey)
        defaults.set(encodeCachedWeather(weather), forKey: Self.cacheSummaryKey)
        defaults.set(encodeLocation(location), forKey: Self.cacheLocationKey)
    }

    private func markFailure(_ error: Error, at date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(date, forKey: Self.lastFailureAtKey)
        let reason = (error as? WeatherError)?.debugDescription ?? error.localizedDescription
        defaults.set(reason, forKey: Self.lastFailureReasonKey)
    }

    private func clearFailureCooldown() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.lastFailureAtKey)
        defaults.removeObject(forKey: Self.lastFailureReasonKey)
    }

    // Small hand-rolled encode/decode instead of Codable+UserDefaults ceremony
    // for a single cached value — "maxTemp|minTemp|code|description"
    private func encodeCachedWeather(_ weather: DailyWeather) -> String {
        "\(weather.maxTemp)|\(weather.minTemp)|\(weather.weatherCode)|\(weather.weatherDescription)"
    }

    private func decodeCachedWeather(summary: String, date: String) -> DailyWeather? {
        let parts = summary.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let maxTemp = Double(parts[0]),
              let minTemp = Double(parts[1]),
              let code = Int(parts[2]) else { return nil }
        return DailyWeather(
            date: date,
            maxTemp: maxTemp,
            minTemp: minTemp,
            weatherCode: code,
            weatherDescription: String(parts[3])
        )
    }

    private func encodeLocation(_ location: CLLocationCoordinate2D) -> String {
        "\(location.latitude),\(location.longitude)"
    }

    private func decodeLocation(_ string: String) -> CLLocationCoordinate2D? {
        let parts = string.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func dateFromCacheString(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    // MARK: - Mention cooldown

    private func isWithinCooldown(now: Date) -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastMentionKey) as? Date else { return false }
        return now.timeIntervalSince(last) < Double(rates.mentionCooldownHours) * 3600
    }

    private func markMentioned(now: Date) {
        UserDefaults.standard.set(now, forKey: Self.lastMentionKey)
    }
}
