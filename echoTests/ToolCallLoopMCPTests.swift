import XCTest

@testable import echo

final class ToolCallLoopMCPTests: XCTestCase {
    func testToolCallLoopForwardsToMockMCP() async throws {
        let server = MockMCPServer()
        let defs = try await server.listTools()
        XCTAssertTrue(defs.contains { $0.name == "mock_ping" })

        // MockMCPServer is a test double standing in for the real MCP
        // client; wrap it in RemoteMCPTool exactly like MCPConnector wraps
        // MCPClient in production.
        let remoteTool = RemoteMCPTool(definition: defs[0]) { call in
            try await server.callTool(name: call.name, arguments: call.arguments)
        }

        let registry = ToolRegistry(tools: [remoteTool])
        let tools = registry.definitions

        // Fake provider: first generate -> asks to call mock_ping; second generate -> returns text using tool result
        final class FakeProvider: LLMProviderService {
            func testConnection() async throws -> Bool { true }

            func generate(messages: [LLMMessage], tools: [LLMToolDefinition]?, temperature: Double, maxTokens: Int) async throws -> LLMGenerationResult {
                // If a tool result message exists, return final text
                if let toolMsg = messages.first(where: { $0.role == .tool }) {
                    return .text("Final reply with tool result: \(toolMsg.content ?? "")")
                }

                // Otherwise request the model to call mock_ping
                let call = LLMToolCall(id: "c1", name: "mock_ping", arguments: "{}")
                return .toolCalls([call])
            }
        }

        let provider = FakeProvider()

        let initialMessages = [LLMMessage(role: .user, content: "What's the ping?")]

        let executor = registry.executor(for: "mock_ping")!

        let reply = try await ToolCallLoop.run(
            provider: provider,
            messages: initialMessages,
            tools: tools,
            executeTool: executor,
            temperature: 0.0,
            maxTokens: 128,
            maxRounds: 4,
            logger: nil
        )

        XCTAssertTrue(reply.contains("pong"))
    }
}
