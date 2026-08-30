import Foundation

/// Registry of tools the model may call in one reply turn.
///
/// Built at composition root and injected into `ConversationManager`. The
/// **MCP master switch lives at the call site, not here**: `ConversationManager`
/// only consults `definitions` / `executor(for:)` when `AppSettings.enableMCP`
/// is true, so a disabled toggle means tools are never registered or handed to
/// the model at all.
///
/// Names are unique; registering two tools with the same name keeps the last
/// one (later registrations win), mirroring override semantics.
struct ToolRegistry: Sendable {
    private let tools: [String: any LLMTool]

    init(tools: [any LLMTool]) {
        var map: [String: any LLMTool] = [:]
        for tool in tools {
            map[tool.definition.name] = tool
        }
        self.tools = map
    }

    /// All registered definitions, sorted by name for stable prompt ordering.
    var definitions: [LLMToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    /// Returns an executor bound to the registered tool, or nil if `name` is
    /// not registered (caller throws `ToolCallLoopError.noToolRegistered`).
    func executor(for name: String) -> ToolCallLoop.ToolExecutor? {
        guard let tool = tools[name] else { return nil }
        return { call in
            try await tool.execute(call)
        }
    }

    /// Build a `ToolRegistry` from an MCP connector by fetching remote tool
    /// definitions and creating `RemoteMCPTool` proxies that forward calls to
    /// the connector. This is useful for tests and for a future real MCP
    /// connector integration.
    static func makeFrom(connector: MCPConnector) async throws -> ToolRegistry {
        let defs = try await connector.fetchTools()
        let wrapped: [any LLMTool] = defs.map { def in
            RemoteMCPTool(definition: def) { call in
                try await connector.callTool(call)
            }
        }
        return ToolRegistry(tools: wrapped)
    }
}
