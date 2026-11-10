import Foundation

/// A Model Context Protocol server on the Local API, so Claude (Claude Code,
/// or Claude Desktop through a local bridge) can build presentations in the
/// library. It speaks the protocol's Streamable HTTP transport in its plainest
/// form: each POST to /mcp is one JSON-RPC message, answered with one JSON
/// reply, and nothing is streamed. It sits behind the same bearer token as the
/// rest of the API; a tool needs the scope it names, so a view token can read
/// the library but not change it.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var scope: APIScope
    public var readOnly: Bool
    public var handler: @MainActor @Sendable (JSONValue) async throws -> MCPToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue,
        scope: APIScope, readOnly: Bool = false,
        handler: @escaping @MainActor @Sendable (JSONValue) async throws -> MCPToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.scope = scope
        self.readOnly = readOnly
        self.handler = handler
    }
}

/// What a tool hands back: text for Claude to read, and optionally the same
/// thing as structured JSON.
public struct MCPToolResult: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    /// The value as pretty JSON text, and as structured content.
    public static func json(_ value: some Encodable, summary: String? = nil) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let structured = try? JSONDecoder().decode(JSONValue.self, from: data)
        let objectLike: JSONValue? = if case .object = structured { structured } else { nil }
        return MCPToolResult(text: summary.map { $0 + "\n\n" + text } ?? text, structured: objectLike)
    }
}

/// A tool's input was wrong in a way Claude can fix and try again.
public struct MCPToolError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct MCPServer: Sendable {
    /// Newest first. The client's version is used when it is one of these.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public var name: String
    public var version: String
    public var instructions: String
    public var tools: [MCPTool]

    public init(name: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// The route the Local API serves it on.
    public func route() -> APIRoute {
        APIRoute(
            "POST", "/mcp", scope: .view,
            operationId: "mcp",
            summary: "Model Context Protocol (Streamable HTTP, JSON replies). Tools for building presentations.",
            tag: "MCP",
            requestSchema: ["type": "object"], responseSchema: ["type": "object"]
        ) { context in
            await handle(body: context.body, scope: context.scope)
        }
    }

    public func handle(body: Data, scope: APIScope) async -> APIHandlerResponse {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let fields) = message else {
            return reply(error: -32700, "Parse error", id: .null)
        }
        // A batch was allowed by one version of the protocol and dropped by
        // the next; nobody sends one to a server that doesn't offer it.
        guard case .string(let method)? = fields["method"] else {
            if fields["result"] != nil || fields["error"] != nil {
                return APIHandlerResponse(status: 202, body: Data())
            }
            return reply(error: -32600, "Invalid request", id: fields["id"] ?? .null)
        }
        guard let id = fields["id"], id != .null else {
            // A notification (initialized, cancelled): nothing to answer.
            return APIHandlerResponse(status: 202, body: Data())
        }
        let params = fields["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return reply(result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "title": "Screens", "version": .string(version)],
                "instructions": .string(instructions),
            ], id: id)
        case "ping":
            return reply(result: [:], id: id)
        case "tools/list":
            let listed = tools.filter { scope.allows($0.scope) }.map { tool -> JSONValue in
                [
                    "name": .string(tool.name),
                    "title": .string(tool.title),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": [
                        "title": .string(tool.title),
                        "readOnlyHint": .bool(tool.readOnly),
                        "destructiveHint": false,
                        "openWorldHint": false,
                    ],
                ]
            }
            return reply(result: ["tools": .array(listed)], id: id)
        case "tools/call":
            guard let toolName = params["name"]?.stringValue,
                  let tool = tools.first(where: { $0.name == toolName }) else {
                return reply(error: -32602, "Unknown tool: \(params["name"]?.stringValue ?? "")", id: id)
            }
            guard scope.allows(tool.scope) else {
                return reply(result: Self.content(MCPToolResult(
                    text: "This key can't \(tool.title.lowercased()). It takes a key with \(tool.scope == .edit ? "Manage" : "Operate") access: Screens › Settings › Remote & API › Manage Keys.",
                    isError: true)), id: id)
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                return reply(result: Self.content(try await tool.handler(arguments)), id: id)
            } catch let error as MCPToolError {
                return reply(result: Self.content(MCPToolResult(text: error.message, isError: true)), id: id)
            } catch let error as APIError {
                return reply(result: Self.content(MCPToolResult(text: error.message, isError: true)), id: id)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return reply(result: Self.content(MCPToolResult(text: message, isError: true)), id: id)
            }
        case "resources/list":
            return reply(result: ["resources": []], id: id)
        case "prompts/list":
            return reply(result: ["prompts": []], id: id)
        default:
            return reply(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    static func content(_ result: MCPToolResult) -> JSONValue {
        var out: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(result.text)]],
            "isError": .bool(result.isError),
        ]
        if let structured = result.structured { out["structuredContent"] = structured }
        return .object(out)
    }

    private func reply(result: JSONValue, id: JSONValue) -> APIHandlerResponse {
        .json(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func reply(error code: Int, _ message: String, id: JSONValue) -> APIHandlerResponse {
        .json(JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .integer(code), "message": .string(message)],
        ]))
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): value
        case .number(let value) where value.rounded() == value: Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
