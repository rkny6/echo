//
//  ToolRegistryTests.swift
//  echoTests
//

import Foundation
import CoreLocation
import Testing
@testable import echo

// MARK: - Test location provider (settable coordinate)

private final class TestLocationProvider: LocationProviding, @unchecked Sendable {
    var coordinate: CLLocationCoordinate2D?

    init(coordinate: CLLocationCoordinate2D? = nil) {
        self.coordinate = coordinate
    }

    var currentLocation: CLLocationCoordinate2D? { coordinate }

    func requestLocationUpdates() async {}
    func stopLocationUpdates() {}
    func isUserOut() async -> Bool { false }
    func setLocationEventHandler(_ handler: @escaping (CompanionEvent) async -> Void) {}
}

// MARK: - ToolRegistry

struct ToolRegistryTests {
    private struct StubTool: LLMTool {
        let name: String
        var definition: LLMToolDefinition {
            LLMToolDefinition(
                name: name,
                description: "stub \(name)",
                parameters: .init(properties: [:], required: [])
            )
        }

        func execute(_ call: LLMToolCall) async throws -> String {
            "stub:\(name)"
        }
    }

    @Test func definitionsReturnsRegisteredToolsSortedByName() {
        let registry = ToolRegistry(tools: [StubTool(name: "zebra"), StubTool(name: "apple")])
        let names = registry.definitions.map(\.name)
        #expect(names == ["apple", "zebra"])
    }

    @Test func executorDelegatesToRegisteredTool() async throws {
        let registry = ToolRegistry(tools: [StubTool(name: "ping")])
        let call = LLMToolCall(id: "c1", name: "ping", arguments: "{}")
        guard let executor = registry.executor(for: "ping") else {
            Issue.record("expected executor for ping")
            return
        }
        let result = try await executor(call)
        #expect(result == "stub:ping")
    }

    @Test func executorReturnsNilForUnregisteredName() {
        let registry = ToolRegistry(tools: [StubTool(name: "ping")])
        #expect(registry.executor(for: "nope") == nil)
    }

    @Test func duplicateNamesKeepLastRegistration() async throws {
        let registry = ToolRegistry(tools: [StubTool(name: "dup"), StubTool(name: "dup")])
        #expect(registry.definitions.count == 1)
        guard let executor = registry.executor(for: "dup") else {
            Issue.record("expected executor")
            return
        }
        let result = try await executor(LLMToolCall(id: "c1", name: "dup", arguments: "{}"))
        #expect(result == "stub:dup")
    }

    @Test func emptyRegistryHasNoDefinitionsAndNoExecutors() {
        let registry = ToolRegistry(tools: [])
        #expect(registry.definitions.isEmpty)
        #expect(registry.executor(for: "anything") == nil)
    }
}

// MARK: - WeatherTool

struct WeatherToolTests {
    private func makeWeatherTool(
        location: CLLocationCoordinate2D? = nil,
        fetch: @escaping @Sendable (Double, Double) async throws -> DailyWeather
    ) -> WeatherTool {
        WeatherTool(
            locationProvider: TestLocationProvider(coordinate: location),
            fetchWeather: fetch
        )
    }

    private static let sampleWeather = DailyWeather(
        date: "2026-08-09",
        maxTemp: 26.4,
        minTemp: 17.8,
        weatherCode: 4,
        weatherDescription: "多云"
    )

    @Test func definitionNamesToolGetWeather() {
        let tool = makeWeatherTool(fetch: { _, _ in Self.sampleWeather })
        #expect(tool.definition.name == "get_weather")
        #expect(tool.definition.parameters.required.isEmpty)
    }

    @Test func explicitCoordinatesWinOverDeviceLocation() async throws {
        var fetched: [(Double, Double)] = []
        let tool = makeWeatherTool(
            location: CLLocationCoordinate2D(latitude: 31.23, longitude: 121.47), // 上海
            fetch: { lat, lon in
                fetched.append((lat, lon))
                return Self.sampleWeather
            }
        )
        let call = LLMToolCall(
            id: "c1",
            name: "get_weather",
            arguments: #"{"latitude": 39.90, "longitude": 116.40}"# // 北京
        )
        let result = try await tool.execute(call)
        #expect(fetched.count == 1)
        #expect(abs(fetched[0].0 - 39.90) < 0.001)
        #expect(abs(fetched[0].1 - 116.40) < 0.001)
        #expect(result.contains("\"description\": \"多云\""))
        #expect(result.contains("\"low\": 18"))
        #expect(result.contains("\"high\": 26"))
        #expect(result.contains("\"date\": \"2026-08-09\""))
    }

    @Test func fallsBackToDeviceLocation() async throws {
        var fetched: [(Double, Double)] = []
        let tool = makeWeatherTool(
            location: CLLocationCoordinate2D(latitude: 1.23, longitude: 4.56),
            fetch: { lat, lon in
                fetched.append((lat, lon))
                return Self.sampleWeather
            }
        )
        let call = LLMToolCall(id: "c1", name: "get_weather", arguments: #"{"city": "上海"}"#)
        _ = try await tool.execute(call)
        #expect(fetched.count == 1)
        #expect(abs(fetched[0].0 - 1.23) < 0.001)
        #expect(abs(fetched[0].1 - 4.56) < 0.001)
    }

    @Test func noLocationReturnsErrorJSON() async throws {
        let tool = makeWeatherTool(
            location: nil,
            fetch: { _, _ in Self.sampleWeather }
        )
        let call = LLMToolCall(id: "c1", name: "get_weather", arguments: "{}")
        let result = try await tool.execute(call)
        #expect(result.contains("\"error\""))
    }

    @Test func fetchFailureReturnsErrorJSON() async throws {
        struct Boom: Error {}
        let tool = makeWeatherTool(
            location: CLLocationCoordinate2D(latitude: 1, longitude: 2),
            fetch: { _, _ in throw Boom() }
        )
        let call = LLMToolCall(id: "c1", name: "get_weather", arguments: "{}")
        let result = try await tool.execute(call)
        #expect(result.contains("\"error\""))
    }

    @Test func unparsableArgumentsReturnErrorJSON() async throws {
        let tool = makeWeatherTool(fetch: { _, _ in Self.sampleWeather })
        let call = LLMToolCall(id: "c1", name: "get_weather", arguments: "not-json")
        let result = try await tool.execute(call)
        #expect(result.contains("\"error\""))
    }
}
