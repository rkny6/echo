import Foundation

/// Unified adapter for OpenAI-compatible APIs that supports both Chat Completions and Responses.
actor CustomOpenAICompatibleAdapter: LLMProviderService {
    private let apiKey: String
    private let baseURL: String
    private let modelName: String
    private let endpointMode: LLMAPIEndpointMode
    private let session: URLSession
    private let logger: LoggingProviding?

    init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1",
        modelName: String = "gpt-4-turbo",
        endpointMode: LLMAPIEndpointMode = .chatCompletions,
        logger: LoggingProviding? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.endpointMode = endpointMode
        self.logger = logger
        self.session = session
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        temperature: Double,
        maxTokens: Int
    ) async throws -> LLMGenerationResult {
        let endpoint = endpointMode.endpointURL(baseURL: baseURL)
        guard let url = URL(string: endpoint) else {
            await logAPI(
                "LLM API request aborted: invalid endpoint URL \(endpoint)",
                level: .error
            )
            throw OpenAICompatibleError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Keep chat requests from hanging forever without feedback in Debug logs.
        request.timeoutInterval = 60

        var payload: [String: Any]
        switch endpointMode {
        case .chatCompletions:
            payload = [
                "model": modelName,
                "messages": Self.messagesPayload(messages),
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
        case .responses:
            payload = [
                "model": modelName,
                "input": Self.messagesPayload(messages),
                "temperature": temperature,
                "max_output_tokens": maxTokens
            ]
        }
        if let toolsPayload = Self.toolsPayload(tools, endpointMode: endpointMode) {
            payload["tools"] = toolsPayload
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        await logAPI(
            "LLM API request start: mode=\(endpointMode.rawValue) model=\(modelName) url=\(endpoint) messages=\(messages.count) tools=\(tools?.count ?? 0) chars=\(messages.reduce(0) { $0 + ($1.content?.count ?? 0) }) temp=\(temperature) maxTokens=\(maxTokens)",
            level: .debug
        )

        let requestStart = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            await logAPI(
                "LLM API transport failed after \(elapsedMs)ms: \(error.localizedDescription) (ns=\((error as NSError).domain)/\((error as NSError).code)) url=\(endpoint)",
                level: .error
            )
            throw error
        }

        let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)

        guard let httpResponse = response as? HTTPURLResponse else {
            await logAPI(
                "LLM API response invalid (non-HTTP) after \(elapsedMs)ms url=\(endpoint)",
                level: .error
            )
            throw OpenAICompatibleError.invalidResponse
        }

        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
            let truncatedBody = Self.truncateForLog(bodyString, limit: 400)
            await logAPI(
                "LLM API HTTP error status=\(httpResponse.statusCode) after \(elapsedMs)ms body=\(truncatedBody) url=\(endpoint)",
                level: .error
            )
            throw OpenAICompatibleError.invalidResponseStatus(status: httpResponse.statusCode, body: bodyString)
        }

        do {
            let result = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)

            if let toolCalls = result.toolCalls(), !toolCalls.isEmpty {
                await logAPI(
                    "LLM API success status=\(httpResponse.statusCode) after \(elapsedMs)ms toolCalls=\(toolCalls.count) source=tool_calls url=\(endpoint)",
                    level: .debug
                )
                return .toolCalls(toolCalls)
            }

            if let choice = result.choices?.first,
               let content = choice.message?.content,
               !content.isEmpty {
                await logAPI(
                    "LLM API success status=\(httpResponse.statusCode) after \(elapsedMs)ms responseChars=\(content.count) source=choices url=\(endpoint)",
                    level: .debug
                )
                return .text(content)
            }

            if let outputText = result.output?.compactMap({ item in
                item.content?.compactMap { $0.text }.joined(separator: "\n")
            }).joined(separator: "\n"),
               !outputText.isEmpty {
                await logAPI(
                    "LLM API success status=\(httpResponse.statusCode) after \(elapsedMs)ms responseChars=\(outputText.count) source=output url=\(endpoint)",
                    level: .debug
                )
                return .text(outputText)
            }

            let rawBody = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            await logAPI(
                "LLM API returned empty content status=\(httpResponse.statusCode) after \(elapsedMs)ms body=\(Self.truncateForLog(rawBody, limit: 400)) url=\(endpoint)",
                level: .error
            )
            throw OpenAICompatibleError.noContent
        } catch let error as OpenAICompatibleError {
            throw error
        } catch {
            let rawBody = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            await logAPI(
                "LLM API decode failed after \(elapsedMs)ms status=\(httpResponse.statusCode): \(error.localizedDescription) body=\(Self.truncateForLog(rawBody, limit: 400)) url=\(endpoint)",
                level: .error
            )
            throw error
        }
    }

    // MARK: - Payload Building

    private static func messagesPayload(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.map { message in
            var dict: [String: Any] = ["role": message.role.rawValue]
            dict["content"] = message.content ?? ""
            if let toolCallID = message.toolCallID {
                dict["tool_call_id"] = toolCallID
            }
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                dict["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments
                        ]
                    ]
                }
            }
            return dict
        }
    }

    private static func toolsPayload(
        _ tools: [LLMToolDefinition]?,
        endpointMode: LLMAPIEndpointMode
    ) -> [[String: Any]]? {
        guard let tools = tools, !tools.isEmpty else { return nil }
        switch endpointMode {
        case .chatCompletions:
            return tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": Self.schemaPayload(for: tool)
                    ]
                ]
            }
        case .responses:
            return tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": Self.schemaPayload(for: tool)
                ]
            }
        }
    }

    /// Prefers `rawSchema` (verbatim JSON Schema, e.g. from an MCP server's
    /// `inputSchema`) when present, since it can express nesting the flat
    /// `parameters` shape can't; falls back to reconstructing from
    /// `parameters` for locally-defined tools that never set `rawSchema`.
    private static func schemaPayload(for tool: LLMToolDefinition) -> [String: Any] {
        if let rawSchema = tool.rawSchema, case .object = rawSchema {
            return Self.foundationObject(from: rawSchema)
        }
        return Self.parametersPayload(tool.parameters)
    }

    private static func foundationObject(from value: JSONValue) -> [String: Any] {
        guard case .object(let dict) = value else { return [:] }
        var result: [String: Any] = [:]
        for (key, entry) in dict {
            result[key] = Self.foundationValue(from: entry)
        }
        return result
    }

    private static func foundationValue(from value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(Self.foundationValue)
        case .object:
            return Self.foundationObject(from: value)
        }
    }

    private static func parametersPayload(_ parameters: LLMToolDefinition.LLMToolParameters) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, parameter) in parameters.properties {
            var property: [String: Any] = [
                "type": parameter.type,
                "description": parameter.description
            ]
            if let enumValues = parameter.enumValues {
                property["enum"] = enumValues
            }
            properties[key] = property
        }
        return [
            "type": "object",
            "properties": properties,
            "required": parameters.required
        ]
    }

    func testConnection() async throws -> Bool {
        let endpoint = endpointMode.endpointURL(baseURL: baseURL)
        guard let url = URL(string: endpoint) else {
            await logAPI("LLM API test aborted: invalid endpoint URL \(endpoint)", level: .error)
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let payload: [String: Any]
        switch endpointMode {
        case .chatCompletions:
            payload = [
                "model": modelName,
                "messages": [
                    ["role": "user", "content": "ping"]
                ],
                "max_tokens": 8
            ]
        case .responses:
            payload = [
                "model": modelName,
                "input": "ping",
                "max_output_tokens": 8
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        await logAPI(
            "LLM API test start: mode=\(endpointMode.rawValue) model=\(modelName) url=\(endpoint)",
            level: .debug
        )

        let requestStart = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                await logAPI("LLM API test invalid non-HTTP response after \(elapsedMs)ms", level: .error)
                return false
            }

            let success = httpResponse.statusCode >= 200 && httpResponse.statusCode < 300
            if success {
                await logAPI(
                    "LLM API test success status=\(httpResponse.statusCode) after \(elapsedMs)ms",
                    level: .info
                )
            } else {
                let bodyString = String(data: data, encoding: .utf8) ?? "<no body>"
                await logAPI(
                    "LLM API test failed status=\(httpResponse.statusCode) after \(elapsedMs)ms body=\(Self.truncateForLog(bodyString, limit: 300))",
                    level: .error
                )
            }
            return success
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            await logAPI(
                "LLM API test transport failed after \(elapsedMs)ms: \(error.localizedDescription)",
                level: .error
            )
            throw error
        }
    }

    private func logAPI(_ message: String, level: LogLevel) async {
        // Always emit to OSLog so Xcode console has a signal even if Debug UI
        // logger isn't wired for a particular call site.
        switch level {
        case .debug:
            AppLog.debug("LLMAPI", message)
        case .info:
            AppLog.info("LLMAPI", message)
        case .warning:
            AppLog.warning("LLMAPI", message)
        case .error:
            AppLog.error("LLMAPI", message)
        }

        if let logger {
            await logger.log(message, level: level)
        }
    }

    private static func truncateForLog(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }
}
