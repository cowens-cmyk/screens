import Foundation
import LocalAPI
import PresenterCore

/// Claude through the CMS (dashboard.hopejc.org/screens/mcp), on this Mac.
/// The CMS signs Claude in and passes each MCP request over the sync socket;
/// this Mac answers it with the same tools as its Local API's /mcp
/// (ScreensMCP), less the ones that read files on this Mac.
///
/// Off unless turned on here (Settings › Integrations › Sync), and then only
/// on the Mac that runs the service (Run on this Mac): Claude can change the
/// whole library, so a Mac takes part only when someone at it said so. The
/// hub sends each request to one Mac, the one that last said it's ready.
@MainActor
final class ClaudeRelay {
    static let shared = ClaudeRelay()

    static let enabledKey = "claude.cloudTools"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// This Mac answers Claude.
    static var answers: Bool { enabled && ServiceStation.runsService }

    private var server: MCPServer?
    private var said: Bool?
    private var loop: Task<Void, Never>?

    private init() {}

    func attach(mcp: ScreensMCP) {
        server = mcp.server(version: OpenAPIDocument.apiVersion, remote: true)
        guard loop == nil else { return }
        // The switch or Run on this Mac can change at any time; the hub
        // hears within a few seconds.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tell()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The socket is (re)connected: the hub knows nothing about this Mac yet.
    func connected() {
        said = nil
        Task { await tell() }
    }

    private func tell() async {
        let now = Self.answers
        guard now != said, CloudSync.shared.status == .live else { return }
        if await CloudSync.shared.send(.claudeReady(on: now)) { said = now }
    }

    func handle(id: String, body: Data, user: String?) async {
        let reply: String
        if Self.answers, let server {
            let response = await server.handle(body: body, scope: .edit)
            reply = String(decoding: response.body, as: UTF8.self)
            DiagnosticsStore.shared.note("claude.cloud", detail: "\(Self.method(body)) for \(user ?? "someone")")
        } else {
            // The hub thought this Mac was ready; it isn't any more.
            let rpcID = (try? JSONDecoder().decode(JSONValue.self, from: body))?["id"] ?? .null
            let error: JSONValue = ["jsonrpc": "2.0", "id": rpcID, "error": [
                "code": -32603, "message": "Claude is turned off on this Mac (Settings › Sync), or it doesn't run the service."]]
            reply = (try? JSONEncoder().encode(error)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            said = nil
        }
        _ = await CloudSync.shared.send(.claudeDone(id: id, body: reply))
    }

    private static func method(_ body: Data) -> String {
        let message = try? JSONDecoder().decode(JSONValue.self, from: body)
        let method = message?["method"]?.stringValue ?? "?"
        guard method == "tools/call", let tool = message?["params"]?["name"]?.stringValue else { return method }
        return tool
    }
}
