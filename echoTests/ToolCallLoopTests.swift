//
//  ToolCallLoopTests.swift
//  echoTests
//

import Foundation
import Testing
@testable import echo

// MARK: - ToolCallLoop

struct ToolCallLoopTests {
    private static let weatherTool = LLMToolDefinition(
        name: "get_weather",
        description: "查询天气",
        parameters: .init(
            properties: [
                "city": .init(type: "string", description: "城市名")
            ],
            required: ["city"]
        )
    )

    private static func weatherCall(city: String = "Tokyo") -> LLMToolCall {
        LLMToolCall(id: "call_1", name: "get_weather", arguments: #"{"city": "\#(city)"}"#)
    }

    @Test func singlePlainTurnReturnsText() async throws {
        let provider = MockLLMProvider(script: [.text("你好呀")])
        let text = try await ToolCallLoop.run(
            provider: provider,
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: [],
            executeTool: { _ in "" },
            temperature: 0.7,
            maxTokens: 10
        )
        #expect(text == "你好呀")
        #expect(await provider.callCount == 1)
        // Empty tools must be sent as nil, not an empty array.
        let received = await provider.receivedTools
        #expect(received.count == 1)
        #expect(received[0] == nil)
    }

    @Test func toolCallThenFinalTextRoundTrips() async throws {
        let provider = MockLLMProvider(script: [.toolCalls([Self.weatherCall()]), .text("东京 20 度")])
        let recorder = ExecutorRecorder()
        let text = try await ToolCallLoop.run(
            provider: provider,
            messages: [
                LLMMessage(role: .system, content: "sys"),
                LLMMessage(role: .user, content: "东京天气？")
            ],
            tools: [Self.weatherTool],
            executeTool: { call in
                recorder.record(call)
                return "20度"
            },
            temperature: 0.7,
            maxTokens: 10
        )
        #expect(text == "东京 20 度")
        #expect(await provider.callCount == 2)
        #expect(recorder.capturedNames == ["get_weather"])

        // Second generate sees the assistant tool-call + tool-result transcript.
        let transcript = await provider.receivedMessages
        #expect(transcript.count == 2)
        let second = transcript[1]
        #expect(second.count == 4)
        #expect(second[0].role == .system)
        #expect(second[1].role == .user)
        #expect(second[2].role == .assistant)
        #expect(second[2].toolCalls?.count == 1)
        #expect(second[3].role == .tool)
        #expect(second[3].toolCallID == "call_1")
        #expect(second[3].content == "20度")
    }

    @Test func multipleToolRoundsAreAllowed() async throws {
        let provider = MockLLMProvider(script: [
            .toolCalls([Self.weatherCall()]),
            .toolCalls([Self.weatherCall(city: "Osaka")]),
            .text("done")
        ])
        let recorder = ExecutorRecorder()
        let text = try await ToolCallLoop.run(
            provider: provider,
            messages: [LLMMessage(role: .user, content: "天气？")],
            tools: [Self.weatherTool],
            executeTool: { call in
                recorder.record(call)
                return "ok"
            },
            temperature: 0.7,
            maxTokens: 10
        )
        #expect(text == "done")
        #expect(await provider.callCount == 3)
        #expect(recorder.capturedNames == ["get_weather", "get_weather"])
    }

    @Test func roundLimitThrowsWhenModelNeverFinishes() async throws {
        let provider = MockLLMProvider(script: [
            .toolCalls([Self.weatherCall()]),
            .toolCalls([Self.weatherCall()]),
            .toolCalls([Self.weatherCall()]),
            .toolCalls([Self.weatherCall()]),
            .toolCalls([Self.weatherCall()]) // never reached
        ])
        await #expect(throws: ToolCallLoopError.self) {
            _ = try await ToolCallLoop.run(
                provider: provider,
                messages: [LLMMessage(role: .user, content: "天气？")],
                tools: [Self.weatherTool],
                executeTool: { _ in "ok" },
                temperature: 0.7,
                maxTokens: 10
            )
        }
        // 4 generate calls, then the round budget is exhausted.
        #expect(await provider.callCount == 4)
    }

    @Test func toolExecutionErrorIsFedBackToModel() async throws {
        let provider = MockLLMProvider(script: [.toolCalls([Self.weatherCall()]), .text("抱歉，天气服务不可用")])
        let text = try await ToolCallLoop.run(
            provider: provider,
            messages: [LLMMessage(role: .user, content: "天气？")],
            tools: [Self.weatherTool],
            executeTool: { _ in throw ToolCallLoopError.noToolRegistered(name: "get_weather") },
            temperature: 0.7,
            maxTokens: 10
        )
        #expect(text == "抱歉，天气服务不可用")
        let transcript = await provider.receivedMessages
        let toolMessage = transcript[1].last
        #expect(toolMessage?.role == .tool)
        #expect(toolMessage?.content?.contains("error") == true)
        #expect(toolMessage?.toolCallID == "call_1")
    }

    @Test func emptyToolCallsTreatsAsEmptyReply() async throws {
        let provider = MockLLMProvider(script: [.toolCalls([])])
        let text = try await ToolCallLoop.run(
            provider: provider,
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: [Self.weatherTool],
            executeTool: { _ in "unused" },
            temperature: 0.7,
            maxTokens: 10
        )
        #expect(text.isEmpty)
        #expect(await provider.callCount == 1)
    }
}

/// Thread-safe recorder for tool executions in tests.
private final class ExecutorRecorder: @unchecked Sendable {
    private var names: [String] = []

    func record(_ call: LLMToolCall) {
        names.append(call.name)
    }

    var capturedNames: [String] { names }
}
