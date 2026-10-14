import CoreText
import Foundation

/// One presentation or theme packed with everything it needs on another
/// Mac: the documents it points at (themes, media, stage layouts, macros,
/// messages…), the media files, the fonts that don't ship with macOS, and
/// the timers its actions start. Inside it's a library backup holding only
/// those pieces, zipped into one file, so import reuses the backup restore.
public enum ShareBundle {
    public static let presentationExtension = "screenspres"
    public static let themeExtension = "screenstheme"
    static let shareName = "share.json"
    public static let timersName = "timers.json"

    public struct Info: Codable, Equatable, Sendable {
        public var kind: String
        public var id: String
        public var name: String
    }

    public enum ShareError: LocalizedError {
        case missing(String), unzip
        public var errorDescription: String? {
            switch self {
            case .missing(let name): "“\(name)” couldn't be found in the library."
            case .unzip: "That file couldn't be opened. It may be damaged."
            }
        }
    }

    /// Kinds that come along when something points at them. Services,
    /// boards, per-Mac settings, stream destinations (keys) and hardware
    /// stay behind.
    static let carriedKinds: Set<DocumentKind> = [
        .presentation, .theme, .media, .audio, .overlay, .alertPreset,
        .actionCombo, .confidenceLayout, .note, .font,
    ]

    public struct Contents: Sendable {
        public var documents: [DocumentKind: Set<String>] = [:]
        public var fileHashes: Set<String> = []
        public var fontNames: Set<String> = []
        public var strings: Set<String> = []
        public var count: Int { documents.values.reduce(0) { $0 + $1.count } }
    }

    /// Everything reachable from the root document: any carried document
    /// whose id appears anywhere inside a document already collected.
    @LibraryActor
    public static func collect(root: URL, kind: DocumentKind, id: String) throws -> Contents {
        var contents = Contents()
        var queue = [(kind, id)]
        var seen = Set<String>()
        while let (kind, id) = queue.popLast() {
            guard seen.insert(id).inserted else { continue }
            let file = documentURL(root: root, kind: kind, id: id)
            guard let data = try? Data(contentsOf: file) else {
                if seen.count == 1 { throw ShareError.missing(id) }
                continue
            }
            contents.documents[kind, default: []].insert(id)
            let json = try encodedValue(SyncScope.entityType(for: kind), data: data)
            var strings: [String] = []
            walk(try JSONSerialization.jsonObject(with: json), key: nil, strings: &strings, contents: &contents)
            contents.strings.formUnion(strings)
            for candidate in Set(strings) where candidate.count >= 8 && !seen.contains(candidate) {
                for other in carriedKinds
                where FileManager.default.fileExists(atPath: documentURL(root: root, kind: other, id: candidate).path) {
                    queue.append((other, candidate))
                }
            }
        }
        return contents
    }

    /// Writes the share file. `extraFiles` go in as-is (timers.json).
    public static func export(
        root: URL, kind: DocumentKind, id: String, name: String,
        extraFiles: [String: Data] = [:], to destination: URL
    ) async throws -> Contents {
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let contents = try await collect(root: root, kind: kind, id: id)
            let staging = files.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: staging) }

            var counts: [String: Int] = [:]
            for (docKind, ids) in contents.documents {
                let folder = staging.appendingPathComponent(docKind.directoryName, isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                for docID in ids {
                    try files.copyItem(at: documentURL(root: root, kind: docKind, id: docID),
                                       to: folder.appendingPathComponent("\(docID).automerge"))
                }
                counts[docKind.rawValue] = ids.count
            }

            // Media files and posters are named by their hash.
            var blobCount = 0
            for folderName in [BackupBundle.blobsName, BackupBundle.postersName] {
                let source = root.appendingPathComponent(folderName, isDirectory: true)
                let target = staging.appendingPathComponent(folderName, isDirectory: true)
                let names = (try? files.contentsOfDirectory(atPath: source.path)) ?? []
                for file in names where contents.fileHashes.contains(where: { file.hasPrefix($0) }) {
                    try files.createDirectory(at: target, withIntermediateDirectories: true)
                    try files.copyItem(at: source.appendingPathComponent(file), to: target.appendingPathComponent(file))
                    if folderName == BackupBundle.blobsName { blobCount += 1 }
                }
            }

            // Fonts that aren't part of macOS travel with it.
            let fontFiles = fontURLs(for: contents.fontNames)
            if !fontFiles.isEmpty {
                let target = staging.appendingPathComponent(BackupBundle.fontsName, isDirectory: true)
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                for url in fontFiles {
                    let destinationURL = target.appendingPathComponent(url.lastPathComponent)
                    if !files.fileExists(atPath: destinationURL.path) {
                        try files.copyItem(at: url, to: destinationURL)
                    }
                }
            }

            for (fileName, data) in extraFiles {
                try data.write(to: staging.appendingPathComponent(fileName))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Info(kind: kind.rawValue, id: id, name: name))
                .write(to: staging.appendingPathComponent(shareName))
            encoder.dateEncodingStrategy = .iso8601
            var manifest = BackupBundle.Manifest(
                formatVersion: BackupBundle.formatVersion, createdAt: Date(),
                documentCounts: counts, blobCount: blobCount)
            manifest.fontCount = fontFiles.count
            manifest.modernVocabulary = true
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(BackupBundle.manifestName))

            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try ditto(["-c", "-k", "--sequesterRsrc", staging.path, destination.path])
            return contents
        }.value
    }

    /// Unzips a share file into a temporary folder laid out like a backup.
    public static func unpack(_ file: URL) throws -> (folder: URL, info: Info) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-import-\(UUID().uuidString)", isDirectory: true)
        do { try ditto(["-x", "-k", file.path, folder.path]) } catch { throw ShareError.unzip }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(shareName)),
              let info = try? JSONDecoder().decode(Info.self, from: data)
        else { throw ShareError.unzip }
        return (folder, info)
    }

    static func documentURL(root: URL, kind: DocumentKind, id: String) -> URL {
        root.appendingPathComponent(kind.directoryName, isDirectory: true)
            .appendingPathComponent("\(id).automerge")
    }

    @LibraryActor
    private static func encodedValue<E: DocumentEntity>(_ type: E.Type, data: Data) throws -> Data {
        try JSONEncoder().encode(TypedDocument<E>(data: data).value)
    }

    private static func walk(_ node: Any, key: String?, strings: inout [String], contents: inout Contents) {
        switch node {
        case let dictionary as [String: Any]:
            for (childKey, child) in dictionary { walk(child, key: childKey, strings: &strings, contents: &contents) }
        case let array as [Any]:
            for child in array { walk(child, key: key, strings: &strings, contents: &contents) }
        case let string as String where !string.isEmpty:
            strings.append(string)
            switch key {
            case "fileHash": contents.fileHashes.insert(string)
            case "fontName", "fontFamily": contents.fontNames.insert(string)
            default: break
            }
        default: break
        }
    }

    /// The files behind fonts by PostScript or family name, leaving out the
    /// ones in /System (every Mac has them).
    public static func fontURLs(for names: Set<String>) -> [URL] {
        var urls = Set<URL>()
        for name in names {
            var descriptors: [CTFontDescriptor] = []
            for attribute in [kCTFontNameAttribute, kCTFontFamilyNameAttribute] {
                let query = CTFontDescriptorCreateWithAttributes([attribute: name] as CFDictionary)
                let matches = CTFontDescriptorCreateMatchingFontDescriptors(query, NSSet(object: attribute) as CFSet) as? [CTFontDescriptor] ?? []
                if !matches.isEmpty { descriptors = matches; break }
            }
            for descriptor in descriptors {
                if let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL,
                   !url.path.hasPrefix("/System/") {
                    urls.insert(url.standardizedFileURL)
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ShareError.unzip }
    }
}
