import Foundation
import Testing
@testable import PresenterCore

struct SongOrderEditTests {
    private let order = ["v1", "c", "v2", "c", "b"]

    @Test func insertingASectionLandsWhereItWasDropped() {
        #expect(SongOrderEdit.inserting("t", before: 2, in: order) == ["v1", "c", "t", "v2", "c", "b"])
        #expect(SongOrderEdit.inserting("t", before: nil, in: order).last == "t")
        #expect(SongOrderEdit.inserting("t", before: 99, in: order).last == "t")
        #expect(SongOrderEdit.inserting("t", before: 0, in: []) == ["t"])
    }

    @Test func movingABlockForwardAndBack() {
        #expect(SongOrderEdit.moving(from: 4, before: 0, in: order) == ["b", "v1", "c", "v2", "c"])
        #expect(SongOrderEdit.moving(from: 0, before: 3, in: order) == ["c", "v2", "v1", "c", "b"])
        #expect(SongOrderEdit.moving(from: 0, before: nil, in: order) == ["c", "v2", "c", "b", "v1"])
        #expect(SongOrderEdit.moving(from: 1, before: 2, in: order) == order, "dropped on itself")
        #expect(SongOrderEdit.moving(from: 9, before: 0, in: order) == order)
    }

    @Test func removingOneBlockOnly() {
        #expect(SongOrderEdit.removing(at: 1, in: order) == ["v1", "v2", "c", "b"])
        #expect(SongOrderEdit.removing(at: 9, in: order) == order)
    }

    @Test func payloadsRoundTrip() {
        #expect(SongOrderEdit.payload(SongOrderEdit.sectionPayload("abc")) == .section("abc"))
        #expect(SongOrderEdit.payload(SongOrderEdit.blockPayload(3)) == .block(3))
        #expect(SongOrderEdit.payload("arrblock::x::1") == nil)
    }

    @Test func baseOrderIsTheRunsOfSections() {
        var song = Presentation(id: "s", name: "S", presentationKind: .song, themeId: "", slides: [])
        song.sections = [PresentationSection(id: "v", name: "Verse 1"), PresentationSection(id: "c", name: "Chorus")]
        song.slides = ["v", "v", "c", "c", "v"].enumerated().map { index, section in
            var slide = Slide(id: "\(index)", name: "", objects: [])
            slide.sectionId = section
            return slide
        }
        #expect(SongOrderEdit.baseOrder(of: song) == ["v", "c", "v"])
    }

    @Test func duplicatingABlockSingsItAgainRightAfter() {
        #expect(SongOrderEdit.duplicating(at: 1, in: order) == ["v1", "c", "c", "v2", "c", "b"])
        #expect(SongOrderEdit.duplicating(at: 9, in: order) == order)
    }

    @Test func aDuplicateArrangementIsACopyOfItsOwn() throws {
        let sections = [PresentationSection(id: "v1", name: "Verse 1"), PresentationSection(id: "c", name: "Chorus")]
        let slides = [
            Slide(id: "a", name: "", objects: [], sectionId: "v1"),
            Slide(id: "b", name: "", objects: [], sectionId: "c"),
        ]
        var shepherds = Arrangement(id: "shepherd-a1", name: "Default (Shepherd)", sectionIds: ["v1", "c", "c"])
        shepherds.shepherdArrangementId = "a1"
        var song = Presentation(
            id: "s", name: "Song", presentationKind: .song, themeId: "", slides: slides,
            sections: sections, arrangements: [shepherds])
        let copy = try #require(SongOrderEdit.duplicate(shepherds, of: song, id: "x"))
        #expect(copy.id == "x" && copy.name == "Default Copy" && copy.sectionIds == ["v1", "c", "c"])
        #expect(copy.shepherdArrangementId == nil, "sync never rewrites a copy")

        song.arrangements = [shepherds, copy]
        #expect(SongOrderEdit.duplicate(shepherds, of: song)?.name == "Default Copy 2")
        // No arrangement: the slide order.
        #expect(SongOrderEdit.duplicate(nil, of: song)?.sectionIds == ["v1", "c"])
    }
}
