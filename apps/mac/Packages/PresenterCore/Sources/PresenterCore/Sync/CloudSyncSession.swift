import Foundation

/// What this Mac remembers about the church library between launches, kept
/// beside the library (not synced).
public struct CloudSyncState: Codable, Equatable, Sendable {
    /// The newest hub sequence number applied here.
    public var since: Int = 0
    /// This Mac's library is the church library: it seeded the hub or
    /// replaced its own with the hub's.
    public var joined = false

    public init(since: Int = 0, joined: Bool = false) {
        self.since = since
        self.joined = joined
    }

    public static func url(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("cloud-sync.json")
    }

    public static func load(libraryRoot: URL) -> CloudSyncState {
        (try? Data(contentsOf: url(libraryRoot: libraryRoot)))
            .flatMap { try? JSONDecoder().decode(CloudSyncState.self, from: $0) } ?? CloudSyncState()
    }

    public func save(libraryRoot: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(libraryRoot: libraryRoot), options: .atomic)
    }
}

/// Documents deleted on this Mac whose delete the hub hasn't acknowledged,
/// kept beside the library (not synced). A delete leaves nothing behind for
/// `cloudOwedKeys()` to find, so without this list a delete made while the
/// socket was down, or still on its way when it closed, never reached the
/// other Macs. A file of its own, not part of CloudSyncState, because the
/// app adds to it while no session is open, and a session saving its state
/// would otherwise write over what was added.
@LibraryActor public enum CloudPendingDeletes {
    private struct Row: Codable, Hashable {
        var kind: String
        var id: String
    }

    public static func url(libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("cloud-deletes.json")
    }

    public static func load(libraryRoot: URL) -> Set<SyncLedger.Key> {
        guard let data = try? Data(contentsOf: url(libraryRoot: libraryRoot)),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return Set(rows.compactMap { row in
            DocumentKind(rawValue: row.kind).map { SyncLedger.Key(kind: $0, id: row.id) }
        })
    }

    public static func add(_ keys: [SyncLedger.Key], libraryRoot: URL) {
        let keys = keys.filter { LibraryEngine.syncsToCloud($0.kind) }
        guard !keys.isEmpty else { return }
        write(load(libraryRoot: libraryRoot).union(keys), libraryRoot: libraryRoot)
    }

    public static func remove(_ keys: [SyncLedger.Key], libraryRoot: URL) {
        let current = load(libraryRoot: libraryRoot)
        let left = current.subtracting(keys)
        guard left.count != current.count else { return }
        write(left, libraryRoot: libraryRoot)
    }

    public static func clear(libraryRoot: URL) {
        try? FileManager.default.removeItem(at: url(libraryRoot: libraryRoot))
    }

    private static func write(_ keys: Set<SyncLedger.Key>, libraryRoot: URL) {
        if keys.isEmpty { return clear(libraryRoot: libraryRoot) }
        let rows = keys.map { Row(kind: $0.kind.rawValue, id: $0.id) }
            .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
        try? JSONEncoder().encode(rows).write(to: url(libraryRoot: libraryRoot), options: .atomic)
    }
}

/// One connection's worth of sync with the hub (docs/cloud-sync.md), apart
/// from the socket: the transport hands it the hub's messages and sends what
/// it returns. It applies the hub's chunks to the library, keeps a list of
/// documents edited here, and pushes them once caught up, one push in flight
/// per document.
@LibraryActor public final class CloudSyncSession {
    public enum Phase: Equatable, Sendable {
        case connecting
        /// The hub has a library and this Mac hasn't joined it: the person
        /// chooses before anything is changed.
        case needsJoin(documents: Int)
        case catchingUp
        case live
    }

    /// What the app hears about, to show.
    public enum Event: Sendable, Equatable {
        case phase(Phase)
        case applied(Int)
        case pushed(Int)
        case blobArrived(String)
        case problem(String)
    }

    private let engine: LibraryEngine
    private let token: String
    private let app: String
    private let send: @Sendable (CloudClientMessage) async throws -> Void
    private let report: @Sendable (Event) -> Void

    public private(set) var state: CloudSyncState
    public private(set) var phase = Phase.connecting {
        didSet { if phase != oldValue { report(.phase(phase)) } }
    }

    private var edited: Set<SyncLedger.Key> = []
    private var deleted: Set<SyncLedger.Key> = []
    private var snapshotsWanted: Set<SyncLedger.Key> = []
    private enum InFlight {
        case push(CloudOutgoing)
        case delete(SyncLedger.Key)

        var key: SyncLedger.Key {
            switch self {
            case .push(let sent): sent.key
            case .delete(let key): key
            }
        }
    }
    private var inFlight: [Int: InFlight] = [:]
    private var nextRef = 1
    /// Pushes out at once; a seeding Mac has hundreds of documents to send
    /// and the rest go as acks come back.
    private let window = 24

    public init(
        engine: LibraryEngine, token: String, app: String,
        send: @escaping @Sendable (CloudClientMessage) async throws -> Void,
        report: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.engine = engine
        self.token = token
        self.app = app
        self.send = send
        self.report = report
        state = CloudSyncState.load(libraryRoot: engine.rootURL)
    }

    // MARK: The socket

    public func opened() async throws {
        phase = .connecting
        try await send(.hello(token: token, since: state.joined ? state.since : 0, app: app))
    }

    /// The socket closed: what was on its way is sent again next time.
    public func closed() {
        for flight in inFlight.values {
            switch flight {
            case .push(let sent): edited.insert(sent.key)
            case .delete(let key): deleted.insert(key)
            }
        }
        inFlight = [:]
        if case .needsJoin = phase { return }
        phase = .connecting
    }

    public func receive(_ message: CloudServerMessage) async throws {
        switch message {
        case .welcome(let seq, let docs, _):
            try await welcomed(seq: seq, docs: docs)
        case .changes(let items):
            guard state.joined else { return }
            for item in items { try apply(item) }
            try saveState()
        case .caughtUp(let seq):
            guard state.joined else { return }
            state.since = max(state.since, seq)
            try saveState()
            for key in try engine.cloudOwedKeys() { edited.insert(key) }
            // Deletes made while no socket was open, or lost when it closed.
            deleted.formUnion(CloudPendingDeletes.load(libraryRoot: engine.rootURL).subtracting(inFlight.values.map(\.key)))
            phase = .live
            try await flush()
        case .change(let item):
            guard state.joined else { return }
            try apply(item)
            try saveState()
        case .ack(let ref, let seq):
            guard let flight = inFlight.removeValue(forKey: ref) else { return }
            switch flight {
            case .push(let sent): try engine.cloudPushed(sent, seq: seq)
            case .delete(let key): CloudPendingDeletes.remove([key], libraryRoot: engine.rootURL)
            }
            report(.pushed(1))
            try await flush()
        case .error(let ref, let code, let message):
            let flight = ref.flatMap { inFlight.removeValue(forKey: $0) }
            // A refused delete isn't tried again, here or after a reconnect.
            if case .delete(let key) = flight { CloudPendingDeletes.remove([key], libraryRoot: engine.rootURL) }
            if code == "deleted", let key = flight?.key {
                // Deleted on another Mac while it was being edited here: the
                // delete wins, as it does on every other Mac.
                try engine.cloudApply(CloudChange(seq: 0, kind: key.kind, id: key.id, bytes: Data(), mode: .deleted))
            } else {
                report(.problem(message.isEmpty ? code : message))
            }
            try await flush()
        case .wantSnapshot(let kind, let id):
            let key = SyncLedger.Key(kind: kind, id: id)
            snapshotsWanted.insert(key)
            edited.insert(key)
            try await flush()
        case .blob(let sha):
            report(.blobArrived(sha))
        // The phone remote is the app's (CloudSync takes it before it gets here).
        case .pong, .unknown, .remote, .claude:
            break
        }
    }

    private func welcomed(seq: Int, docs: Int) async throws {
        if state.joined {
            phase = .catchingUp
        } else if docs == 0 {
            // An empty hub: this Mac's library becomes the church library.
            state = CloudSyncState(since: 0, joined: true)
            try engine.cloudForgetHub()
            try saveState()
            phase = .catchingUp
        } else {
            phase = .needsJoin(documents: docs)
        }
    }

    /// The person chose to join the church library: this Mac's shared
    /// documents go (the caller has made a backup) and the hub's come in on
    /// the next connection.
    public func join() throws {
        try engine.cloudClearSharedDocuments()
        edited = []
        deleted = []
        // What this Mac deleted from its own library isn't the church's.
        CloudPendingDeletes.clear(libraryRoot: engine.rootURL)
        state = CloudSyncState(since: 0, joined: true)
        try saveState()
        phase = .connecting
    }

    // MARK: Edits here

    /// A batch from the library: shared documents edited or deleted on this
    /// Mac. What came from the hub (`.landed`) isn't sent back.
    public func noteLocal(edited keys: [SyncLedger.Key], deleted gone: [SyncLedger.Key]) async throws {
        for key in keys where LibraryEngine.syncsToCloud(key.kind) {
            edited.insert(key)
            deleted.remove(key)
        }
        for key in gone where LibraryEngine.syncsToCloud(key.kind) {
            edited.remove(key)
            deleted.insert(key)
        }
        // Kept on disk until the hub acknowledges it, so a socket that closes
        // first, or a quit, doesn't lose it.
        CloudPendingDeletes.add(gone, libraryRoot: engine.rootURL)
        let remade = keys.filter { LibraryEngine.syncsToCloud($0.kind) }
        if !remade.isEmpty { CloudPendingDeletes.remove(remade, libraryRoot: engine.rootURL) }
        try await flush()
    }

    /// Sends what's waiting, once caught up, one request per document at a
    /// time; an edit made while a push is out goes after its ack.
    public func flush() async throws {
        guard phase == .live, state.joined else { return }
        let busy = Set(inFlight.values.map(\.key))
        for key in deleted.subtracting(busy).sorted(by: Self.order) where inFlight.count < window {
            // Sent even for a document the hub may never have had: deleting
            // clears its sync entry, so this Mac can't tell, and a tombstone
            // for nothing is harmless.
            deleted.remove(key)
            let ref = takeRef()
            inFlight[ref] = .delete(key)
            try await send(.delete(ref: ref, kind: key.kind, id: key.id))
        }
        for key in edited.subtracting(busy).sorted(by: Self.order) where inFlight.count < window {
            edited.remove(key)
            let snapshot = snapshotsWanted.remove(key) != nil
            guard let outgoing = try engine.cloudOutgoing(key, snapshot: snapshot) else { continue }
            let ref = takeRef()
            inFlight[ref] = .push(outgoing)
            try await send(.push(
                ref: ref, kind: key.kind, id: key.id, bytes: outgoing.bytes, mode: outgoing.mode,
                base: outgoing.mode == .changes ? nil : state.since))
        }
    }

    public var waiting: Int { edited.count + deleted.count + inFlight.count }

    // MARK: Helpers

    private func apply(_ item: CloudChange) throws {
        do {
            try engine.cloudApply(item)
        } catch {
            // One unreadable chunk doesn't stop the rest; it's kept for a look.
            _ = try? engine.quarantine(kind: item.kind, id: item.id, seq: item.seq, bytes: item.bytes, error: "\(error)")
            report(.problem("Couldn't apply a change to \(item.kind.rawValue) \(item.id)."))
        }
        state.since = max(state.since, item.seq)
        report(.applied(1))
    }

    private func saveState() throws {
        try state.save(libraryRoot: engine.rootURL)
    }

    private func takeRef() -> Int {
        defer { nextRef += 1 }
        return nextRef
    }

    private static func order(_ a: SyncLedger.Key, _ b: SyncLedger.Key) -> Bool {
        (a.kind.rawValue, a.id) < (b.kind.rawValue, b.id)
    }
}

/// The app reaches the library through the client, never the engine.
extension LibraryClient {
    /// A session for one connection to the hub.
    public func cloudSession(
        token: String, app: String,
        send: @escaping @Sendable (CloudClientMessage) async throws -> Void,
        report: @escaping @Sendable (CloudSyncSession.Event) -> Void
    ) async -> CloudSyncSession {
        await Task { @LibraryActor [engine] in
            CloudSyncSession(engine: engine, token: token, app: app, send: send, report: report)
        }.value
    }

    /// Unlinked: what the hub had is forgotten, so linking again starts fresh.
    public func forgetCloudHub() {
        Task { @LibraryActor [engine] in
            _ = try? engine.cloudForgetHub()
            CloudPendingDeletes.clear(libraryRoot: engine.rootURL)
        }
    }

    /// Shared documents deleted while no session is open: sent once one is
    /// caught up.
    public func noteCloudDeletesWhileOffline(_ keys: [SyncLedger.Key]) async {
        await Task { @LibraryActor [engine] in
            CloudPendingDeletes.add(keys, libraryRoot: engine.rootURL)
        }.value
    }
}
