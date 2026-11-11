import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PresenterCore

private struct Item {
    var id: String
    var folder: String?
}

@Test func aPackIsTheFolderRightUnderWorshipBackgrounds() {
    #expect(BackgroundPacks.pack(ofFolder: "Worship Backgrounds/Blossom") == "Blossom")
    #expect(BackgroundPacks.pack(ofFolder: "Worship Backgrounds/Christmas/2024") == "Christmas", "deeper folders belong to the pack")
    #expect(BackgroundPacks.pack(ofFolder: "worship backgrounds/Blossom") == "Blossom", "a category folder made by hand")
    #expect(BackgroundPacks.pack(ofFolder: "Worship Backgrounds") == nil, "the top of the category")
    #expect(BackgroundPacks.pack(ofFolder: "Videos/Blossom") == nil, "only Worship Backgrounds has packs")
    #expect(BackgroundPacks.pack(ofFolder: "Countdowns/2026") == nil)
    #expect(BackgroundPacks.pack(ofFolder: nil) == nil)
    #expect(BackgroundPacks.pack(ofFolder: "") == nil)
    #expect(BackgroundPacks.pack(ofFolder: "Backgrounds/Worship Backgrounds/Blossom") == nil, "only the top folder is the category")
}

@Test func backgroundsGroupIntoPacksAndTheRestStayAtTheTop() {
    let items = [
        Item(id: "a", folder: "Worship Backgrounds"),
        Item(id: "b", folder: "Worship Backgrounds/Blossom"),
        Item(id: "c", folder: "Worship Backgrounds/Pack 10"),
        Item(id: "d", folder: "Worship Backgrounds/Blossom"),
        Item(id: "e", folder: "Worship Backgrounds/Pack 2"),
        Item(id: "f", folder: "Worship Backgrounds/Pack 2/Extras"),
        Item(id: "g", folder: nil),
    ]
    let grouped = BackgroundPacks.group(items, id: \.id, folder: \.folder)
    #expect(grouped.packs.map(\.name) == ["Blossom", "Pack 2", "Pack 10"], "sorted as Finder sorts")
    #expect(grouped.packs.map(\.memberIDs) == [["b", "d"], ["e", "f"], ["c"]], "members keep the order given")
    #expect(grouped.loose == ["a", "g"])
    #expect(grouped.pack(named: "blossom")?.memberIDs == ["b", "d"], "found without regard to case")
    #expect(grouped.pack(named: "Ocean") == nil)
}

@Test func packNamesMatchWithoutRegardToCase() {
    let items = [
        Item(id: "a", folder: "Worship Backgrounds/blossom"),
        Item(id: "b", folder: "Worship Backgrounds/Blossom"),
        Item(id: "c", folder: "worship backgrounds/Blossom"),
    ]
    let grouped = BackgroundPacks.group(items, id: \.id, folder: \.folder)
    #expect(grouped.packs.count == 1)
    #expect(grouped.packs.first?.name == "Blossom", "the spelling most of its backgrounds carry")
    #expect(grouped.packs.first?.memberIDs == ["a", "b", "c"])
}

@Test func movingInAndOutOfAPackIsAFolder() {
    #expect(BackgroundPacks.folder(forPack: "Blossom") == "Worship Backgrounds/Blossom")
    #expect(BackgroundPacks.folder(forPack: nil) == "Worship Backgrounds", "out of a pack is the top of the category")
    #expect(BackgroundPacks.folder(forPack: "  ") == "Worship Backgrounds")
    #expect(MediaLibraryCategory.containing(folder: BackgroundPacks.folder(forPack: "Blossom")) == .worshipBackgrounds,
            "a background in a pack is still a worship background")
}

@Test func renamingAPackKeepsFoldersMadeInsideIt() {
    #expect(BackgroundPacks.renamed(folder: "Worship Backgrounds/Blossom", to: "Spring") == "Worship Backgrounds/Spring")
    #expect(BackgroundPacks.renamed(folder: "worship backgrounds/Christmas/2024", to: "Advent") == "Worship Backgrounds/Advent/2024")
}

@Test func packNamesComeFromTheFolder() {
    #expect(BackgroundPacks.cleanName("  Blossom ") == "Blossom")
    #expect(BackgroundPacks.cleanName("Easter/Spring") == "Easter-Spring", "a slash would make a folder inside the pack")
    #expect(BackgroundPacks.cleanName("Easter:Spring") == "Easter-Spring", "Finder's slash, as it's stored on disk")
    #expect(BackgroundPacks.cleanName("   ") == nil)
    #expect(BackgroundPacks.packName(forFolderNamed: "Blossom", existing: []) == "Blossom")
    #expect(BackgroundPacks.packName(forFolderNamed: "blossom", existing: ["Ocean", "Blossom"]) == "Blossom",
            "dropping the folder again fills the pack it made")
    #expect(BackgroundPacks.packName(forFolderNamed: "", existing: ["Blossom"]) == nil)
}

@Test func backgroundFilesArePicturesAndVideos() {
    for name in ["a.mov", "a.mp4", "a.m4v", "a.jpg", "a.png", "a.heic"] {
        #expect(BackgroundPackImport.isBackgroundFile(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
    }
    for name in ["a.mp3", "a.wav", "a.pdf", "a.key", "a.txt", "a", ".hidden.mov", "._a.mov"] {
        #expect(!BackgroundPackImport.isBackgroundFile(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
    }
}

@Suite(.serialized)
struct BackgroundPackFolderTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func aFolderBringsInItsPicturesAndVideosAllTheWayDown() throws {
        let root = try makeDir().appendingPathComponent("Blossom")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for path in [
            "Blossom 10.mov", "Blossom 2.mov", "Blossom 1.jpg",
            "4K/Blossom Wide.mp4",
            "Read Me.pdf", "Theme.mp3", "Project.prproj",
            ".DS_Store", ".hidden.mov", "._Blossom 2.mov",
            ".cache/clip.mov",
            "__MACOSX/Blossom 2.mov",
            "Slides.key/Data/image.jpg",
        ] {
            try touch(root.appendingPathComponent(path))
        }
        let names = BackgroundPackImport.files(inFolder: root).map {
            String($0.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        }
        #expect(names == ["4K/Blossom Wide.mp4", "Blossom 1.jpg", "Blossom 2.mov", "Blossom 10.mov"])
    }

    @Test func aDropSplitsIntoPacksAndFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Ocean")
        let file = dir.appendingPathComponent("Loose.mov")
        let deck = dir.appendingPathComponent("Deck.key")
        try touch(folder.appendingPathComponent("Wave.mov"))
        try touch(file)
        try touch(deck.appendingPathComponent("Index.zip"))
        let split = BackgroundPackImport.split([folder, file, deck])
        #expect(split.folders.map(\.lastPathComponent) == ["Ocean"])
        #expect(split.files.map(\.lastPathComponent) == ["Loose.mov", "Deck.key"], "a Keynote package isn't a pack")
        #expect(BackgroundPackImport.files(in: [file, folder, dir.appendingPathComponent("Theme.mp3")])
            .map(\.lastPathComponent) == ["Loose.mov", "Wave.mov"], "what's dropped on a pack, folders opened")
    }

    private func writePNG(to url: URL, size: Int) throws {
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @MainActor @Test func droppingTheSameFolderAgainAddsOnlyWhatsNew() async throws {
        let dir = try makeDir()
        let libraryRoot = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        let folder = dir.appendingPathComponent("Blossom")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writePNG(to: folder.appendingPathComponent("One.png"), size: 40)
        try writePNG(to: folder.appendingPathComponent("Two.png"), size: 48)
        try writePNG(to: folder.appendingPathComponent("Two copy.png"), size: 48)

        let client = LibraryClient(rootURL: libraryRoot)
        try await client.start().value
        let importer = try MediaImporter(client: client)
        let placement = LibraryHome.Placement.drive(viewing: LibraryHome.Viewed(
            kind: .media, area: .team, path: BackgroundPacks.folder(forPack: "Blossom")))

        let first = await importer.importFiles(
            at: BackgroundPackImport.files(inFolder: folder), placement: placement, skippingHashes: [])
        #expect(first.filter { $0.outcome == .duplicate }.count == 1, "a copy inside the folder comes in once")

        try writePNG(to: folder.appendingPathComponent("Three.png"), size: 56)
        let items = try await onLibraryActor(reading: libraryRoot) { library in
            try library.index.entries(of: .media).map { try library.open(MediaItem.self, id: $0.id).value }
        }
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.folder == "Worship Backgrounds/Blossom" })

        let second = await importer.importFiles(
            at: BackgroundPackImport.files(inFolder: folder), placement: placement,
            skippingHashes: Set(items.map(\.fileHash)))
        #expect(second.filter { $0.outcome == .duplicate }.count == 3)
        let added = second.compactMap { result -> String? in
            if case .media = result.outcome { return result.fileURL.lastPathComponent }
            return nil
        }
        #expect(added == ["Three.png"])

        let plain = await importer.importFiles(at: [folder.appendingPathComponent("One.png")], placement: placement)
        #expect(plain.allSatisfy { $0.outcome != .duplicate }, "other imports don't skip anything")
    }
}

/// The media bin's side of packs: folders dropped on Worship Backgrounds
/// become packs, the folder is read off the main thread, and nothing that
/// changes a pack is open to a run-only volunteer.
@Test func theMediaBinMakesPacksFromFoldersAndLocksThemInRunOnly() throws {
    let sweep = try SourceSweep.app()
    let bin = try #require(sweep.file("MediaLibraryView.swift")).text
    #expect(bin.contains("case .category(.worshipBackgrounds):\n            if let pack {\n                await model.importIntoPack(urls, pack: pack)"))
    #expect(bin.contains("let split = BackgroundPackImport.split(urls)"))
    #expect(bin.contains("await model.importBackgroundPacks(split.folders)"))
    #expect(bin.contains("enabled: !runOnly && picking == nil,"), "a pack's tile takes drops only from someone who can change it")
    #expect(bin.contains("if !runOnly {\n            Divider()\n            Button(\"Rename Pack…\")"))
    #expect(bin.contains("packMenu(for: entry, packs: packs)"), "the packs are listed once per pass, not per tile")
    let model = try #require(sweep.file("BackgroundPacksModel.swift")).text
    #expect(model.contains("await Task.detached(priority: .userInitiated) {\n            BackgroundPackImport.files(in: urls)"))
    #expect(model.contains("skippingHashes: hashes"))
}
