import Foundation
import Testing
@testable import PresenterCore

/// A presentation exported from one library lands in another with its
/// theme and media, and nothing it doesn't use.
@MainActor
struct ShareBundleTests {
    private func client(at root: URL) async throws -> LibraryClient {
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        return client
    }

    @Test func presentationCarriesItsThemeAndMediaOnly() async throws {
        let temp = FileManager.default.temporaryDirectory
        let rootA = temp.appendingPathComponent(UUID().uuidString)
        let rootB = temp.appendingPathComponent(UUID().uuidString)
        let file = temp.appendingPathComponent("\(UUID().uuidString).\(ShareBundle.presentationExtension)")
        defer { for url in [rootA, rootB, file] { try? FileManager.default.removeItem(at: url) } }

        let source = try await client(at: rootA)
        let blobSource = temp.appendingPathComponent("\(UUID()).bin")
        try Data("background bytes".utf8).write(to: blobSource)
        let hash = try BlobStore(libraryRoot: rootA).store(fileURL: blobSource)
        try? FileManager.default.removeItem(at: blobSource)
        _ = try await source.create(MediaItem(
            id: "media-ocean", name: "Ocean", mediaKind: .image, classification: .background,
            fileHash: hash, fileName: "ocean.png", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false,
            inPoint: nil, outPoint: nil, durationSeconds: nil, pixelWidth: nil, pixelHeight: nil
        )).value
        _ = try await source.create(Theme(
            id: "theme-series", name: "Series", fontFamily: "Helvetica Neue",
            fontSize: 72, textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
            slides: [Slide(id: "design", name: "Bible", objects: [
                SlideObject(id: "art", objectKind: .shape, name: "Art", text: "",
                            fill: ObjectFill(fillKind: .media, mediaId: "media-ocean")),
            ])]
        )).value
        _ = try await source.create(Presentation(
            id: "deck-sermon", name: "Sermon", presentationKind: .deck, themeId: "theme-series",
            slides: [Slide(id: "sl1", name: "One", objects: [])]
        )).value
        _ = try await source.create(Presentation(
            id: "deck-other", name: "Other", presentationKind: .deck, themeId: "",
            slides: [Slide(id: "sl2", name: "Two", objects: [])]
        )).value

        let contents = try await ShareBundle.export(
            root: rootA, kind: .presentation, id: "deck-sermon", name: "Sermon",
            extraFiles: [ShareBundle.timersName: Data("[]".utf8)], to: file)
        #expect(contents.documents[.presentation] == ["deck-sermon"])
        #expect(contents.documents[.theme] == ["theme-series"])
        #expect(contents.documents[.media] == ["media-ocean"])

        let (folder, info) = try ShareBundle.unpack(file)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(info.id == "deck-sermon" && info.kind == "presentation")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ShareBundle.timersName).path))

        var options = BackupImportOptions()
        options.excluded = [.settings]
        let result = try await BackupBundle.restore(from: folder, into: try await client(at: rootB), options: options)
        #expect(result.mediaFilesCopied == 1)
        #expect(result.warnings.isEmpty)
        try await onLibraryActor(reading: rootB) { library throws in
            #expect(try library.index.entries(of: .presentation).map(\.id) == ["deck-sermon"])
            #expect(try library.index.entries(of: .theme).map(\.id) == ["theme-series"])
            let media = try library.open(MediaItem.self, id: "media-ocean").value
            #expect(try BlobStore(libraryRoot: rootB).url(forHash: media.fileHash) != nil)
        }
    }
}
