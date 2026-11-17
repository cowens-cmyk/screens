import Foundation
import Testing
@testable import PresenterCore

@Suite struct ShareLookTests {
    private let background = PresentationTypeRule(
        category: "Worship", actions: [SlideAction(id: "bg", kind: .fireMedia, mediaId: "media-waves")])
    private let lowerThird = PresentationTypeScreens(category: "Worship", stream: "design", streamThemeId: "theme-lyrics-lt")

    @Test func readsThisLibrarysWorshipLook() {
        let settings = SlideBuildingSettings(
            id: "slide-building-settings", lyricsImportThemeId: "theme-hope-lyrics",
            presentationTypeRules: [background, PresentationTypeRule(category: "Sermon", actions: [])],
            typeScreens: [lowerThird])
        let look = ShareLook(settings)
        #expect(look.worshipRule == background && look.worshipScreens == lowerThird)
        #expect(look.lyricsImportThemeId == "theme-hope-lyrics")
        // The stage displays, and what the look names, are carried.
        #expect(look.referencedIDs.contains("screens.stage.worship"))
        #expect(look.referencedIDs.contains("media-waves") && look.referencedIDs.contains("theme-lyrics-lt"))
        #expect(ShareLook(nil).isEmpty)
    }

    @Test func fillsOnlyWhatTheOtherMacHasntChosen() throws {
        let look = ShareLook(lyricsImportThemeId: "theme-hope-lyrics", worshipScreens: lowerThird, worshipRule: background)
        // A new library: everything comes in.
        let fresh = SlideBuildingSettings(id: "s", lyricsImportThemeId: BasicTemplates.worshipThemeID)
        let filled = try #require(look.filling(fresh))
        #expect(filled.presentationTypeRules == [background] && filled.typeScreens == [lowerThird])
        #expect(filled.lyricsImportThemeId == "theme-hope-lyrics")
        // Its own choices stay.
        let own = SlideBuildingSettings(
            id: "s", lyricsImportThemeId: "theirs",
            presentationTypeRules: [PresentationTypeRule(category: "worship", actions: [])],
            typeScreens: [PresentationTypeScreens(category: "WORSHIP", stream: "clear")])
        #expect(look.filling(own) == nil)
    }
}

/// A file carries the stage displays, and the receiving library takes them
/// in place of its own.
@MainActor
struct ShareLookCarryTests {
    @Test func theStageDisplayTravelsAndReplacesTheOtherOne() async throws {
        let temp = FileManager.default.temporaryDirectory
        let rootA = temp.appendingPathComponent(UUID().uuidString)
        let rootB = temp.appendingPathComponent(UUID().uuidString)
        let file = temp.appendingPathComponent("\(UUID().uuidString).\(ShareBundle.presentationExtension)")
        defer { for url in [rootA, rootB, file] { try? FileManager.default.removeItem(at: url) } }

        let ours = LibraryClient(rootURL: rootA)
        try await ours.start().value
        _ = try await ours.create(Presentation(
            id: "deck-song", name: "Song", presentationKind: .song, themeId: "",
            slides: [Slide(id: "s1", name: "", objects: [])])).value
        _ = try await ours.create(ConfidenceLayout(
            id: BasicTemplates.worshipStageID, name: "Hope Lyrics + Chords",
            objects: [SlideObject(id: "big", objectKind: .text, name: "Lyrics", text: "")])).value

        let contents = try await ShareBundle.export(
            root: rootA, kind: .presentation, id: "deck-song", name: "Song",
            alsoIDs: ShareLook().referencedIDs, to: file)
        #expect(contents.documents[.confidenceLayout] == [BasicTemplates.worshipStageID])

        let theirs = LibraryClient(rootURL: rootB)
        try await theirs.start().value
        _ = try await theirs.create(ConfidenceLayout(
            id: BasicTemplates.worshipStageID, name: "Their Layout", objects: [])).value

        let (folder, _) = try ShareBundle.unpack(file)
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = BackupImportOptions()
        options.excluded = [.settings, .confidenceLayouts]
        _ = try await BackupBundle.restore(from: folder, into: theirs, options: options)
        var layouts = BackupImportOptions()
        layouts.policy = .replace
        layouts.excluded = Set(BackupSection.allCases).subtracting([.confidenceLayouts])
        _ = try await BackupBundle.restore(from: folder, into: theirs, options: layouts)

        try await onLibraryActor(reading: rootB) { library throws in
            let layout = try library.open(ConfidenceLayout.self, id: BasicTemplates.worshipStageID).value
            #expect(layout.name == "Hope Lyrics + Chords")
            #expect(layout.objects.map(\.id) == ["big"])
            #expect(try library.index.entries(of: .presentation).map(\.id) == ["deck-song"])
        }
    }
}
