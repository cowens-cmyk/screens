import Foundation
import Testing

@testable import PresenterCore

/// Two libraries syncing through a real hub over real sockets. Runs only
/// with a hub to talk to, e.g. the CMS Worker under `wrangler dev`:
/// CLOUD_SYNC_HUB=ws://localhost:8799/api/screens/sync CLOUD_SYNC_TOKEN=…
/// The hub must start empty for the seeding check.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLOUD_SYNC_HUB"] != nil))
struct CloudSyncHubTests {
    private final class Link: @unchecked Sendable {
        let socket: URLSessionWebSocketTask
        var session: CloudSyncSession!
        var reader: Task<Void, Never>?

        init(url: URL) {
            socket = URLSession.shared.webSocketTask(with: url)
            socket.maximumMessageSize = 64 << 20
        }
    }

    @LibraryActor private func connect(_ engine: LibraryEngine, url: URL, token: String) async throws -> Link {
        let link = Link(url: url)
        let socket = link.socket
        link.session = CloudSyncSession(engine: engine, token: token, app: "test") { message in
            try await socket.send(.string(String(decoding: try message.encoded(), as: UTF8.self)))
        }
        socket.resume()
        let session = link.session!
        link.reader = Task { @LibraryActor in
            while let message = try? await socket.receive() {
                let data: Data = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                try? await session.receive(CloudServerMessage.decode(data))
            }
        }
        try await session.opened()
        return link
    }

    @LibraryActor private func until(_ what: String, _ condition: @LibraryActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while try !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out: \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @LibraryActor @Test func twoMacsShareALibraryThroughTheHub() async throws {
        let environment = ProcessInfo.processInfo.environment
        let url = try #require(environment["CLOUD_SYNC_HUB"].flatMap(URL.init(string:)))
        let token = try #require(environment["CLOUD_SYNC_TOKEN"])
        let roots = (0..<2).map { _ in FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)") }
        defer { roots.forEach { try? FileManager.default.removeItem(at: $0) } }
        let studio = LibraryEngine(rootURL: roots[0])
        let laptop = LibraryEngine(rootURL: roots[1])
        _ = try studio.bootstrap()
        _ = try laptop.bootstrap()

        let big = (0..<400).map { "Line \($0) " + String(repeating: "word ", count: 1200) }
        try studio.create(Presentation(
            id: "hub-song", name: "Through the hub", presentationKind: .song, themeId: "",
            slides: big.enumerated().map { index, text in
                Slide(id: "s\(index)", name: "Verse", objects: [SlideObject(id: "t\(index)", objectKind: .text, name: "Lyrics", text: text)])
            }))

        let first = try await connect(studio, url: url, token: token)
        try await until("studio live") { first.session.phase == .live }
        try await until("seeded") { try studio.cloudOwedKeys().isEmpty && first.session.waiting == 0 }

        let second = try await connect(laptop, url: url, token: token)
        try await until("join offered") { if case .needsJoin = second.session.phase { true } else { false } }
        second.socket.cancel(with: .normalClosure, reason: nil)
        try second.session.join()
        let rejoined = try await connect(laptop, url: url, token: token)
        try await until("laptop has the song") {
            (try? laptop.replica(Presentation.self, id: "hub-song").value.slides.count) == 400
        }

        try laptop.modify(Presentation.self, id: "hub-song") { $0.name = "Edited on the laptop" }
        try await rejoined.session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: "hub-song")], deleted: [])
        try await until("studio sees the edit") {
            try studio.replica(Presentation.self, id: "hub-song").value.name == "Edited on the laptop"
        }

        try studio.delete(kind: .presentation, id: "hub-song")
        try await first.session.noteLocal(edited: [], deleted: [SyncLedger.Key(kind: .presentation, id: "hub-song")])
        try await until("laptop deleted it") { !(try laptop.cloudDocumentKeys().contains(SyncLedger.Key(kind: .presentation, id: "hub-song"))) }

        first.socket.cancel(with: .normalClosure, reason: nil)
        rejoined.socket.cancel(with: .normalClosure, reason: nil)
    }
}
