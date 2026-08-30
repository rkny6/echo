//
//  LLMProviderToolCallTests.swift
//  echoTests
//

import Foundation
import Testing
@testable import echo

// MARK: - LLMMessage / LLMToolCall

struct LLMMessageTypeTests {
    @Test func messageCodableRoundTripPreservesToolFields() throws {
        let call = LLMToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Tokyo"}"#)
        let message = LLMMessage(role: .assistant, content: nil, toolCallID: nil, toolCalls: [call])
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        #expect(decoded == message)
        #expect(decoded.toolCalls?.first?.name == "get_weather")
        #expect(decoded.toolCalls?.first?.arguments.contains("Tokyo") == true)
    }

    @Test func toolMessageCarriesCallID() {
        let message = LLMMessage(role: .tool, content: "20度", toolCallID: "call_1")
        #expect(message.role == .tool)
        #expect(message.toolCallID == "call_1")
        #expect(message.content == "20度")
    }
}

// MARK: - OpenAICompatibleResponse tool-call decoding

struct OpenAIResponseToolCallDecodingTests {
    @Test func chatCompletionsToolCallsDecode() throws {
        let json = """
        {"choices": [{"message": {
          "role": "assistant",
          "content": null,
          "tool_calls": [
            {"id": "call_abc", "type": "function", "function": {"name": "get_weather", "arguments": "{\\"city\\": \\"Tokyo\\"}"}}
          ]
        }}]}
        """
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: Data(json.utf8))
        let calls = response.toolCalls()
        #expect(calls?.count == 1)
        #expect(calls?.first?.id == "call_abc")
        #expect(calls?.first?.name == "get_weather")
        #expect(calls?.first?.arguments.contains("Tokyo") == true)
    }

    @Test func responsesFunctionCallDecodes() throws {
        let json = """
        {"output": [
          {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "get_weather", "arguments": "{\\"city\\": \\"Tokyo\\"}", "status": "completed"},
          {"type": "message", "content": [{"type": "output_text", "text": "东京今天20度"}]}
        ]}
        """
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: Data(json.utf8))
        let calls = response.toolCalls()
        #expect(calls?.count == 1)
        #expect(calls?.first?.id == "call_1")
        #expect(calls?.first?.name == "get_weather")
        let text = response.output?.compactMap { item in
            item.content?.compactMap { $0.text }.joined(separator: "\n")
        }.joined(separator: "\n")
        #expect(text == "东京今天20度")
    }

    @Test func plainTextResponseHasNoToolCalls() throws {
        let json = """
        {"choices": [{"message": {"role": "assistant", "content": "你好"}}]}
        """
        let response = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: Data(json.utf8))
        #expect(response.toolCalls() == nil)
    }
}

// MARK: - MockLLMProvider

struct MockLLMProviderTests {
    @Test func scriptedResultsRepeatLast() async throws {
        let provider = MockLLMProvider(script: [.text("first")])
        let r1 = try await provider.generate(
            messages: [LLMMessage(role: .user, content: "a")],
            tools: nil, temperature: 0.7, maxTokens: 10
        )
        let r2 = try await provider.generate(
            messages: [LLMMessage(role: .user, content: "b")],
            tools: nil, temperature: 0.7, maxTokens: 10
        )
        #expect(r1 == .text("first"))
        #expect(r2 == .text("first"))
    }

    @Test func recordsToolCallTranscript() async throws {
        let call = LLMToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Tokyo"}"#)
        let provider = MockLLMProvider(script: [.toolCalls([call]), .text("晴天")])
        _ = try await provider.generate(
            messages: [LLMMessage(role: .user, content: "天气怎么样？")],
            tools: nil, temperature: 0.7, maxTokens: 10
        )
        _ = try await provider.generate(
            messages: [LLMMessage(role: .tool, content: "20度", toolCallID: "call_1")],
            tools: nil, temperature: 0.7, maxTokens: 10
        )
        let transcript = await provider.receivedMessages
        #expect(transcript.count == 2)
        #expect(transcript[0].last?.role == .user)
        #expect(transcript[1].last?.role == .tool)
        #expect(transcript[1].last?.toolCallID == "call_1")
        #expect(await provider.callCount == 2)
    }

    @Test func emptyScriptThrows() async {
        let provider = MockLLMProvider(script: [])
        await #expect(throws: LLMMockError.self) {
            _ = try await provider.generate(
                messages: [LLMMessage(role: .user, content: "x")],
                tools: nil, temperature: 0.7, maxTokens: 10
            )
        }
    }
}

// MARK: - Default sendMessage (plain text path)

struct LLMProviderSendMessageTests {
    @Test func sendMessageExtractsText() async throws {
        let provider = MockLLMProvider(script: [.text("你好呀")])
        let text = try await provider.sendMessage(
            systemPrompt: "sys", userMessage: "hi", temperature: 0.7, maxTokens: 10
        )
        #expect(text == "你好呀")
    }

    @Test func sendMessageThrowsOnUnexpectedToolCalls() async {
        let call = LLMToolCall(id: "call_1", name: "get_weather", arguments: "{}")
        let provider = MockLLMProvider(script: [.toolCalls([call])])
        await #expect(throws: OpenAICompatibleError.self) {
            _ = try await provider.sendMessage(
                systemPrompt: "sys", userMessage: "hi", temperature: 0.7, maxTokens: 10
            )
        }
    }
}

// MARK: - withTransientRetry

struct TransientRetryTests {
    @Test func transientErrorIsRetriedUntilSuccess() async throws {
        var attempts = 0
        let result = try await withTransientRetry(maxAttempts: 3, logger: nil) {
            attempts += 1
            if attempts < 3 { throw URLError(.notConnectedToInternet) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts == 3)
    }

    @Test func permanentErrorIsNotRetried() async {
        var attempts = 0
        await #expect(throws: OpenAICompatibleError.self) {
            _ = try await withTransientRetry(maxAttempts: 3, logger: nil) {
                attempts += 1
                throw OpenAICompatibleError.invalidResponse
            }
        }
        #expect(attempts == 1)
    }

    @Test func serverFiveHundredIsRetried() async {
        var attempts = 0
        await #expect(throws: OpenAICompatibleError.self) {
            _ = try await withTransientRetry(maxAttempts: 2, logger: nil) {
                attempts += 1
                throw OpenAICompatibleError.invalidResponseStatus(status: 500, body: "boom")
            }
        }
        #expect(attempts == 2)
    }
}

// MARK: - Adapter integration (URLProtocol-stubbed transport)

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var capturedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession converts `request.httpBody` into an `httpBodyStream` before
    /// handing the request to a URLProtocol, so `httpBody` reads as nil inside
    /// `startLoading`. Read the stream (or the body) to capture the payload.
    static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var result = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func startLoading() {
        StubURLProtocol.capturedBodies.append(Self.bodyData(from: request))
        guard let handler = StubURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// A dedicated session whose configuration lists `StubURLProtocol` first.
    /// `URLSession.shared` ignores `URLProtocol.registerClass` once its
    /// configuration is cached, so tests must inject a session instead.
    static func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Both tests drive the same `StubURLProtocol` static state, so they must
/// run serially (swift-testing parallelizes within a suite by default).
@Suite(.serialized)
struct AdapterToolCallIntegrationTests {
    @Test func chatCompletionsSendsToolsAndDecodesToolCalls() async throws {
        StubURLProtocol.requestHandler = { request in
            let json = """
            {"choices": [{"message": {
              "role": "assistant",
              "content": null,
              "tool_calls": [
                {"id": "call_abc", "type": "function", "function": {"name": "get_weather", "arguments": "{\\"city\\": \\"Tokyo\\"}"}}
              ]
            }}]}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
        defer {
            StubURLProtocol.requestHandler = nil
            StubURLProtocol.capturedBodies = []
        }

        let adapter = CustomOpenAICompatibleAdapter(
            apiKey: "test-key",
            baseURL: "https://example.test/v1",
            modelName: "gpt-test",
            endpointMode: .chatCompletions,
            session: StubURLProtocol.makeStubbedSession()
        )

        let tool = LLMToolDefinition(
            name: "get_weather",
            description: "查询城市天气",
            parameters: .init(
                properties: [
                    "city": .init(type: "string", description: "城市名", enumValues: ["Tokyo", "Beijing"])
                ],
                required: ["city"]
            )
        )

        let result = try await adapter.generate(
            messages: [LLMMessage(role: .user, content: "东京天气怎么样？")],
            tools: [tool],
            temperature: 0.7,
            maxTokens: 100
        )

        guard case .toolCalls(let calls) = result else {
            Issue.record("expected toolCalls, got \(result)")
            return
        }
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.arguments.contains("Tokyo") == true)

        let payload = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
        #expect((payload["messages"] as? [[String: Any]])?.count == 1)
        let tools = payload["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        let function = tools?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "get_weather")
        let parameters = function?["parameters"] as? [String: Any]
        #expect(parameters?["type"] as? String == "object")
        #expect(parameters?["required"] as? [String] == ["city"])
    }

    @Test func responsesModeSerializesToolCallRoundTrip() async throws {
        StubURLProtocol.requestHandler = { request in
            let json = """
            {"output": [{"type": "message", "content": [{"type": "output_text", "text": "东京今天20度"}]}]}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
        defer {
            StubURLProtocol.requestHandler = nil
            StubURLProtocol.capturedBodies = []
        }

        let adapter = CustomOpenAICompatibleAdapter(
            apiKey: "test-key",
            baseURL: "https://example.test/v1",
            modelName: "gpt-test",
            endpointMode: .responses,
            session: StubURLProtocol.makeStubbedSession()
        )

        let call = LLMToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Tokyo"}"#)
        let transcript = [
            LLMMessage(role: .user, content: "东京天气怎么样？"),
            LLMMessage(role: .assistant, content: nil, toolCallID: nil, toolCalls: [call]),
            LLMMessage(role: .tool, content: "20度", toolCallID: "call_1")
        ]

        let result = try await adapter.generate(
            messages: transcript,
            tools: nil,
            temperature: 0.7,
            maxTokens: 100
        )
        guard case .text(let text) = result else {
            Issue.record("expected text, got \(result)")
            return
        }
        #expect(text.contains("东京今天20度"))

        let payload = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
        let input = payload["input"] as? [[String: Any]]
        #expect(input?.count == 3)
        let toolCalls = input?[1]["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == "call_1")
        #expect(input?[2]["role"] as? String == "tool")
        #expect(input?[2]["tool_call_id"] as? String == "call_1")
        #expect(input?[2]["content"] as? String == "20度")
    }
}
