import AppKit
import Foundation
import Observation
import PresenterCore

/// The church library: this Mac's shared documents kept in step with every
/// other Mac through the hub in the CMS (docs/cloud-sync.md). The socket and
/// the reconnecting live here; CloudSyncSession does the syncing.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Status: Equatable {
        case notLinked
        case connecting
        case needsJoin(documents: Int)
        case joining
        case catchingUp
        case live
        case offline(String)
        case unlinked
    }

    private(set) var status = Status.notLinked
    private(set) var deviceName: String?
    private(set) var problem: String?
    private(set) var lastActivity: Date?
    private(set) var isLinking = false
    private(set) var files = CloudBlobTransfer.Progress()

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var session: CloudSyncSession?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observer: LibraryBatchObservers.Token?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var transfer: CloudBlobTransfer?
    @ObservationIgnored private var retrier: Task<Void, Never>?

    private static let keychainService = "org.hopejc.screens.cloud"
    /// A copy of the app on a test library (SCREENS_LIBRARY_ROOT) is linked
    /// as a Mac of its own, so its key and name are kept apart.
    private static let testScope: String = ProcessInfo.processInfo.environment["SCREENS_LIBRARY_ROOT"]
        .map { "-" + String($0.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36) } ?? ""
    private static let keychainAccount = "device-token" + testScope
    private static let deviceNameKey = "cloud.deviceName" + testScope
    /// For testing against a hub run locally; unset in use.
    private static let hostKey = "cloud.host"

    static var host: URL {
        UserDefaults.standard.string(forKey: hostKey).flatMap(URL.init(string:))
            ?? URL(string: "https://media.hopejc.org")!
    }

    /// The socket goes to the Worker's own address: media.hopejc.org is
    /// proxied, and the proxy doesn't carry WebSockets (as for Transmit).
    static var socketHost: URL {
        UserDefaults.standard.string(forKey: hostKey).flatMap(URL.init(string:))
            ?? URL(string: "https://hope-media.cowens-09f.workers.dev")!
    }

    private init() {}

    private var token: String? {
        SecretStore.load(service: Self.keychainService, account: Self.keychainAccount, localOnly: true)
    }

    var isLinked: Bool { token != nil }

    // MARK: Starting

    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        deviceName = UserDefaults.standard.string(forKey: Self.deviceNameKey)
        observer = model.batchObservers.add { batch in
            let media = batch.changes.filter { [.media, .audio].contains($0.kind) && $0.value != nil }.map(\.key)
            if !media.isEmpty {
                Task { @MainActor in await CloudSync.shared.moveFiles(for: media) }
            }
            let route = SyncBatchRoute(batch)
            guard !route.edited.isEmpty || !route.deleted.isEmpty else { return }
            Task { @MainActor in
                guard let session = CloudSync.shared.session else {
                    // Edits are found again on reconnect (cloudOwedKeys);
                    // a delete leaves nothing to find, so it's written down.
                    if CloudSync.shared.isLinked, !route.deleted.isEmpty {
                        await CloudSync.shared.model?.client.noteCloudDeletesWhileOffline(route.deleted)
                    }
                    return
                }
                await Self.note(session, edited: route.edited, deleted: route.deleted)
            }
        }
        model.whenLibraryReady { [weak self] in self?.connect() }
    }

    @LibraryActor private static func note(_ session: CloudSyncSession, edited: [SyncLedger.Key], deleted: [SyncLedger.Key]) async {
        try? await session.noteLocal(edited: edited, deleted: deleted)
    }

    // MARK: Linking

    /// Trades a code from the CMS (Screens › Link a Mac) for this Mac's own
    /// key, kept in the Keychain on this Mac only.
    func link(code: String, name: String) async {
        isLinking = true
        problem = nil
        defer { isLinking = false }
        DiagnosticsStore.shared.note("cloud.link", detail: "to \(Self.host.absoluteString)")
        do {
            var request = URLRequest(url: Self.host.appendingPathComponent("api/screens/link"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                // Shown grouped in the CMS ("3Y8N JK2U"); typed either way.
                "code": code.uppercased().filter { $0.isLetter || $0.isNumber }, "name": name,
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, let token = object?["token"] as? String else {
                problem = (object?["error"] as? String) ?? "That code didn't work. Make a new one in the CMS."
                return
            }
            SecretStore.save(token, service: Self.keychainService, account: Self.keychainAccount, localOnly: true)
            // A transfer left from an earlier link would still send the old key.
            retrier?.cancel()
            retrier = nil
            transfer = nil
            UserDefaults.standard.set(name, forKey: Self.deviceNameKey)
            deviceName = name
            connect()
        } catch {
            DiagnosticsStore.shared.note("cloud.link.failed", detail: "\(error)")
            problem = "Couldn't reach the CMS: \(error.localizedDescription)"
        }
    }

    /// Stops syncing here. The library stays as it is; linking again joins
    /// the church library afresh.
    func unlink() {
        disconnect()
        transfer = nil
        SecretStore.save("", service: Self.keychainService, account: Self.keychainAccount, localOnly: true)
        UserDefaults.standard.removeObject(forKey: Self.deviceNameKey)
        deviceName = nil
        if let model {
            let root = model.client.rootURL
            try? FileManager.default.removeItem(at: CloudSyncState.url(libraryRoot: root))
            model.client.forgetCloudHub()
        }
        status = .notLinked
    }

    /// The hub already has the church library: this Mac's own shared
    /// documents are copied aside and replaced by it.
    func joinChurchLibrary() async {
        guard let model, let session else { return }
        status = .joining
        do {
            try Self.backUp(libraryRoot: model.client.rootURL)
            try await Self.join(session)
            reconnect(after: 0)
        } catch {
            problem = "Couldn't join: \(error.localizedDescription)"
            status = .offline("Couldn't join")
        }
    }

    @LibraryActor private static func join(_ session: CloudSyncSession) throws {
        try session.join()
    }

    /// The documents (not the media files, which joining leaves alone) as
    /// they were, in Application Support/Screens/Backups.
    nonisolated static func backUp(libraryRoot: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = libraryRoot.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Before joining \(stamp)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        where !["blobs", "thumbnails"].contains(item.lastPathComponent) {
            try manager.copyItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
        }
    }

    // MARK: Media files

    /// Once caught up: every file the library refers to that this Mac lacks
    /// is fetched, and every one it has that the hub lacks is sent.
    private func startFiles() {
        guard let model, let blobs = model.blobs, let token else { return }
        if transfer == nil {
            let client = model.client
            transfer = CloudBlobTransfer(
                base: Self.socketHost, token: token, blobs: blobs,
                uploaded: { hash in _ = try? await client.markBlobUploaded(hash).value },
                landed: { _ in
                    await MainActor.run {
                        CloudSync.shared.model?.noteBlobsChanged()
                        // A file added in the browser is read for what it couldn't say.
                        CloudSync.shared.model?.fillMediaDetails()
                    }
                },
                progress: { progress in Task { @MainActor in CloudSync.shared.files = progress } })
        }
        Task { await moveFiles(for: nil) }
        retrier?.cancel()
        retrier = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if let transfer = self?.transfer { await transfer.retryMissing() }
            }
        }
    }

    /// The files of these media and audio items (all of them when nil).
    fileprivate func moveFiles(for keys: [SyncLedger.Key]?) async {
        guard let model, let blobs = model.blobs, let transfer, status == .live else { return }
        let keys = keys ?? (model.entries(of: .media).map { SyncLedger.Key(kind: .media, id: $0.id) }
            + model.entries(of: .audio).map { SyncLedger.Key(kind: .audio, id: $0.id) })
        let refs = Set(keys.compactMap { key -> CloudBlobRef? in
            switch key.kind {
            case .media: model.media(key.id).flatMap { CloudBlobRef(hash: $0.fileHash, fileName: $0.fileName) }
            case .audio: model.audio(key.id).flatMap { CloudBlobRef(hash: $0.fileHash, fileName: $0.fileName) }
            default: nil
            }
        })
        guard !refs.isEmpty else { return }
        let hashes = refs.map(\.hash)
        let present = blobs.presence(forHashes: hashes)
        let uploaded = (try? await model.client.uploadedBlobs(among: hashes)) ?? []
        let plan = CloudBlobPlan.plan(refs: refs, present: present, uploaded: uploaded)
        await transfer.want(plan.download)
        await transfer.offer(plan.upload)
        // Media added in the browser whose file this Mac already has.
        model.fillMediaDetails()
    }

    // MARK: The socket

    /// A message of the app's own (the phone remote's) on the open socket;
    /// false when there isn't one.
    func send(_ message: CloudClientMessage) async -> Bool {
        guard status == .live, let socket, let data = try? message.encoded() else { return false }
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            return true
        } catch {
            return false
        }
    }

    private func connect() {
        guard loop == nil, let model, let token else {
            if token == nil { status = .notLinked }
            return
        }
        let client = model.client
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // A warning from an earlier connection (a chunk that couldn't be
        // applied, a push the hub refused) doesn't stay once sync starts
        // over; one from this connection shows until the next.
        problem = nil
        status = .connecting
        loop = Task { [weak self] in
            await self?.run(client: client, token: token, version: version)
        }
    }

    private func disconnect() {
        loop?.cancel()
        loop = nil
        retrier?.cancel()
        retrier = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if let session {
            Task { @LibraryActor in session.closed() }
        }
        session = nil
    }

    private func reconnect(after seconds: Double) {
        disconnect()
        Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            self?.connect()
        }
    }

    private func run(client: LibraryClient, token: String, version: String) async {
        var url = URLComponents(url: Self.socketHost.appendingPathComponent("api/screens/sync"), resolvingAgainstBaseURL: false)!
        url.scheme = url.scheme == "http" ? "ws" : "wss"
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.maximumMessageSize = 64 << 20
        self.socket = socket
        let session = await Self.makeSession(client: client, token: token, version: version, socket: socket)
        self.session = session
        socket.resume()
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                try? await socket.send(.string(String(decoding: try CloudClientMessage.ping.encoded(), as: UTF8.self)))
            }
        }
        defer { pinger.cancel() }
        do {
            try await Self.opened(session)
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                let decoded = CloudServerMessage.decode(data)
                if case .remote(let request) = decoded {
                    // The phone remote's tap: done here, not in the library.
                    Task { await PhoneRemoteController.shared.handle(request) }
                } else if case .claude(let id, let body, let user) = decoded {
                    // Claude's request: answered by this Mac's MCP tools.
                    Task { await ClaudeRelay.shared.handle(id: id, body: body, user: user) }
                } else {
                    try await Self.deliver(decoded, to: session)
                }
                lastActivity = Date()
                failures = 0
            }
        } catch {
            guard !Task.isCancelled else { return }
            await Self.closed(session)
            loop = nil
            self.session = nil
            if socket.closeCode.rawValue == 4401 {
                // Unlinked in the CMS: the key no longer works. The media
                // transfer holds that key, so it goes too; linking again
                // makes a new one with the new key.
                SecretStore.save("", service: Self.keychainService, account: Self.keychainAccount, localOnly: true)
                retrier?.cancel()
                retrier = nil
                transfer = nil
                status = .unlinked
                return
            }
            if case .needsJoin = status { return }
            failures += 1
            status = .offline(error.localizedDescription)
            let wait = [2.0, 5, 10, 30, 60][min(failures - 1, 4)]
            reconnect(after: wait)
        }
    }

    private static func makeSession(
        client: LibraryClient, token: String, version: String, socket: URLSessionWebSocketTask
    ) async -> CloudSyncSession {
        await client.cloudSession(
            token: token, app: version,
            send: { message in
                try await socket.send(.string(String(decoding: try message.encoded(), as: UTF8.self)))
            },
            report: { event in
                Task { @MainActor in CloudSync.shared.heard(event) }
            })
    }

    @LibraryActor private static func opened(_ session: CloudSyncSession) async throws {
        try await session.opened()
    }

    @LibraryActor private static func deliver(_ message: CloudServerMessage, to session: CloudSyncSession) async throws {
        try await session.receive(message)
    }

    @LibraryActor private static func closed(_ session: CloudSyncSession) {
        session.closed()
    }

    private func heard(_ event: CloudSyncSession.Event) {
        switch event {
        case .phase(.connecting): status = .connecting
        case .phase(.catchingUp): status = .catchingUp
        case .phase(.live):
            status = .live
            startFiles()
            PhoneRemoteController.shared.connected()
            ClaudeRelay.shared.connected()
        case .phase(.needsJoin(let documents)):
            status = .needsJoin(documents: documents)
            // Nothing more until the person chooses.
            loop?.cancel()
            loop = nil
            socket?.cancel(with: .normalClosure, reason: nil)
        case .applied, .pushed:
            lastActivity = Date()
        case .blobArrived(let sha):
            if let transfer { Task { await transfer.arrived(sha) } }
        case .problem(let text):
            problem = text
        }
    }
}
