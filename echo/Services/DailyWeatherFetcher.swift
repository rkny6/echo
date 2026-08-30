import Foundation

/// 天气错误类型
enum WeatherError: Error, LocalizedError {
    /// 无效的 URL
    case invalidURL
    /// 缺少 API Token
    case missingAPIToken
    /// 网络请求失败
    case networkError(Error)
    /// TLS / 安全连接失败
    case secureConnectionFailed(Error)
    /// 请求超时
    case timeout(Error)
    /// 无效的响应
    case invalidResponse(statusCode: Int?)
    /// 上游业务错误（如 token 失效、配额耗尽）
    case upstreamError(String)
    /// 数据解析失败
    case decodingError(Error)
    /// 数据不完整
    case incompleteData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 URL"
        case .missingAPIToken:
            return "缺少天气 API Token"
        case .networkError(let error):
            return "网络请求失败: \(error.localizedDescription)"
        case .secureConnectionFailed(let error):
            return "SSL/安全连接失败: \(error.localizedDescription)"
        case .timeout(let error):
            return "请求超时: \(error.localizedDescription)"
        case .invalidResponse(let statusCode):
            if let statusCode {
                return "无效的响应 (HTTP \(statusCode))"
            }
            return "无效的响应"
        case .upstreamError(let message):
            return "天气服务错误: \(message)"
        case .decodingError(let error):
            return "数据解析失败: \(error.localizedDescription)"
        case .incompleteData:
            return "数据不完整"
        }
    }

    /// 适合日志的技术细节（含 URLError code）
    var debugDescription: String {
        switch self {
        case .networkError(let error),
             .secureConnectionFailed(let error),
             .timeout(let error):
            if let urlError = error as? URLError {
                return "\(errorDescription ?? "") [URLError code=\(urlError.code.rawValue) \(urlError.code)]"
            }
            return errorDescription ?? String(describing: self)
        default:
            return errorDescription ?? String(describing: self)
        }
    }
}

/// 每日天气数据结构体
struct DailyWeather: Codable, Sendable {
    /// 日期，格式 "yyyy-MM-dd"
    let date: String
    /// 最高气温，单位 °C
    let maxTemp: Double
    /// 最低气温，单位 °C
    let minTemp: Double
    /// 内部稳定天气代码（兼容缓存；非 Open-Meteo WMO）
    let weatherCode: Int
    /// 天气描述（中文）
    let weatherDescription: String
}

// MARK: - 彩云天气响应

private struct CaiyunDailyResponse: Codable {
    let status: String
    let error: String?
    let result: CaiyunResult?
}

private struct CaiyunResult: Codable {
    let daily: CaiyunDaily?
}

private struct CaiyunDaily: Codable {
    let status: String?
    let temperature: [CaiyunTemperature]?
    let skycon: [CaiyunSkycon]?
}

private struct CaiyunTemperature: Codable {
    let date: String
    let max: Double
    let min: Double
}

private struct CaiyunSkycon: Codable {
    let date: String
    let value: String
}

// MARK: - Open-Meteo 兜底响应（海外网络）

private struct OpenMeteoResponse: Codable {
    let currentWeather: OpenMeteoCurrentWeather?
    let current: OpenMeteoCurrent?
    let daily: OpenMeteoDaily

    enum CodingKeys: String, CodingKey {
        case currentWeather = "current_weather"
        case current
        case daily
    }
}

private struct OpenMeteoCurrentWeather: Codable {
    let weathercode: Int
    let time: String
}

private struct OpenMeteoCurrent: Codable {
    let weatherCode: Int
    let time: String

    enum CodingKeys: String, CodingKey {
        case weatherCode = "weather_code"
        case time
    }
}

private struct OpenMeteoDaily: Codable {
    let time: [String]?
    let temperature2mMax: [Double]
    let temperature2mMin: [Double]

    enum CodingKeys: String, CodingKey {
        case time
        case temperature2mMax = "temperature_2m_max"
        case temperature2mMin = "temperature_2m_min"
    }
}

/// 天气获取器：优先使用国内可达的彩云天气 API，失败时再尝试 Open-Meteo。
///
/// 为什么换源：
/// - 原 `api.open-meteo.com` 托管在欧洲 Hetzner，国内部分网络 TLS 握手失败频繁
///   （`发生 SSL 错误，无法与服务器建立安全连接`）。
/// - 彩云天气（`api.caiyunapp.com`）国内节点，支持经纬度，适合当前 location-based 氛围注入。
final class DailyWeatherFetcher: @unchecked Sendable {
    /// Info.plist 可选覆盖：`CaiyunWeatherToken`
    /// 未配置时 caiyunToken 为空字符串，`fetchFromCaiyun` 会抛出 `missingAPIToken`，
    /// 并自动回退到 Open-Meteo（见 `fetchDailyWeather`）。
    /// 请勿在此处硬编码任何真实 token —— 请到 https://platform.caiyunapp.com 免费申请你自己的 token，
    /// 并通过 Info.plist 的 `CaiyunWeatherToken` 字段或 init 的 `caiyunToken` 参数注入。
    private static let caiyunTokenInfoKey = "CaiyunWeatherToken"

    private let session: URLSession
    private let maxAttempts: Int
    private let caiyunToken: String
    private let enableOpenMeteoFallback: Bool

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(
        session: URLSession? = nil,
        maxAttempts: Int = 3,
        caiyunToken: String? = nil,
        enableOpenMeteoFallback: Bool = true
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            config.httpAdditionalHeaders = [
                "Accept": "application/json",
                "User-Agent": "echo-ios-weather/1.1"
            ]
            self.session = URLSession(configuration: config)
        }
        self.maxAttempts = max(1, maxAttempts)
        self.caiyunToken = Self.resolveToken(explicit: caiyunToken)
        self.enableOpenMeteoFallback = enableOpenMeteoFallback
    }

    /// 获取指定经纬度位置的当日天气数据
    func fetchDailyWeather(latitude: Double, longitude: Double) async throws -> DailyWeather {
        do {
            return try await fetchFromCaiyun(latitude: latitude, longitude: longitude)
        } catch let primaryError {
            guard enableOpenMeteoFallback else { throw primaryError }
            // 国内主源失败时再试 Open-Meteo（海外网络通常可用）
            do {
                return try await fetchFromOpenMeteo(latitude: latitude, longitude: longitude)
            } catch {
                // 优先抛出主源错误，便于排查国内链路
                throw primaryError
            }
        }
    }

    // MARK: - 彩云天气（主源）

    private func fetchFromCaiyun(latitude: Double, longitude: Double) async throws -> DailyWeather {
        guard !caiyunToken.isEmpty else {
            throw WeatherError.missingAPIToken
        }
        // 彩云路径顺序是 经度,纬度
        guard let url = URL(string: "https://api.caiyunapp.com/v2.5/\(caiyunToken)/\(longitude),\(latitude)/daily?dailysteps=1&unit=metric") else {
            throw WeatherError.invalidURL
        }

        let data = try await requestData(from: url)
        let decoded: CaiyunDailyResponse
        do {
            decoded = try JSONDecoder().decode(CaiyunDailyResponse.self, from: data)
        } catch {
            throw WeatherError.decodingError(error)
        }

        guard decoded.status == "ok" else {
            throw WeatherError.upstreamError(decoded.error ?? decoded.status)
        }

        guard let temperature = decoded.result?.daily?.temperature?.first,
              let skycon = decoded.result?.daily?.skycon?.first else {
            throw WeatherError.incompleteData
        }

        let description = Self.caiyunSkyconDescription(skycon.value)
        let code = Self.caiyunSkyconCode(skycon.value)

        return DailyWeather(
            date: extractDate(from: temperature.date),
            maxTemp: temperature.max,
            minTemp: temperature.min,
            weatherCode: code,
            weatherDescription: description
        )
    }

    // MARK: - Open-Meteo（兜底）

    private func fetchFromOpenMeteo(latitude: Double, longitude: Double) async throws -> DailyWeather {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current_weather", value: "true"),
            URLQueryItem(name: "current", value: "weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components?.url else {
            throw WeatherError.invalidURL
        }

        let data = try await requestData(from: url)
        let decoded: OpenMeteoResponse
        do {
            decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            throw WeatherError.decodingError(error)
        }

        guard let maxTemp = decoded.daily.temperature2mMax.first,
              let minTemp = decoded.daily.temperature2mMin.first else {
            throw WeatherError.incompleteData
        }

        let weatherCode = decoded.currentWeather?.weathercode
            ?? decoded.current?.weatherCode
        guard let weatherCode else {
            throw WeatherError.incompleteData
        }

        let date = decoded.daily.time?.first
            ?? decoded.currentWeather.map { extractDate(from: $0.time) }
            ?? decoded.current.map { extractDate(from: $0.time) }
            ?? dateFormatter.string(from: Date())

        return DailyWeather(
            date: date,
            maxTemp: maxTemp,
            minTemp: minTemp,
            weatherCode: weatherCode,
            weatherDescription: Self.openMeteoWeatherDescription(for: weatherCode)
        )
    }

    // MARK: - 网络

    private func requestData(from url: URL) async throws -> Data {
        var lastError: WeatherError = .invalidResponse(statusCode: nil)

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw WeatherError.invalidResponse(statusCode: nil)
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    // 彩云配额耗尽等常见 4xx 也尽量读 body 里的 error
                    if let body = try? JSONDecoder().decode(CaiyunDailyResponse.self, from: data),
                       let message = body.error, !message.isEmpty {
                        throw WeatherError.upstreamError(message)
                    }
                    throw WeatherError.invalidResponse(statusCode: httpResponse.statusCode)
                }
                return data
            } catch let error as WeatherError {
                lastError = error
                guard attempt < maxAttempts, Self.shouldRetry(error) else {
                    throw error
                }
            } catch {
                let mapped = Self.mapURLError(error)
                lastError = mapped
                guard attempt < maxAttempts, Self.shouldRetry(mapped) else {
                    throw mapped
                }
            }

            let delayNs = UInt64(pow(2.0, Double(attempt - 1)) * 0.35 * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
        }

        throw lastError
    }

    private static func resolveToken(explicit: String?) -> String {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        if let plistToken = Bundle.main.object(forInfoDictionaryKey: caiyunTokenInfoKey) as? String,
           !plistToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plistToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func extractDate(from timeString: String) -> String {
        // "2026-07-21T00:00+08:00" / "2026-07-21T10:00"
        String(timeString.prefix(10))
    }

    private static func mapURLError(_ error: Error) -> WeatherError {
        let urlError = error as? URLError
        switch urlError?.code {
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed(error)
        case .timedOut:
            return .timeout(error)
        default:
            return .networkError(error)
        }
    }

    private static func shouldRetry(_ error: WeatherError) -> Bool {
        switch error {
        case .secureConnectionFailed, .timeout, .networkError, .invalidResponse:
            return true
        case .invalidURL, .missingAPIToken, .upstreamError, .decodingError, .incompleteData:
            return false
        }
    }

    // MARK: - 描述映射

    /// 彩云 skycon → 中文描述
    private static func caiyunSkyconDescription(_ skycon: String) -> String {
        switch skycon.uppercased() {
        case "CLEAR_DAY", "CLEAR_NIGHT":
            return "晴朗"
        case "PARTLY_CLOUDY_DAY", "PARTLY_CLOUDY_NIGHT":
            return "多云"
        case "CLOUDY":
            return "阴"
        case "LIGHT_HAZE":
            return "轻度雾霾"
        case "MODERATE_HAZE":
            return "中度雾霾"
        case "HEAVY_HAZE":
            return "重度雾霾"
        case "LIGHT_RAIN":
            return "小雨"
        case "MODERATE_RAIN":
            return "中雨"
        case "HEAVY_RAIN":
            return "大雨"
        case "STORM_RAIN":
            return "暴雨"
        case "FOG":
            return "雾"
        case "LIGHT_SNOW":
            return "小雪"
        case "MODERATE_SNOW":
            return "中雪"
        case "HEAVY_SNOW":
            return "大雪"
        case "STORM_SNOW":
            return "暴雪"
        case "DUST":
            return "浮尘"
        case "SAND":
            return "沙尘"
        case "WIND":
            return "大风"
        default:
            return "未知天气"
        }
    }

    /// 稳定 int code，便于缓存字段兼容
    private static func caiyunSkyconCode(_ skycon: String) -> Int {
        switch skycon.uppercased() {
        case "CLEAR_DAY", "CLEAR_NIGHT": return 0
        case "PARTLY_CLOUDY_DAY", "PARTLY_CLOUDY_NIGHT": return 2
        case "CLOUDY": return 3
        case "FOG": return 45
        case "LIGHT_HAZE": return 51
        case "MODERATE_HAZE": return 53
        case "HEAVY_HAZE": return 55
        case "LIGHT_RAIN": return 61
        case "MODERATE_RAIN": return 63
        case "HEAVY_RAIN": return 65
        case "STORM_RAIN": return 67
        case "LIGHT_SNOW": return 71
        case "MODERATE_SNOW": return 73
        case "HEAVY_SNOW": return 75
        case "STORM_SNOW": return 77
        case "DUST", "SAND": return 80
        case "WIND": return 85
        default: return -1
        }
    }

    private static func openMeteoWeatherDescription(for code: Int) -> String {
        switch code {
        case 0:
            return "晴朗"
        case 1, 2, 3:
            return "多云"
        case 45, 48:
            return "雾"
        case 51, 53, 55:
            return "小雨"
        case 56, 57:
            return "冻雨"
        case 61, 63, 65:
            return "中雨"
        case 66, 67:
            return "大雨"
        case 71, 73, 75:
            return "小雪"
        case 77:
            return "雪粒"
        case 80, 81, 82:
            return "阵雨"
        case 85, 86:
            return "阵雪"
        case 95:
            return "雷暴"
        case 96, 99:
            return "雷暴伴有冰雹"
        default:
            return "未知天气"
        }
    }
}
