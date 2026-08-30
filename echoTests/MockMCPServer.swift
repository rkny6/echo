import Foundation

/// Minimal in-memory test double for a single "mock_ping" tool. Not wired
/// into `MCPConnector` anymore — `MCPConnector` now speaks real MCP
/// (JSON-RPC over Streamable HTTP) via `MCPClient`. Kept for unit tests that
/// want an `LLMToolDefinition`/`callTool` pair without a real network round
/// trip; wrap it in a `RemoteMCPTool` the same way `MCPConnector`+`MCPClient`
/// do for the real thing.
///
/// `tools` is only ever set at init and never mutated afterwards, so plain
/// `@unchecked Sendable` is safe without a synchronization queue — this
/// class is test infrastructure, not production code, and lives under
/// `echoTests/` rather than the app target for that reason.
final class MockMCPServer: @unchecked Sendable {
    struct Tool: Codable {
        let name: String
        let description: String
    }

    private let tools: [Tool] = [Tool(name: "mock_ping", description: "Returns pong")]

    // Simulate tools/list
    func listTools() async throws -> [LLMToolDefinition] {
        return tools.map { tool in
            LLMToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: .init(properties: [:], required: [])
            )
        }
    }

    // Simulate callTool: expect arguments JSON; return text
    func callTool(name: String, arguments: String) async throws -> String {
        if name == "mock_ping" {
            return "pong"
        }
        return "{\"error\": \"unknown tool\"}"
    }
}
