import Foundation
import Testing

@testable import PresenterCore

/// The hub as docs/cloud-sync.md describes it, in memory: per-document chunk
/// logs with one sequence across them, catch-up after hello, live changes to
/// every other client, compaction on snapshot and reset, tombstones.
@LibraryActor private final class FakeHub {
    struct Row { var seq: Int; var kind: DocumentKind; var id: String; var bytes: Data; var mode: CloudSyncMode; var from: String }
    var rows: [Row] = []
    var seq = 0
    var pushes: [(client: String, mode: CloudSyncMode, size: Int)] = []
    private var inbox: [(client: String, message: CloudClientMessage)] = []
    private var outboxes: [String: [CloudServerMessage]] = [:]
    private var connected: Set<String> = []

    var liveDocs: Int {
        Set(rows.filter { $0.mode != .deleted }.map { "\($0.kind.rawValue)/\($0.id)" }).count
    }

    func sender(for client: String) -> @Sendable (CloudClientMessage) async throws -> Void {
        { [weak self] message in await self?.take(client, message) }
    }

    private func take(_ client: String, _ message: CloudClientMessage) {
        inbox.append((client, message))
    }

    func disconnect(_ client: String) {
        connected.remove(client)
        outboxes[client] = nil
        inbox.removeAll { $0.client == client }
    }

    /// Runs the hub and every session until nobody has anything left to say.
    func pump(_ sessions: [String: CloudSyncSession]) async throws {
        while !inbox.isEmpty || outboxes.values.contains(where: { !$0.isEmpty }) {
            while !inbox.isEmpty {
                let (client, message) = inbox.removeFirst()
                handle(client, message)
            }
            for client in outboxes.keys.sorted() {
                while let message = outboxes[client]?.first {
                    outboxes[client]?.removeFirst()
                    try await sessions[client]?.receive(message)
                }
            }
        }
    }

    private func to(_ client: String, _ message: CloudServerMessage) {
        outboxes[client, default: []].append(message)
    }

    private func handle(_ client: String, _ message: CloudClientMessage) {
        switch message {
        case .hello(_, let since, _):
            connected.insert(client)
            to(client, .welcome(seq: seq, docs: liveDocs, device: client))
            let items = rows.filter { $0.seq > since }.map {
                CloudChange(seq: $0.seq, kind: $0.kind, id: $0.id, bytes: $0.bytes, mode: $0.mode, from: $0.from)
            }
            if !items.isEmpty { to(client, .changes(items)) }
            to(client, .caughtUp(seq: seq))
        case .push(let ref, let kind, let id, let bytes, let mode, _):
            let tombstoned = rows.last { $0.kind == kind && $0.id == id }?.mode == .deleted
            if tombstoned, mode != .reset {
                to(client, .error(ref: ref, code: "deleted", message: "Deleted"))
                return
            }
            seq += 1
            if mode != .changes { rows.removeAll { $0.kind == kind && $0.id == id } }
            rows.append(Row(seq: seq, kind: kind, id: id, bytes: bytes, mode: mode, from: client))
            pushes.append((client, mode, bytes.count))
            to(client, .ack(ref: ref, seq: seq))
            for other in connected where other != client {
                to(other, .change(CloudChange(seq: seq, kind: kind, id: id, bytes: bytes, mode: mode, from: client)))
            }
        case .delete(let ref, let kind, let id):
            seq += 1
            rows.removeAll { $0.kind == kind && $0.id == id }
            rows.append(Row(seq: seq, kind: kind, id: id, bytes: Data(), mode: .deleted, from: client))
            to(client, .ack(ref: ref, seq: seq))
            for other in connected where other != client {
                to(other, .change(CloudChange(seq: seq, kind: kind, id: id, bytes: Data(), mode: .deleted, from: client)))
            }
        case .ping:
            to(client, .pong)
        }
    }
}

private func song(_ id: String, _ name: String, _ lyrics: [String]) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "",
        slides: lyrics.enumerated().map { index, text in
            Slide(id: "\(id)-s\(index)", name: "Verse", objects: [
                SlideObject(id: "\(id)-t\(index)", objectKind: .text, name: "Lyrics", text: text)])
        })
}

@LibraryActor private struct Mac {
    let name: String
    let root: URL
    let engine: LibraryEngine
    let session: CloudSyncSession

    init(_ name: String, hub: FakeHub) throws {
        self.name = name
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(name)-\(UUID().uuidString)")
        engine = LibraryEngine(rootURL: root)
        _ = try engine.bootstrap()
        session = CloudSyncSession(engine: engine, token: "t-\(name)", app: "test", send: hub.sender(for: name))
    }

    func song(_ id: String) throws -> Presentation? {
        guard try engine.cloudDocumentKeys().contains(SyncLedger.Key(kind: .presentation, id: id)) else { return nil }
        return try engine.replica(Presentation.self, id: id).value
    }

    /// An edit made here, told to the session the way the app's batch
    /// observer does.
    func edit(_ id: String, _ change: (inout Presentation) -> Void) async throws {
        try engine.modify(Presentation.self, id: id) { change(&$0) }
        try await session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: id)], deleted: [])
    }
}

@Suite struct CloudSyncSessionTests {
    @LibraryActor @Test func theFirstMacSeedsTheHubAndTheNextJoinsInsteadOfMerging() async throws {
        let hub = FakeHub()
        let studio = try Mac("studio", hub: hub)
        let laptop = try Mac("laptop", hub: hub)
        defer { [studio.root, laptop.root].forEach { try? FileManager.default.removeItem(at: $0) } }
        try studio.engine.create(song("amazing", "Amazing Grace", ["Amazing grace", "How sweet the sound"]))
        try laptop.engine.create(song("laptop-only", "Draft", ["Only here"]))
        let sessions = ["studio": studio.session, "laptop": laptop.session]

        try await studio.session.opened()
        try await hub.pump(sessions)
        #expect(studio.session.phase == .live)
        #expect(hub.liveDocs == 1)
        #expect(hub.pushes.map(\.mode) == [.reset])

        try await laptop.session.opened()
        try await hub.pump(sessions)
        #expect(laptop.session.phase == .needsJoin(documents: 1))
        #expect(try laptop.song("laptop-only") != nil, "nothing is touched before the person chooses")

        try laptop.session.join()
        hub.disconnect("laptop")
        try await laptop.session.opened()
        try await hub.pump(sessions)
        #expect(laptop.session.phase == .live)
        #expect(try laptop.song("laptop-only") == nil, "joining replaces, it doesn't merge")
        #expect(try laptop.song("amazing")?.name == "Amazing Grace")
        #expect(hub.liveDocs == 1, "the laptop sent nothing back")
    }

    @LibraryActor @Test func editsOnEachMacReachTheOtherAndConcurrentOnesMerge() async throws {
        let (hub, studio, laptop, sessions) = try await joinedPair()
        defer { [studio.root, laptop.root].forEach { try? FileManager.default.removeItem(at: $0) } }

        try await studio.edit("amazing") { $0.name = "Amazing Grace (My Chains)" }
        try await hub.pump(sessions)
        #expect(try laptop.song("amazing")?.name == "Amazing Grace (My Chains)")

        // Both edit before hearing from the other.
        try studio.engine.modify(Presentation.self, id: "amazing") { $0.slides[0].objects[0].text = "Amazing grace!" }
        try laptop.engine.modify(Presentation.self, id: "amazing") { $0.slides[1].objects[0].text = "How sweet the sound!" }
        try await studio.session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: "amazing")], deleted: [])
        try await laptop.session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: "amazing")], deleted: [])
        try await hub.pump(sessions)
        for mac in [studio, laptop] {
            let lines = try mac.song("amazing")?.slides.map { $0.objects[0].text }
            #expect(lines == ["Amazing grace!", "How sweet the sound!"], "\(mac.name)")
        }
    }

    @LibraryActor @Test func whatCameFromTheHubIsNotSentBack() async throws {
        let (hub, studio, laptop, sessions) = try await joinedPair()
        defer { [studio.root, laptop.root].forEach { try? FileManager.default.removeItem(at: $0) } }
        try await studio.edit("amazing") { $0.name = "One" }
        try await hub.pump(sessions)
        let before = hub.pushes.count
        // The laptop's own small edit goes as changes, without the studio's.
        try await laptop.edit("amazing") { $0.slides[0].name = "Chorus" }
        try await hub.pump(sessions)
        #expect(hub.pushes.count == before + 1)
        #expect(hub.pushes.last?.mode == .changes)
        // Nothing owed after a round trip either way.
        #expect(try studio.engine.cloudOwedKeys().isEmpty)
        #expect(try laptop.engine.cloudOwedKeys().isEmpty)
        #expect(try studio.song("amazing")?.slides[0].name == "Chorus")
    }

    @LibraryActor @Test func deletesAndWholesaleReplacementsReachTheOtherMac() async throws {
        let (hub, studio, laptop, sessions) = try await joinedPair()
        defer { [studio.root, laptop.root].forEach { try? FileManager.default.removeItem(at: $0) } }

        try studio.engine.replace(song("amazing", "Amazing Grace", ["Rewritten"]))
        try await studio.session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: "amazing")], deleted: [])
        try await hub.pump(sessions)
        #expect(hub.pushes.last?.mode == .reset)
        #expect(try laptop.song("amazing")?.slides.map { $0.objects[0].text } == ["Rewritten"])

        try studio.engine.delete(kind: .presentation, id: "amazing")
        try await studio.session.noteLocal(edited: [], deleted: [SyncLedger.Key(kind: .presentation, id: "amazing")])
        try await hub.pump(sessions)
        #expect(try laptop.song("amazing") == nil)
        #expect(hub.liveDocs == 0)

        // An edit on a document deleted elsewhere loses to the delete.
        try laptop.engine.create(song("amazing", "Back", ["Again"]))
        try await laptop.session.noteLocal(edited: [SyncLedger.Key(kind: .presentation, id: "amazing")], deleted: [])
        try await hub.pump(sessions)
        #expect(try studio.song("amazing")?.name == "Back", "made again, it's a new document")
    }

    @LibraryActor @Test func aMacThatWasOfflineCatchesUpAndSendsWhatItChanged() async throws {
        let (hub, studio, laptop, sessions) = try await joinedPair()
        defer { [studio.root, laptop.root].forEach { try? FileManager.default.removeItem(at: $0) } }
        laptop.session.closed()
        hub.disconnect("laptop")

        try await studio.edit("amazing") { $0.name = "From the studio" }
        try await hub.pump(sessions)
        // Edited while offline, and the app quit before it could say so.
        try laptop.engine.modify(Presentation.self, id: "amazing") { $0.slides[0].name = "Offline" }

        let reopened = CloudSyncSession(engine: laptop.engine, token: "t", app: "test", send: hub.sender(for: "laptop"))
        var both = sessions
        both["laptop"] = reopened
        try await reopened.opened()
        try await hub.pump(both)
        #expect(try laptop.song("amazing")?.name == "From the studio")
        #expect(try studio.song("amazing")?.slides[0].name == "Offline")
    }

    @LibraryActor @Test func aSnapshotIsSentWhenTheHubAsks() async throws {
        let (hub, studio, _, sessions) = try await joinedPair()
        try await studio.session.receive(.wantSnapshot(kind: .presentation, id: "amazing"))
        try await hub.pump(sessions)
        #expect(hub.pushes.last?.mode == .snapshot)
        #expect(hub.rows.filter { $0.id == "amazing" }.count == 1, "the hub kept only the snapshot")
    }

    @Test func messagesReadAndWriteTheContract() throws {
        let push = try CloudClientMessage.push(ref: 3, kind: .presentation, id: "p", bytes: Data([1, 2]), mode: .changes).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: push) as? [String: Any])
        #expect(object["t"] as? String == "push" && object["bytes"] as? String == "AQI=" && object["mode"] as? String == "changes")
        let change = CloudServerMessage.decode(Data(#"{"t":"change","seq":9,"kind":"service","id":"x","bytes":"AQI=","mode":"changes","from":"d1"}"#.utf8))
        #expect(change == .change(CloudChange(seq: 9, kind: .service, id: "x", bytes: Data([1, 2]), mode: .changes, from: "d1")))
        let deleted = CloudServerMessage.decode(Data(#"{"t":"deleted","seq":10,"kind":"service","id":"x"}"#.utf8))
        #expect(deleted == .change(CloudChange(seq: 10, kind: .service, id: "x", bytes: Data(), mode: .deleted)))
        let page = CloudServerMessage.decode(Data(#"{"t":"changes","items":[{"seq":1,"kind":"newKind","id":"a","bytes":"AQI=","mode":"changes"}]}"#.utf8))
        #expect(page == .changes([]), "a kind this version doesn't know is skipped")
    }
}

@LibraryActor private func joinedPair() async throws -> (FakeHub, Mac, Mac, [String: CloudSyncSession]) {
    let hub = FakeHub()
    let studio = try Mac("studio", hub: hub)
    let laptop = try Mac("laptop", hub: hub)
    try studio.engine.create(song("amazing", "Amazing Grace", ["Amazing grace", "How sweet the sound"]))
    let sessions = ["studio": studio.session, "laptop": laptop.session]
    try await studio.session.opened()
    try await hub.pump(sessions)
    try await laptop.session.opened()
    try await hub.pump(sessions)
    try laptop.session.join()
    hub.disconnect("laptop")
    try await laptop.session.opened()
    try await hub.pump(sessions)
    return (hub, studio, laptop, sessions)
}

@Suite struct CloudBlobPlanTests {
    @Test func fetchWhatIsMissingAndSendWhatTheHubLacks() {
        let a = CloudBlobRef(hash: String(repeating: "a", count: 64), ext: "JPG")
        let b = CloudBlobRef(hash: String(repeating: "b", count: 64), ext: "mp4")
        let c = CloudBlobRef(hash: String(repeating: "c", count: 64), ext: "png")
        let plan = CloudBlobPlan.plan(refs: [a, b, c], present: [a.hash, b.hash], uploaded: [b.hash])
        #expect(plan.download == [c])
        #expect(plan.upload == [a])
        #expect(a.ext == "jpg")
        #expect(CloudBlobRef(hash: "not-a-hash", fileName: "x.jpg") == nil)
        #expect(CloudBlobRef(hash: String(repeating: "d", count: 64), fileName: "Clip.MOV")?.ext == "mov")
    }
}
