import Foundation
import Testing
@testable import LocalAPI

@Suite struct MCPServerTests {
    let server = MCPServer(name: "screens", version: "1.0", instructions: "Build presentations.", tools: [
        MCPTool(name: "list_plans", title: "List plans", description: "Plans.", inputSchema: ["type": "object"],
                scope: .view, readOnly: true) { _ in MCPToolResult(text: "two plans") },
        MCPTool(name: "build_song", title: "Build a song", description: "Song.", inputSchema: ["type": "object"],
                scope: .edit) { args in
            guard let title = args["title"]?.stringValue else { throw MCPToolError("Give the song a title.") }
            return .json(["id": "S1", "title": title], summary: "Built \(title).")
        },
    ])

    private func call(_ message: JSONValue, scope: APIScope = .edit) async throws -> (Int, JSONValue?) {
        let response = await server.handle(body: try JSONEncoder().encode(message), scope: scope)
        let body = response.body.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: response.body)
        return (response.status, body)
    }

    @Test func initializeAgreesOnAVersionItKnows() async throws {
        let (_, known) = try await call(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]])
        #expect(known?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(known?["result"]?["capabilities"]?["tools"] != nil)
        #expect(known?["result"]?["instructions"]?.stringValue == "Build presentations.")
        let (_, unknown) = try await call(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(unknown?["result"]?["protocolVersion"]?.stringValue == MCPServer.protocolVersions[0])
    }

    @Test func notificationsGetAnEmptyAccepted() async throws {
        let (status, body) = try await call(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(status == 202 && body == nil)
    }

    @Test func aViewTokenSeesOnlyReadingTools() async throws {
        let (_, view) = try await call(["jsonrpc": "2.0", "id": 3, "method": "tools/list"], scope: .view)
        #expect(view?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["list_plans"])
        let (_, edit) = try await call(["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        #expect(edit?["result"]?["tools"]?.arrayValue?.count == 2)
        #expect(edit?["result"]?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"] == .bool(true))
    }

    @Test func callsReturnTextAndStructuredContent() async throws {
        let (_, ok) = try await call(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                      "params": ["name": "build_song", "arguments": ["title": "The Lord Is With Me"]]])
        let result = ok?["result"]
        #expect(result?["isError"] == .bool(false))
        #expect(result?["structuredContent"]?["id"]?.stringValue == "S1")
        #expect(result?["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("Built The Lord Is With Me.") == true)
    }

    @Test func toolMistakesComeBackAsToolErrors() async throws {
        let (_, bad) = try await call(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "build_song", "arguments": [:]]])
        #expect(bad?["result"]?["isError"] == .bool(true))
        #expect(bad?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "Give the song a title.")
        let (_, denied) = try await call(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                          "params": ["name": "build_song", "arguments": ["title": "x"]]], scope: .view)
        #expect(denied?["result"]?["isError"] == .bool(true))
        let (_, missing) = try await call(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "nope"]])
        #expect(missing?["error"]?["code"]?.intValue == -32602)
        let (_, method) = try await call(["jsonrpc": "2.0", "id": 9, "method": "sampling/createMessage"])
        #expect(method?["error"]?["code"]?.intValue == -32601)
    }

    @Test func garbageIsAParseError() async throws {
        let response = await server.handle(body: Data("not json".utf8), scope: .edit)
        let body = try JSONDecoder().decode(JSONValue.self, from: response.body)
        #expect(body["error"]?["code"]?.intValue == -32700)
    }
}
