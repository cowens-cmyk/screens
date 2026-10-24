import Foundation

/// The rules for what dropped art or a Claude Design download may be, kept
/// apart from the file system so they can be tested. Anything dropped here
/// can end up read by Claude, so what's taken is kept narrow, and a
/// download is held to a size that suits a background, a lower third and
/// a JSON file.
public enum DesignDownload {
    /// More than a download needs, few enough that reading them is quick.
    public static let maxFiles = 60
    /// Folders inside folders, counted from the download's top.
    public static let maxDepth = 4
    public static let maxBytes: Int64 = 200 * 1024 * 1024

    public enum LimitError: LocalizedError, Equatable {
        case tooManyFiles
        case tooDeep
        case tooLarge
        case unreadableZip

        public var errorDescription: String? {
            switch self {
            case .tooManyFiles: "That download has more than \(DesignDownload.maxFiles) files."
            case .tooDeep: "That download has folders more than \(DesignDownload.maxDepth) deep."
            case .tooLarge: "That download is over \(DesignDownload.maxBytes / 1024 / 1024) MB."
            case .unreadableZip: "That ZIP couldn't be opened."
            }
        }
    }

    /// Pictures, as opposed to PDFs or vector files.
    public static let rasterExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]

    /// What the plan list takes: one picture or one ZIP. A plan is dropped
    /// on for many reasons (songs, notes, media), so a PDF, a folder, JSON
    /// or several files are left alone rather than sent off to be read.
    public static func acceptsOnPlan(_ fileNames: [String]) -> Bool {
        guard fileNames.count == 1, let name = fileNames.first else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return rasterExtensions.contains(ext) || ext == "zip"
    }

    public static func isPDF(_ fileName: String) -> Bool {
        (fileName as NSString).pathExtension.lowercased() == "pdf"
    }

    /// Whether `path` is `root` or inside it. Both are expected resolved
    /// (symlinks followed, standardized), so `..` or a link can't step out.
    public static func isInside(_ path: String, root: String) -> Bool {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == base || path.hasPrefix(base + "/")
    }

    /// Folders between `root` and the file at `path`: 0 for a file at the
    /// top. Nil when the path isn't inside the root.
    public static func depth(of path: String, under root: String) -> Int? {
        guard isInside(path, root: root) else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        let rest = path.dropFirst(base.count).split(separator: "/")
        return max(0, rest.count - 1)
    }

    /// The uncompressed total from `unzip -l`'s last line
    /// ("  12345                     3 files"), before anything is unpacked.
    public static func listedSize(_ listing: String) -> Int64? {
        let lines = listing.split(whereSeparator: \.isNewline)
        guard let last = lines.last(where: { $0.contains("file") }),
              let first = last.split(separator: " ").first
        else { return nil }
        return Int64(first)
    }

    /// Checks a ZIP's entry names (`unzip -Z1`, one per line) before it's
    /// unpacked: none may be absolute or climb out with "..", and the files
    /// (entries not ending in "/") must be within the count.
    public static func checkEntries(_ listing: String) throws {
        let names = listing.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.hasPrefix("/") || name.hasPrefix("\\") || parts.contains("..") || name.contains("\\..") {
                throw LimitError.unreadableZip
            }
        }
        let files = names.filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }
        guard files.count <= maxFiles else { throw LimitError.tooManyFiles }
    }

    /// Files counted so far against the limits; `add` throws as soon as
    /// one is crossed, so a huge download stops being walked early.
    public struct Tally: Sendable {
        public private(set) var files = 0
        public private(set) var bytes: Int64 = 0

        public init() {}

        public mutating func add(bytes size: Int64, depth: Int) throws {
            guard depth <= DesignDownload.maxDepth else { throw LimitError.tooDeep }
            files += 1
            bytes += max(0, size)
            guard files <= DesignDownload.maxFiles else { throw LimitError.tooManyFiles }
            guard bytes <= DesignDownload.maxBytes else { throw LimitError.tooLarge }
        }
    }
}
