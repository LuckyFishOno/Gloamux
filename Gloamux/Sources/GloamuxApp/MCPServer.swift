import App
import Foundation

/// `gloamux mcp`: a Model Context Protocol server on standard input and output for AI agents. It holds no secrets
/// and decides nothing itself: each tool call goes to the running Gloamux, which checks Settings › Agents, records
/// the request, and shows proposed commands to the user before anything runs.
enum MCPServer {
    static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        Gloamux is an SSH and terminal app on this Mac. The user decides which saved sessions you can see. You never \
        receive passwords or keys. Commands you propose run only after the user reviews them in Gloamux; check the \
        result with get_proposal, then ask the user to share the output (Terminal › Share with Agents) and read it \
        with read_shared_output.
        """

    static let tools: [[String: Any]] = [
        tool("list_sessions", "List the saved sessions the user allows agents to use, with their destinations and open tabs.",
             [:], required: []),
        tool("open_session", "Open an allowed session in Gloamux, or bring forward the tab where it is already open. Sign-in happens in Gloamux.",
             ["session": ["type": "string", "description": "Session name or ID from list_sessions."]], required: ["session"]),
        tool("read_shared_output", "Read terminal text the user shared with agents from Gloamux, oldest first.",
             ["after": ["type": "string", "description": "Only excerpts after this excerpt ID."]], required: []),
        tool("propose_command", "Propose one command for a connected session. Gloamux shows the full command and destination, and the user decides whether it runs.",
             ["session": ["type": "string", "description": "Session name or ID from list_sessions."],
              "command": ["type": "string", "description": "The exact command line to run."],
              "reason": ["type": "string", "description": "Why, in one sentence, shown to the user."],
              "tab": ["type": "string", "description": "A tab ID from list_sessions when the session is open in more than one tab."]],
             required: ["session", "command"]),
        tool("get_proposal", "Check whether the user ran or declined a proposed command: waiting, sent, declined, expired, or revoked.",
             ["proposal": ["type": "string", "description": "The ID propose_command returned."]], required: ["proposal"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    @MainActor static func run(_ arguments: [String]) async throws {
        if CLICatalog.asksForHelp(arguments) {
            print("""
                Usage: gloamux mcp [--workspace PATH]

                Serves the Model Context Protocol on standard input and output for an AI agent. Add this command to the
                agent's MCP settings. Gloamux must be open, with agent access turned on in Settings › Agents.
                """)
            return
        }
        let args = try CLIArguments(arguments, values: ["--workspace"], switches: [])
        guard args.operands.isEmpty else { throw CLIUsageError("Usage: gloamux mcp [--workspace PATH]") }
        let workspace = args.workspace ?? WorkspaceModel.defaultStorage
        var client = "Agent"
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let id = message["id"]
            guard let method = message["method"] as? String else { continue }   // A response to us; none are expected.
            let params = message["params"] as? [String: Any] ?? [:]
            if id == nil { continue }   // Notifications, such as notifications/initialized, need no answer.
            switch method {
            case "initialize":
                if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String, !name.isEmpty {
                    client = String(name.prefix(80))
                }
                let requested = params["protocolVersion"] as? String ?? versions[0]
                reply(id, ["protocolVersion": versions.contains(requested) ? requested : versions[0],
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "gloamux", "title": "Gloamux", "version": "1"],
                           "instructions": instructions])
            case "ping": reply(id, [:])
            case "tools/list": reply(id, ["tools": tools])
            case "tools/call":
                guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
                    write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32602, "message": "Unknown tool"]])
                    continue
                }
                let input = params["arguments"] as? [String: Any] ?? [:]
                reply(id, await call(name, input, client: client, workspace: workspace))
            default:
                write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "Method not found"]])
            }
        }
    }

    /// Sends one tool call to the running app and turns its answer into a tool result.
    @MainActor static func call(_ name: String, _ input: [String: Any], client: String, workspace: URL) async -> [String: Any] {
        func result(_ text: String, error: Bool) -> [String: Any] {
            ["content": [["type": "text", "text": text]], "isError": error]
        }
        do {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            let channel = try WorkspaceCommandChannel(workspace: workspace)
            if try channel.claim() {
                channel.release()
                return result("Gloamux is not open. Ask the user to open Gloamux and turn on agent access in Settings › Agents.", error: true)
            }
            guard let reply = try await channel.send(["agent", name, json, client]) else {
                channel.release()
                return result("Gloamux is not open. Ask the user to open Gloamux and turn on agent access in Settings › Agents.", error: true)
            }
            var output = result(reply.text, error: reply.code != 0)
            if reply.code == 0, let object = try? JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any] {
                output["structuredContent"] = object
            }
            return output
        } catch {
            return result(error.localizedDescription, error: true)
        }
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
