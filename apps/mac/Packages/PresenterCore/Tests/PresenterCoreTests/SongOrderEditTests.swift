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
}
