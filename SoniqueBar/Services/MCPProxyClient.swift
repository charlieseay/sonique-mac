import Foundation

/// Client for vault-mcp proxy on localhost:8108
/// Provides lazy-loading of MCP tools instead of loading all servers at startup
struct MCPProxyClient {

    private static let proxyURL = "http://localhost:8108"

    /// Query available tools from vault-mcp
    static func queryAvailableTools() async -> [[String: Any]] {
        do {
            guard let url = URL(string: "\(proxyURL)/tools/list") else {
                return []
            }

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tools = json["tools"] as? [[String: Any]] else {
                return []
            }

            return tools

        } catch {
            NSLog("[MCPProxy] Failed to query tools: \(error.localizedDescription)")
            return []
        }
    }

    /// Execute a tool via vault-mcp
    static func executeTool(name: String, params: [String: Any]) async -> [String: Any]? {
        do {
            guard let url = URL(string: "\(proxyURL)/tools/execute") else {
                return nil
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "tool": name,
                "params": params
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        } catch {
            NSLog("[MCPProxy] Failed to execute tool \(name): \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if vault-mcp is running and reachable
    static func isAvailable() async -> Bool {
        do {
            guard let url = URL(string: "\(proxyURL)/health") else {
                return false
            }

            let (_, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            return httpResponse.statusCode == 200

        } catch {
            return false
        }
    }
}
