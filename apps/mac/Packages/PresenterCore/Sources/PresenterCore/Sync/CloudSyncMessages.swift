import Foundation

/// The messages Screens and the church's sync hub trade over the socket.
/// docs/cloud-sync.md is the contract; the hub is ScreensHub in the CMS.
public enum CloudSyncMode: String, Codable, Sendable, Equatable {
    /// Changes since the heads the hub already had.
    case changes
    /// A full save of the same history, so the hub can drop older chunks.
    case snapshot
    /// A full save of a new history that replaces the document.
    case reset
    /// The document was deleted (only in catch-up pages).
    case deleted
}

public enum CloudClientMessage: Equatable, Sendable {
    case hello(token: String, since: Int, app: String)
    /// `base` is the last hub sequence applied here when the bytes were made;
    /// the hub keeps other Macs' chunks after it when a snapshot compacts.
    case push(ref: Int, kind: DocumentKind, id: String, bytes: Data, mode: CloudSyncMode, base: Int? = nil)
    case delete(ref: Int, kind: DocumentKind, id: String)
    case ping
    /// The answer to a phone remote's tap (PhoneRemote).
    case remoteDone(id: String, ok: Bool, message: String?)
    /// What's live, for the phone remote: a JSON object the hub keeps as it is.
    case live(state: Data)
    /// Whether this Mac takes Claude's requests (the CMS's /screens/mcp).
    case claudeReady(on: Bool)
    /// This Mac's JSON-RPC reply to one of Claude's requests, as text.
    case claudeDone(id: String, body: String)

    public func encoded() throws -> Data {
        var object: [String: Any]
        switch self {
        case .hello(let token, let since, let app):
            object = ["t": "hello", "token": token, "since": since, "app": app]
        case .push(let ref, let kind, let id, let bytes, let mode, let base):
            object = ["t": "push", "ref": ref, "kind": kind.rawValue, "id": id,
                      "bytes": bytes.base64EncodedString(), "mode": mode.rawValue]
            if let base { object["base"] = base }
        case .delete(let ref, let kind, let id):
            object = ["t": "delete", "ref": ref, "kind": kind.rawValue, "id": id]
        case .ping:
            object = ["t": "ping"]
        case .remoteDone(let id, let ok, let message):
            object = ["t": "remote-done", "id": id, "ok": ok]
            if let message, !ok { object["message"] = message }
        case .live(let state):
            object = ["t": "live", "state": (try? JSONSerialization.jsonObject(with: state)) ?? [String: Any]()]
        case .claudeReady(let on):
            object = ["t": "claude-ready", "on": on]
        case .claudeDone(let id, let body):
            object = ["t": "claude-done", "id": id, "body": body]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// One document's chunk from the hub: live, or in a catch-up page.
public struct CloudChange: Equatable, Sendable {
    public var seq: Int
    public var kind: DocumentKind
    public var id: String
    public var bytes: Data
    public var mode: CloudSyncMode
    public var from: String?

    public init(seq: Int, kind: DocumentKind, id: String, bytes: Data, mode: CloudSyncMode, from: String? = nil) {
        self.seq = seq
        self.kind = kind
        self.id = id
        self.bytes = bytes
        self.mode = mode
        self.from = from
    }
}

public enum CloudServerMessage: Equatable, Sendable {
    case welcome(seq: Int, docs: Int, device: String?)
    case changes([CloudChange])
    case caughtUp(seq: Int)
    case change(CloudChange)
    case ack(ref: Int, seq: Int)
    case error(ref: Int?, code: String, message: String)
    case wantSnapshot(kind: DocumentKind, id: String)
    /// A media file reached the hub's storage.
    case blob(sha: String)
    /// A tap on the phone remote.
    case remote(PhoneRemote.Request)
    /// One of Claude's MCP requests, passed on by the CMS: the JSON-RPC
    /// message as it came, and the account that sent it.
    case claude(id: String, body: Data, user: String?)
    case pong
    /// A kind this version doesn't know, or a message it can't read: skipped.
    case unknown(String)

    public static func decode(_ data: Data) -> CloudServerMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String
        else { return .unknown("unreadable") }
        switch type {
        case "welcome":
            return .welcome(seq: int(object["seq"]), docs: int(object["docs"]), device: object["device"] as? String)
        case "changes":
            let items = (object["items"] as? [[String: Any]]) ?? []
            return .changes(items.compactMap(change))
        case "caught-up":
            return .caughtUp(seq: int(object["seq"]))
        case "change":
            return change(object).map(CloudServerMessage.change) ?? .unknown(type)
        case "deleted":
            var deleted = object
            deleted["mode"] = CloudSyncMode.deleted.rawValue
            return change(deleted).map(CloudServerMessage.change) ?? .unknown(type)
        case "ack":
            return .ack(ref: int(object["ref"]), seq: int(object["seq"]))
        case "error":
            return .error(ref: object["ref"].map(int), code: object["code"] as? String ?? "",
                          message: object["message"] as? String ?? "")
        case "want-snapshot":
            guard let kind = (object["kind"] as? String).flatMap(DocumentKind.init(rawValue:)),
                  let id = object["id"] as? String
            else { return .unknown(type) }
            return .wantSnapshot(kind: kind, id: id)
        case "blob":
            guard let sha = object["sha"] as? String else { return .unknown(type) }
            return .blob(sha: sha.lowercased())
        case "pong":
            return .pong
        case "remote":
            return PhoneRemote.request(object).map(CloudServerMessage.remote) ?? .unknown(type)
        case "claude":
            guard let id = object["id"] as? String, let body = object["body"] as? String else { return .unknown(type) }
            return .claude(id: id, body: Data(body.utf8), user: object["user"] as? String)
        default:
            return .unknown(type)
        }
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// A chunk for a kind this version doesn't have is dropped rather than
    /// failing the page; a newer Screens on another Mac may sync more.
    private static func change(_ object: [String: Any]) -> CloudChange? {
        guard let kind = (object["kind"] as? String).flatMap(DocumentKind.init(rawValue:)),
              let id = object["id"] as? String,
              let mode = (object["mode"] as? String).flatMap(CloudSyncMode.init(rawValue:))
        else { return nil }
        let bytes = (object["bytes"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        guard mode == .deleted || !bytes.isEmpty else { return nil }
        return CloudChange(seq: int(object["seq"]), kind: kind, id: id, bytes: bytes, mode: mode, from: object["from"] as? String)
    }
}
