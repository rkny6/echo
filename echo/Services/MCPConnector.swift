import Foundation

/// Thin façade over `MCPClient` matching the shape `ToolRegistry.makeFrom`
/// expects (`fetchTools` / `callTool`). Kept separate from `MCPClient` so the
/// registry layer doesn't need to know MCP protocol details — it's also
/// where "one flaky server shouldn't take down the app" recovery lives: a
/// single retry with a fresh handshake if the request looks like it failed
/// because the server dropped the session, rather than because the request
/// itself was bad.
final class MCPConnector: Sendable {
    private let client: MCPClient
    private let logger: LoggingProviding?

    init(
        serverURL: URL,
        authToken: String? = nil,
        logger: LoggingProviding? = nil,
        session: URLSession = .shared
    ) {
        self.client = MCPClient(serverURL: serverURL, authToken: authToken, logger: logger, session: session)
        self.logger = logger
    }

    /// Convenience initializer for tests/previews that already own an
    /// `MCPClient` (e.g. pointed at a local test server).
    init(client: MCPClient, logger: LoggingProviding? = nil) {
        self.client = client
        self.logger = logger
    }

    func fetchTools() async throws -> [LLMToolDefinition] {
        do {
            return try await client.listTools()
        } catch let error as MCPClientError {
            throw error // well-formed protocol error — not a session issue, don't retry
        } catch {
            await logger?.log(
                "MCP fetchTools failed (\(error.localizedDescription)), retrying once after reset",
                level: .warning
            )
            await client.reset()
            return try await client.listTools()
        }
    }

    func callTool(_ call: LLMToolCall) async throws -> String {
        do {
            return try await client.callTool(name: call.name, arguments: call.arguments)
        } catch let error as MCPClientError {
            throw error
        } catch {
            await logger?.log(
                "MCP callTool(\(call.name)) failed (\(error.localizedDescription)), retrying once after reset",
                level: .warning
            )
            await client.reset()
            return try await client.callTool(name: call.name, arguments: call.arguments)
        }
    }
}
