import Testing

@testable import PresenterCore

/// set_song_sequence for one plan item must leave every other plan item's
/// order alone, the song's default order above all.
@Suite struct SongSequenceOrderTests {
    private func song(_ orders: [Arrangement], default defaultID: String?) -> Presentation {
        Presentation(
            id: "song", name: "Song", presentationKind: .song, themeId: "", slides: [],
            arrangements: orders, defaultArrangementId: defaultID)
    }

    @Test func aPlanItemNeverRewritesTheDefaultOrderByName() {
        let deck = song([Arrangement(id: "seq", name: "Sequence", sectionIds: ["v1", "c"])], default: "seq")
        let choice = SongSequenceOrder.choose(name: "Sequence", in: deck, forItem: true, itemPlays: nil, newID: { "new" })
        #expect(choice == .init(id: "new", name: "Sequence 2", isNew: true))
        // Even when the item has the default picked by id.
        let picked = SongSequenceOrder.choose(name: "Sequence", in: deck, forItem: true, itemPlays: "seq", newID: { "new" })
        #expect(picked.id == "new")
    }

    @Test func aPlanItemsOwnOrderIsUpdatedInPlace() {
        let deck = song([
            Arrangement(id: "seq", name: "Sequence", sectionIds: ["v1"]),
            Arrangement(id: "mine", name: "Short", sectionIds: ["c"]),
        ], default: "seq")
        let choice = SongSequenceOrder.choose(name: "short", in: deck, forItem: true, itemPlays: "mine", newID: { "new" })
        #expect(choice == .init(id: "mine", name: "Short", isNew: false))
        // Another item's order with that name is not this item's to change.
        let other = SongSequenceOrder.choose(name: "Short", in: deck, forItem: true, itemPlays: nil, newID: { "new" })
        #expect(other == .init(id: "new", name: "Short 2", isNew: true))
    }

    @Test func theDefaultIsUpdatedByNameOrMade() {
        let deck = song([Arrangement(id: "seq", name: "Sequence", sectionIds: ["v1"])], default: "seq")
        #expect(SongSequenceOrder.choose(name: "Sequence", in: deck, forItem: false, itemPlays: nil).id == "seq")
        let fresh = SongSequenceOrder.choose(name: "Easter", in: deck, forItem: false, itemPlays: nil, newID: { "new" })
        #expect(fresh == .init(id: "new", name: "Easter", isNew: true))
    }
}
