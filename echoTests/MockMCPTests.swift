import XCTest

@testable import echo

final class MockMCPTests: XCTestCase {
    func testToolCallRoundtrip() async throws {
        let server = MockMCPServer()
        let definitions = try await server.listTools()
        XCTAssertTrue(definitions.contains { $0.name == "mock_ping" })

        // MockMCPServer is a test double standing in for the real MCP
        // client; wrap it in RemoteMCPTool exactly like MCPConnector wraps
        // MCPClient in production.
        let remoteTool = RemoteMCPTool(definition: definitions[0]) { call in
            try await server.callTool(name: call.name, arguments: call.arguments)
        }

        let call = LLMToolCall(id: "c1", name: "mock_ping", arguments: "{}")
        let result = try await remoteTool.execute(call)
        XCTAssertEqual(result, "pong")
    }
}
