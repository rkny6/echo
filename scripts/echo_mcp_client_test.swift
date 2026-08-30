// 真实 app 代码跑通 MCP 协议。
// 用法: swiftc -o /tmp/echo_mcp_client \
//   echo/Domain/LLM/JSONValue.swift \
//   echo/Services/MCP/MCPJSONRPC.swift \
//   echo/Protocols/LoggingProviding.swift \
//   echo/Domain/LLM/LLMToolDefinition.swift \
//   echo/Services/MCP/MCPStreamableHTTPTransport.swift \
//   echo/Services/MCP/MCPClient.swift \
//   -o /tmp/echo_mcp_client scripts/main.swift
import Foundation

@main
struct Main {
    static func main() async {
        let url = URL(string: "http://127.0.0.1:8000")!
        let client = MCPClient(serverURL: url, logger: nil)

        do {
            print("== listTools ==")
            let tools = try await client.listTools()
            for t in tools {
                print("  tool: \(t.name) :: \(t.description)")
            }

            print("== callTool get_weather {\"city\":\"北京\"} ==")
            let weather = try await client.callTool(name: "get_weather", arguments: #"{"city":"北京"}"#)
            print("  result: \(weather)")

            print("== callTool ping {} ==")
            let pong = try await client.callTool(name: "ping", arguments: #"{}"#)
            print("  result: \(pong)")
        } catch {
            print("❌ ERROR: \(error)")
            exit(1)
        }
    }
}