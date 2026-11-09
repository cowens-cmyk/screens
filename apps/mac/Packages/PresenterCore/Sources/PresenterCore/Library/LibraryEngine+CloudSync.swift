import Automerge
import Foundation

/// What one document sends the hub: its bytes, how the hub should take them,
/// and the heads they bring it to.
public struct CloudOutgoing: Sendable, Equatable {
    public var key: SyncLedger.Key
    public var bytes: Data
    public var mode: CloudSyncMode
    public var heads: [String]
    /// The heads the hub was known to have when these bytes were made.
    public var base: [String]
}

/// The library side of cloud sync (docs/cloud-sync.md). A document's sync
/// entry holds the heads the hub is known to have (`lastPushedHeads`, which
/// also gathers the heads of every chunk that came from the hub) and the
/// hub's sequence number for it (`remoteSeq`).
extension LibraryEngine {
    public static func syncsToCloud(_ kind: DocumentKind) -> Bool {
        SyncScope.scope(for: kind) == .team
    }

    /// Every document on this Mac that the church library shares.
    public func cloudDocumentKeys() throws -> [SyncLedger.Key] {
        let store = try opened().store
        return try DocumentKind.allCases.filter(Self.syncsToCloud).flatMap { kind in
            try store.ids(of: kind).map { SyncLedger.Key(kind: kind, id: $0) }
        }
    }

    /// Documents with something the hub doesn't have: never sent, or changed
    /// here since. Worked out from the heads recorded on every save, so it
    /// doesn't open every document.
    public func cloudOwedKeys() throws -> [SyncLedger.Key] {
        try cloudDocumentKeys().filter { key in
            guard let entry = sync.entries[key] else { return true }
            guard let heads = recordedHeads(kind: key.kind, id: key.id) else { return true }
            return !Set(heads).isSubset(of: Set(entry.lastPushedHeads))
        }
    }

    /// The bytes that bring the hub up to date with this document; nil when
    /// it has nothing new or is gone. A document the hub has never had, or
    /// whose history no longer holds what the hub had (it was replaced
    /// wholesale), goes as a full save that resets the hub's copy.
    public func cloudOutgoing(_ key: SyncLedger.Key, snapshot: Bool = false) throws -> CloudOutgoing? {
        guard try opened().store.exists(kind: key.kind, id: key.id) else { return nil }
        return try outgoing(SyncScope.entityType(for: key.kind), key: key, snapshot: snapshot)
    }

    private func outgoing<E: DocumentEntity>(_ type: E.Type, key: SyncLedger.Key, snapshot: Bool) throws -> CloudOutgoing? {
        let document = try replica(type, id: key.id)
        let heads = document.heads()
        let base = sync.entries[key]?.lastPushedHeads ?? []
        let known = SyncLedger.heads(base)
        let continues = !known.isEmpty && document.contains(heads: known)
        if snapshot || !continues {
            return CloudOutgoing(
                key: key, bytes: document.save(), mode: continues ? .snapshot : .reset,
                heads: SyncLedger.hex(heads), base: base)
        }
        guard !heads.isSubset(of: known) else { return nil }
        let bytes = try document.encodeChangesSince(heads: known)
        guard !bytes.isEmpty else { return nil }
        return CloudOutgoing(key: key, bytes: bytes, mode: .changes, heads: SyncLedger.hex(heads), base: base)
    }

    /// The hub stored a push. Heads that arrived from the hub while the push
    /// was on its way are kept, so they aren't sent back.
    @discardableResult
    public func cloudPushed(_ sent: CloudOutgoing, seq: Int) throws -> LibraryBatch {
        try updateSyncEntry(kind: sent.key.kind, id: sent.key.id) { entry in
            let arrivedMeanwhile = Set(entry.lastPushedHeads).subtracting(sent.base)
            entry.lastPushedHeads = Array(Set(sent.heads).union(arrivedMeanwhile)).sorted()
            entry.remoteSeq = max(entry.remoteSeq, seq)
            entry.pending = false
        }
    }

    /// A chunk from the hub. A reset (or a document this Mac doesn't have)
    /// replaces the local copy; anything else merges into it. Lands with the
    /// `.landed` origin, so the app shows it and doesn't send it back.
    @discardableResult
    public func cloudApply(_ change: CloudChange) throws -> LibraryBatch {
        let key = SyncLedger.Key(kind: change.kind, id: change.id)
        guard Self.syncsToCloud(change.kind) else { return try publishing {} }
        if change.mode == .deleted {
            return try publishing {
                if try opened().store.exists(kind: key.kind, id: key.id) {
                    try removeDocument(kind: key.kind, id: key.id, origin: .landed)
                }
                try forgetSyncEntry(key)
            }
        }
        return try publishing {
            try apply(SyncScope.entityType(for: key.kind), change: change, key: key)
        }
    }

    private func apply<E: DocumentEntity>(_ type: E.Type, change: CloudChange, key: SyncLedger.Key) throws {
        let store = try opened().store
        let listed = Library.listedKinds.contains(key.kind)
        var entry = sync.entries[key] ?? SyncLedger.Entry()
        if change.mode == .reset || !store.exists(kind: key.kind, id: key.id) {
            let document = try TypedDocument<E>(data: change.bytes)
            guard document.value.id == key.id else { throw CloudSyncError.mismatchedID(key.id) }
            if store.exists(kind: key.kind, id: key.id) {
                endEditorSessions(key)
                try dropFile(kind: key.kind, id: key.id)
            }
            try persist(document, origin: .landed, listed: listed)
            entry.lastPushedHeads = SyncLedger.hex(document.heads())
        } else {
            let document = try replica(type, id: key.id)
            let before = document.heads()
            if try document.applyEncodedChanges(change.bytes) {
                try persist(document, origin: .landed, listed: listed)
            }
            let arrived = document.heads().subtracting(before)
            entry.lastPushedHeads = Array(Set(entry.lastPushedHeads).union(SyncLedger.hex(arrived))).sorted()
        }
        entry.remoteSeq = max(entry.remoteSeq, change.seq)
        entry.appliedSeq = max(entry.appliedSeq, change.seq)
        try writeSyncEntry(entry, key: key)
    }

    /// Joining a church library that already has documents: this Mac's own
    /// shared documents go (a backup is made first, by the caller) so the
    /// two libraries aren't merged into duplicates.
    @discardableResult
    public func cloudClearSharedDocuments() throws -> LibraryBatch {
        let keys = try cloudDocumentKeys()
        return try publishing {
            for key in keys {
                try removeDocument(kind: key.kind, id: key.id, origin: .landed)
                try forgetSyncEntry(key)
            }
        }
    }

    /// Forgets what the hub had, as when this Mac is unlinked: the next
    /// library it joins starts from nothing.
    @discardableResult
    public func cloudForgetHub() throws -> LibraryBatch {
        try publishing {
            for key in Array(sync.entries.keys) where Self.syncsToCloud(key.kind) {
                try forgetSyncEntry(key)
            }
        }
    }
}

public enum CloudSyncError: Error, Equatable {
    case mismatchedID(String)
}
