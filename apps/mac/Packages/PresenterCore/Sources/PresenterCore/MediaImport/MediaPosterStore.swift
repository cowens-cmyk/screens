import CryptoKit
import Foundation
import os

public struct MediaPosterStore: Sendable {
    public let directory: URL

    private let misses = OSAllocatedUnfairLock(initialState: PosterMisses())

    public init(libraryRoot: URL) throws {
        directory = libraryRoot.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// How far into a video its thumbnail is taken when no frame has been
    /// chosen: the first frame of most church videos is black or a title
    /// card, and ten seconds in shows what the video actually is.
    public static let defaultPosterOffset = 10.0

    /// The moment of a video its thumbnail is taken from: the frame chosen
    /// for it (Media › Thumbnail), else ten seconds past its in point. A
    /// video shorter than that gives the frame halfway through what plays.
    public static func posterTime(of item: MediaItem) -> Double {
        if let chosen = item.posterSeconds { return max(chosen, 0) }
        let start = max(item.inPoint ?? 0, 0)
        let wanted = start + defaultPosterOffset
        guard let duration = item.durationSeconds, duration > 0 else { return wanted }
        let end = min(item.outPoint ?? duration, duration)
        guard wanted >= end else { return wanted }
        return end > start ? start + (end - start) / 2 : start
    }

    /// The fingerprint of an item's poster as it should be now: a new frame
    /// (a chosen one, or a new trim moving the default) makes a new poster.
    /// A picture's never changes.
    public static func fingerprint(of item: MediaItem) -> String {
        fingerprint(fileHash: item.fileHash, inPoint: item.mediaKind == .video ? posterTime(of: item) : nil)
    }

    public static func fingerprint(fileHash: String, inPoint: Double?) -> String {
        let key = "\(fileHash)|\(inPoint ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func posterURL(id: String, fingerprint: String) -> URL {
        directory.appendingPathComponent("\(id).\(fingerprint).jpg")
    }

    public func anyPosterURL(id: String) -> URL? {
        let (mayExist, writes) = misses.withLock { (!$0.ids.contains(id), $0.writes) }
        var found: URL?
        if mayExist {
            found = posterFiles().first { Self.posterID(of: $0) == id }
            if found == nil {

                misses.withLock { if $0.writes == writes { $0.ids.insert(id) } }
            }
        }
        return found
    }

    public func writePoster(_ jpegData: Data, id: String, fingerprint: String) throws {
        let destination = posterURL(id: id, fingerprint: fingerprint)
        for stale in posterFiles() where Self.posterID(of: stale) == id && stale != destination {
            try? FileManager.default.removeItem(at: stale)
        }
        try jpegData.write(to: destination, options: .atomic)
        misses.withLock {
            $0.ids.remove(id)
            $0.writes += 1
        }
    }

    public func writeTombstone(_ item: MediaItem) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        try? data.write(to: tombstoneURL(id: item.id), options: .atomic)
    }

    public func tombstone(id: String) -> MediaItem? {
        guard let data = try? Data(contentsOf: tombstoneURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(MediaItem.self, from: data)
    }

    public func allTombstones() -> [MediaItem] {
        allFiles()
            .filter { $0.lastPathComponent.hasSuffix(Self.tombstoneSuffix) }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(MediaItem.self, from: $0) }
            }
    }

    public func removeTombstone(id: String) {
        try? FileManager.default.removeItem(at: tombstoneURL(id: id))
    }

    @discardableResult
    public func sweep(existingMediaIds: Set<String>, referencedIds: Set<String>) -> Int {
        var removed = 0
        for file in allFiles() {
            let name = file.lastPathComponent
            let shouldRemove: Bool
            if name.hasSuffix(Self.tombstoneSuffix) {
                let id = String(name.dropLast(Self.tombstoneSuffix.count))
                shouldRemove = existingMediaIds.contains(id) || !referencedIds.contains(id)
            } else if name.hasSuffix(".jpg") {
                let id = Self.posterID(of: file)
                shouldRemove = !existingMediaIds.contains(id) && !referencedIds.contains(id)
            } else {
                continue
            }
            if shouldRemove {
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
        }
        return removed
    }

    struct PosterMisses: Sendable {
        var ids: Set<String> = []
        var writes = 0
    }

    private static let tombstoneSuffix = ".tombstone.json"

    private func tombstoneURL(id: String) -> URL {
        directory.appendingPathComponent("\(id)\(Self.tombstoneSuffix)")
    }

    private func allFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
    }

    private func posterFiles() -> [URL] {
        allFiles().filter { $0.pathExtension == "jpg" }
    }

    private static func posterID(of url: URL) -> String {
        url.deletingPathExtension().deletingPathExtension().lastPathComponent
    }
}
