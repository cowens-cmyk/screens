import Foundation

/// Where this Mac keeps its media files (pictures, videos, audio): in the
/// library on this Mac (as always), or in a folder on an external drive such
/// as an SSD, chosen in Settings › Media & Video › Media Storage. Kept per
/// Mac, never synced: each Mac decides for itself.
///
/// Every BlobStore asks here for its folder, so the importer, playback,
/// transcoding, previews and cloud downloads all follow one choice. The
/// choice takes effect at launch (changing it moves the files and
/// relaunches).
///
/// With the drive unplugged, nothing is written anywhere else: the files
/// show as missing, imports and downloads fail until it's back, and no
/// folder is made in its place (an unplugged drive's path is an ordinary
/// folder under /Volumes on the internal disk, which must stay empty).
public enum MediaStorage {
    /// The folder inside the chosen one that holds the files, as in the
    /// library.
    public static let filesFolderName = "blobs"

    static let bookmarkKey = "media.storage.bookmark"
    static let pathKey = "media.storage.path"

    public enum Location: Equatable, Sendable {
        case thisMac
        /// The chosen folder (its "blobs" folder holds the files).
        case external(URL)
    }

    /// This Mac's choice. A test library (SCREENS_LIBRARY_ROOT) always keeps
    /// its own files, so a test run never touches the church's drive.
    public static func location(defaults: UserDefaults = .standard) -> Location {
        guard ProcessInfo.processInfo.environment["SCREENS_LIBRARY_ROOT"] == nil else { return .thisMac }
        guard let folder = chosenFolder(defaults: defaults) else { return .thisMac }
        return .external(folder)
    }

    /// The chosen folder: from its bookmark, so a renamed drive or one that
    /// mounts as "Screens SSD 1" is still found; else the path it had.
    static func chosenFolder(defaults: UserDefaults) -> URL? {
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let path = defaults.string(forKey: pathKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Saves the choice: a folder on a drive, or nil for this Mac.
    public static func choose(_ folder: URL?, defaults: UserDefaults = .standard) {
        guard let folder else {
            defaults.removeObject(forKey: bookmarkKey)
            defaults.removeObject(forKey: pathKey)
            return
        }
        defaults.set(folder.path, forKey: pathKey)
        if let data = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
        }
    }

    /// The files folder for a library, and whether it's there to use.
    public struct Resolved: Equatable, Sendable {
        public var directory: URL
        public var isExternal: Bool
        /// The chosen folder (for an external drive), else the library.
        public var root: URL
    }

    public static func resolve(libraryRoot: URL, location: Location) -> Resolved {
        switch location {
        case .thisMac:
            return Resolved(
                directory: libraryRoot.appendingPathComponent(filesFolderName, isDirectory: true),
                isExternal: false, root: libraryRoot)
        case .external(let folder):
            return Resolved(
                directory: folder.appendingPathComponent(filesFolderName, isDirectory: true),
                isExternal: true, root: folder)
        }
    }

    /// The media files folder for a library on this Mac's choice, for code
    /// that copies the folder whole (backups, restores, shared bundles).
    /// Throws while the drive is unplugged rather than give a path that
    /// would read as empty or write onto the internal disk.
    public static func filesDirectory(libraryRoot: URL) throws -> URL {
        let resolved = resolve(libraryRoot: libraryRoot, location: location())
        if resolved.isExternal, !isReachable(resolved.directory) {
            throw DriveNotConnected(folder: resolved.root.path)
        }
        return resolved.directory
    }

    /// Whether the chosen folder is there now: the drive is plugged in and
    /// the folder hasn't been deleted or renamed.
    public static func isReachable(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public struct DriveNotConnected: LocalizedError, Sendable {
        public var folder: String
        public var errorDescription: String? {
            "The media drive isn't connected (\(folder)). Plug it in and try again."
        }
    }

    // MARK: Moving the files

    /// What a move would copy: each file in `from` that `to` doesn't already
    /// have at the same size, and the bytes that adds up to.
    public static func plan(from source: URL, to destination: URL) -> (files: [URL], bytes: Int64) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let files = (try? manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var todo: [URL] = []
        var bytes: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]), Int64(existing.fileSize ?? -1) == size {
                continue
            }
            todo.append(file)
            bytes += size
        }
        return (todo.sorted { $0.lastPathComponent < $1.lastPathComponent }, bytes)
    }

    /// Copies one file and checks it: a media file is named by its SHA-256,
    /// so the copy must hash to its own name. A copy that doesn't is
    /// removed and the move stops.
    public static func copyVerified(_ file: URL, into destination: URL) throws {
        let manager = FileManager.default
        let target = destination.appendingPathComponent(file.lastPathComponent)
        let partial = destination.appendingPathComponent("." + file.lastPathComponent + ".partial")
        try? manager.removeItem(at: partial)
        try manager.copyItem(at: file, to: partial)
        let expected = file.deletingPathExtension().lastPathComponent.lowercased()
        if isContentHash(expected) {
            let actual = try BlobStore.sha256(of: partial)
            guard actual == expected else {
                try? manager.removeItem(at: partial)
                throw CopyMismatch(name: file.lastPathComponent)
            }
        }
        try? manager.removeItem(at: target)
        try manager.moveItem(at: partial, to: target)
    }

    public struct CopyMismatch: LocalizedError, Sendable {
        public var name: String
        public var errorDescription: String? { "\(name) didn't copy correctly. Nothing was changed." }
    }

    /// The bytes the files in a folder take up.
    public static func totalBytes(in folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.reduce(0) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Every file in `source` is in `destination` at the same size: safe to
    /// remove the source's copies.
    public static func isCompleteCopy(from source: URL, to destination: URL) -> Bool {
        plan(from: source, to: destination).files.isEmpty
    }

    static func isContentHash(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { $0.isHexDigit }
    }
}
