import Foundation
import CoreLocation

/// Weather tool (`get_weather`) for the LLM tool loop.
///
/// Returns today's temperature range + Chinese weather description for a
/// user-supplied coordinate pair, or the device's current location when no
/// coordinates are given. Output is compact JSON fed back to the model:
/// `{"date": "...", "description": "...", "low": 18, "high": 26}`.
struct WeatherTool: LLMTool {
    /// Actual weather fetch, injectable for tests. Signature mirrors
    /// `DailyWeatherFetcher.fetchDailyWeather(latitude:longitude:)`.
    private let fetchWeather: @Sendable (Double, Double) async throws -> DailyWeather
    private let locationProvider: LocationProviding

    /// Production seam: wraps a `DailyWeatherFetcher`.
    init(
        locationProvider: LocationProviding,
        weatherFetcher: DailyWeatherFetcher = DailyWeatherFetcher()
    ) {
        self.locationProvider = locationProvider
        self.fetchWeather = { latitude, longitude in
            try await weatherFetcher.fetchDailyWeather(latitude: latitude, longitude: longitude)
        }
    }

    /// Test seam: inject the fetch closure directly, no network involved.
    init(
        locationProvider: LocationProviding,
        fetchWeather: @escaping @Sendable (Double, Double) async throws -> DailyWeather
    ) {
        self.locationProvider = locationProvider
        self.fetchWeather = fetchWeather
    }

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: "get_weather",
            description: "查询某个城市或当前位置今天的天气，返回温度范围与天气描述。当用户问到天气、穿衣建议、是否适合出门等话题时调用。",
            parameters: .init(
                properties: [
                    "city": .init(
                        type: "string",
                        description: "城市名（可选）。不提供经纬度时作为位置提示，实际仍以设备当前位置为准。"
                    ),
                    "latitude": .init(
                        type: "number",
                        description: "纬度（可选），与 longitude 成对使用，优先于当前位置。"
                    ),
                    "longitude": .init(
                        type: "number",
                        description: "经度（可选），与 latitude 成对使用，优先于当前位置。"
                    )
                ],
                required: []
            )
        )
    }

    func execute(_ call: LLMToolCall) async throws -> String {
        struct Arguments: Decodable {
            var city: String?
            var latitude: Double?
            var longitude: Double?
        }

        let arguments: Arguments
        do {
            arguments = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
        } catch {
            return #"{"error": "无法解析参数: \#(error.localizedDescription)"}"#
        }

        // Explicit coordinates win; otherwise fall back to device location.
        let coordinate: CLLocationCoordinate2D?
        if let latitude = arguments.latitude, let longitude = arguments.longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            coordinate = locationProvider.currentLocation
        }

        guard let coordinate else {
            return #"{"error": "没有可用的位置：未提供经纬度，也无法获取当前位置"}"#
        }

        do {
            let weather = try await fetchWeather(coordinate.latitude, coordinate.longitude)
            let low = Int(weather.minTemp.rounded())
            let high = Int(weather.maxTemp.rounded())
            return """
            {"date": "\(weather.date)", "description": "\(weather.weatherDescription)", "low": \(low), "high": \(high)}
            """
        } catch {
            return #"{"error": "天气查询失败: \#(error.localizedDescription)"}"#
        }
    }
}
