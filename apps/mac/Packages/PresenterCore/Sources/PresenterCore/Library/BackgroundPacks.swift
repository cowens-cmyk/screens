import Foundation
import UniformTypeIdentifiers

/// Packs in Worship Backgrounds: a set of related backgrounds (a "Blossom"
/// pack of ten motion loops) kept together. A pack is a folder inside the
/// Worship Backgrounds folder, nothing more, so every other Mac and the
/// browser editor already see it as the folder it is, a background in a pack
/// is still a worship background (it loops, it's offered as a background),
/// and moving one in or out of a pack is an ordinary refile.
///
/// The media bin shows packs one level deep. A folder made by hand deeper
/// inside a pack ("Christmas/2024") belongs to the pack it sits under.
public enum BackgroundPacks {
    /// The folder packs live in.
    public static var categoryFolder: String { MediaLibraryCategory.worshipBackgrounds.folder ?? "Worship Backgrounds" }

    /// A pack and the backgrounds in it, in the order they were given.
    public struct Pack: Equatable, Sendable, Identifiable {
        public var name: String
        public var memberIDs: [String]

        public var id: String { BackgroundPacks.key(name) }

        public init(name: String, memberIDs: [String]) {
            self.name = name
            self.memberIDs = memberIDs
        }
    }

    public struct Grouped: Equatable, Sendable {
        /// By name, as Finder sorts them ("Pack 2" before "Pack 10").
        public var packs: [Pack]
        /// Backgrounds in no pack, in the order they were given.
        public var loose: [String]

        /// The pack of this name, matched without regard to case.
        public func pack(named name: String) -> Pack? {
            packs.first { $0.id == BackgroundPacks.key(name) }
        }
    }

    /// The pack a media folder path is in: the folder right under Worship
    /// Backgrounds. Nil at the top of Worship Backgrounds and outside it.
    public static func pack(ofFolder path: String?) -> String? {
        guard let path, MediaLibraryCategory.containing(folder: path) == .worshipBackgrounds else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// Splits worship backgrounds into packs and the ones in no pack. Pack
    /// names match without regard to case, as Finder's do, so a pack made
    /// "Blossom" on one Mac and "blossom" by hand on another is one pack,
    /// shown by the name most of its backgrounds carry.
    public static func group<Item>(
        _ items: [Item], id: (Item) -> String, folder: (Item) -> String?
    ) -> Grouped {
        var order: [String] = []
        var members: [String: [String]] = [:]
        var spellings: [String: [String: Int]] = [:]
        var loose: [String] = []
        for item in items {
            guard let name = pack(ofFolder: folder(item)) else {
                loose.append(id(item))
                continue
            }
            let key = key(name)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(id(item))
            spellings[key, default: [:]][name, default: 0] += 1
        }
        let packs = order.map { key -> Pack in
            let counts = spellings[key] ?? [:]
            let name = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? key
            return Pack(name: name, memberIDs: members[key] ?? [])
        }
        return Grouped(
            packs: packs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            loose: loose)
    }

    /// Where a background goes when it's put in a pack, or taken out of one
    /// (nil): the pack's folder, or the top of Worship Backgrounds.
    public static func folder(forPack name: String?) -> String {
        guard let name, let clean = cleanName(name) else { return categoryFolder }
        return categoryFolder + "/" + clean
    }

    /// A background's folder once its pack is renamed: the pack's part of
    /// the path changes and any folder made inside the pack stays.
    public static func renamed(folder path: String?, to name: String) -> String {
        let parts = (path ?? "").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return ([folder(forPack: name)] + parts.dropFirst(2)).joined(separator: "/")
    }

    /// A name a pack can have: trimmed, and with no slash, since a slash
    /// would make a folder inside the pack. Finder writes a slash typed in a
    /// folder's name as a colon on disk, so both become a dash. Nil when
    /// nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The pack a dropped Finder folder fills: named after the folder, or
    /// the pack already of that name, so dropping the same folder again
    /// adds to it rather than making a second one.
    public static func packName(forFolderNamed raw: String, existing: [String]) -> String? {
        guard let clean = cleanName(raw) else { return nil }
        return existing.first { key($0) == key(clean) } ?? clean
    }

    static func key(_ name: String) -> String {
        name.lowercased()
    }
}

/// Which files a Finder folder dropped on Worship Backgrounds brings in.
/// Read off the main thread: a folder can be large or on a slow drive.
public enum BackgroundPackImport {
    /// A folder to make a pack from. A package (a Keynote deck, a Photos
    /// library) looks like a folder to the file system but is a single
    /// document to the person dragging it, so it isn't one.
    public static func isPackFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Splits a drop into folders that become packs and everything else,
    /// which is imported the way it always has been.
    public static func split(_ urls: [URL]) -> (folders: [URL], files: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            if isPackFolder(url) { folders.append(url) } else { files.append(url) }
        }
        return (folders, files)
    }

    /// A picture or a video: the two things a background can be. Music,
    /// PDFs, project files and the rest stay behind.
    public static func isBackgroundFile(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."),
              let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// What a drop on a pack brings in: the pictures and videos dropped, and
    /// those in any folder dropped, in the order given.
    public static func files(in urls: [URL]) -> [URL] {
        urls.flatMap { url in
            isPackFolder(url) ? files(inFolder: url) : isBackgroundFile(url) ? [url] : []
        }
    }

    /// Every picture and video in the folder and the folders inside it,
    /// leaving out hidden files, the insides of packages and the
    /// "__MACOSX" folder a zip from a Windows or web download leaves
    /// behind. In the order Finder lists them by name.
    public static func files(inFolder root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        let base = root.standardizedFileURL.path
        var found: [(relative: String, url: URL)] = []
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == "__MACOSX" { walk.skipDescendants() }
                continue
            }
            guard isBackgroundFile(url) else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            found.append((relative, url))
        }
        return found
            .sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
            .map(\.url)
    }
}
