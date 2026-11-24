import Foundation
import Testing
@testable import PresenterCore

struct SongSlidesTests {

    private func song() -> Presentation {
        Presentation(id: "s", name: "It Really Is Amazing Grace", presentationKind: .song, themeId: "", slides: [])
    }

    private func card(_ section: String, _ lines: [(String, String)]) -> SongSlides.Card {
        SongSlides.Card(section: section, lines: lines.map { SongSlides.Line(words: $0.0, chords: $0.1) })
    }

    @Test func eachCardIsOneSlideWithItsWordsOnly() {
        var p = song()
        SongSlides.apply([
            card("Verse 1", [("Amazing grace how sweet the sound", "G       C        G"), ("That saved a wretch like me", "")]),
            card("Verse 1", [("I once was lost", "Em"), ("but now am found", "")]),
        ], to: &p)
        #expect(p.slides.count == 2)
        #expect(p.slides[0].objects.first?.text == "Amazing grace how sweet the sound\nThat saved a wretch like me")
        #expect(p.sections?.map(\.name) == ["Verse 1"])
        #expect(Set(p.slides.compactMap(\.sectionId)).count == 1)
    }

    @Test func chordsSitWhereTheyAreTyped() {
        var p = song()
        SongSlides.apply([card("Chorus", [("My chains are gone", "G     C    D")])], to: &p)
        let chords = p.slides[0].objects.first?.chords ?? []
        #expect(chords.map(\.symbol) == ["G", "C", "D"])
        #expect(chords.map(\.column) == [0, 6, 11])
        #expect(chords.allSatisfy { $0.line == 0 })
    }

    @Test func anyWordOnTheChordLineIsAChord() {
        var p = song()
        SongSlides.apply([card("Bridge", [("Hallelujah", "N.C.  Hm7")])], to: &p)
        #expect(p.slides[0].objects.first?.chords?.map(\.symbol) == ["N.C.", "Hm7"])
        #expect(p.slides[0].objects.first?.text == "Hallelujah")
    }

    @Test func aChordPastTheWordsSitsAtTheirEnd() {
        var p = song()
        SongSlides.apply([card("Tag", [("Amen", "C            G")])], to: &p)
        #expect(p.slides[0].objects.first?.chords?.last?.column == 4)
    }

    @Test func roundTripsThroughTheCards() {
        var p = song()
        let typed = [
            card("Verse 1", [("Amazing grace", "G     C"), ("how sweet the sound", "    D")]),
            card("Chorus", [("My chains are gone", "")]),
        ]
        SongSlides.apply(typed, to: &p)
        let back = SongSlides.cards(from: p)
        #expect(back.map(\.section) == ["Verse 1", "Chorus"])
        #expect(back[0].lines.map(\.words) == ["Amazing grace", "how sweet the sound"])
        #expect(back[0].lines.map(\.chords) == ["G     C", "    D"])
        #expect(back.map(\.id) == p.slides.map(\.id))
    }

    @Test func editingKeepsTheSlideAndItsBackground() {
        var p = song()
        SongSlides.apply([card("Verse 1", [("Old words", "")])], to: &p)
        p.slides[0].background = CueMedia(mediaId: "ocean")
        var cards = SongSlides.cards(from: p)
        cards[0].lines[0].words = "New words"
        let id = p.slides[0].id
        SongSlides.apply(cards, to: &p)
        #expect(p.slides[0].id == id)
        #expect(p.slides[0].background?.mediaId == "ocean")
        #expect(p.slides[0].objects.first?.text == "New words")
    }

    @Test func aRepeatedSectionWithTheSameWordsIsSungAgain() {
        var p = song()
        SongSlides.apply([
            card("Verse 1", [("First verse", "")]),
            card("Chorus", [("The chorus", "")]),
            card("Verse 2", [("Second verse", "")]),
            card("Chorus", [("The chorus", "")]),
        ], to: &p)
        #expect(p.slides.count == 3)
        let names = Dictionary(uniqueKeysWithValues: (p.sections ?? []).map { ($0.id, $0.name) })
        let order = p.arrangements?.first { $0.id == p.defaultArrangementId }?.sectionIds.compactMap { names[$0] }
        #expect(order == ["Verse 1", "Chorus", "Verse 2", "Chorus"])
    }

    @Test func aSongOrderTheOperatorSetIsKept() {
        var p = song()
        SongSlides.apply([card("Verse 1", [("A", "")]), card("Chorus", [("B", "")])], to: &p)
        let ids = p.sections!.map(\.id)
        let index = p.arrangements!.firstIndex { $0.id == p.defaultArrangementId }!
        p.arrangements![index].sectionIds = [ids[1], ids[0], ids[1]]
        var cards = SongSlides.cards(from: p)
        cards[0].lines[0].words = "A changed"
        SongSlides.apply(cards, to: &p)
        #expect(p.arrangements![index].sectionIds == [ids[1], ids[0], ids[1]])
    }

    private func order(_ p: Presentation) -> [String]? {
        let names = Dictionary(uniqueKeysWithValues: (p.sections ?? []).map { ($0.id, $0.name) })
        return p.arrangements?.first { $0.id == p.defaultArrangementId }?.sectionIds.compactMap { names[$0] }
    }

    @Test func aRepeatTypedAsACardIsSungAgainInASongThatHasAnOrder() {
        var p = song()
        SongSlides.apply([
            card("Verse 1", [("First verse", "")]),
            card("Chorus", [("The chorus", "")]),
            card("Verse 2", [("Second verse", "")]),
        ], to: &p)
        var cards = SongSlides.cards(from: p)
        var again = cards[1]
        again.id = UUID().uuidString
        cards.append(again)
        SongSlides.apply(cards, to: &p)
        #expect(order(p) == ["Verse 1", "Chorus", "Verse 2", "Chorus"])
        // Saved again unchanged, the repeat stays.
        SongSlides.apply(SongSlides.cards(from: p), to: &p)
        #expect(order(p) == ["Verse 1", "Chorus", "Verse 2", "Chorus"])
    }

    @Test func aNewSectionGoesOnTheEndOfTheOperatorsOrder() {
        var p = song()
        SongSlides.apply([card("Verse 1", [("A", "")]), card("Chorus", [("B", "")])], to: &p)
        let ids = p.sections!.map(\.id)
        let index = p.arrangements!.firstIndex { $0.id == p.defaultArrangementId }!
        p.arrangements![index].sectionIds = [ids[0], ids[1], ids[1]]
        var cards = SongSlides.cards(from: p)
        cards.append(card("Tag", [("C", "")]))
        SongSlides.apply(cards, to: &p)
        #expect(order(p) == ["Verse 1", "Chorus", "Chorus", "Tag"])
    }

    @Test func aRenamedSectionKeepsItsIdAndPlace() {
        var p = song()
        SongSlides.apply([card("Verse", [("A", "")]), card("Chorus", [("B", "")])], to: &p)
        let ids = p.sections!.map(\.id)
        let index = p.arrangements!.firstIndex { $0.id == p.defaultArrangementId }!
        p.arrangements![index].sectionIds = [ids[1], ids[0], ids[1]]
        var cards = SongSlides.cards(from: p)
        cards[0].section = "Verse 1"
        cards[1].section = "CHORUS"
        SongSlides.apply(cards, to: &p)
        #expect(p.sections?.map(\.id) == ids)
        #expect(order(p) == ["CHORUS", "Verse 1", "CHORUS"])
    }

    @Test func pastedRepeatsBecomeCardsAndAreSung() {
        let pasted = LyricTextImporter.makePresentation("""
        Verse 1
        Line one

        Chorus
        Sing it out

        Verse 2
        Line three

        Chorus
        """, linesPerSlide: 2)
        // The editor leaves out the blank opening slide an import adds.
        let cards = SongSlides.cardsAsSung(from: pasted).filter { $0.lines.contains { !$0.words.isEmpty } }
        #expect(cards.map(\.section) == ["Verse 1", "Chorus", "Verse 2", "Chorus"])
        #expect(Set(cards.map(\.id)).count == 4)
        var p = song()
        SongSlides.apply(cards, to: &p)
        #expect(p.slides.count == 3)
        #expect(order(p) == ["Verse 1", "Chorus", "Verse 2", "Chorus"])
    }

    @Test func anEmptyCardIsABlankSlide() {
        var p = song()
        SongSlides.apply([card("Intro", [("", "G  C  D")]), card("Verse 1", [("Words", "")])], to: &p)
        #expect(p.slides.count == 2)
        #expect(p.slides[0].objects.first?.text == "")
        #expect(p.slides[0].objects.first?.chords?.count == 3)
        SongSlides.apply([card("Intro", [("", "")]), card("Verse 1", [("Words", "")])], to: &p)
        #expect(p.slides[0].objects.isEmpty)
    }

    @Test func lyricsTextKeepsSectionsAndChords() {
        let text = SongSlides.reflowText([
            card("Verse 1", [("Amazing grace", "G      C")]),
            card("Verse 1", [("how sweet", "")]),
            card("Chorus", [("Gone", "D")]),
        ])
        #expect(text == "Verse 1\n[G]Amazing[C] grace\n\nhow sweet\n\nChorus\n[D]Gone")
    }

    @Test func chordLineSpacesChordsThatWouldTouch() {
        let line = SongSlides.chordLine([
            ChordPlacement(line: 0, column: 0, symbol: "Gsus4"),
            ChordPlacement(line: 0, column: 2, symbol: "G"),
        ])
        #expect(line == "Gsus4 G")
    }

    /// A song as Shepherd builds it: two chords at one column, a chord
    /// after the last word, and a chord on a line past the words.
    private func charted() -> Presentation {
        var p = song()
        SongSlides.apply([card("Verse 1", [("Great is Your", ""), ("faithfulness to me", "")]),
                          card("Chorus", [("Holy forever", "")])], to: &p)
        p.slides[0].objects[0].chords = [
            ChordPlacement(line: 0, column: 0, symbol: "6m7"),
            ChordPlacement(line: 0, column: 1, symbol: "5"),
            ChordPlacement(line: 1, column: 18, symbol: "1"),
            ChordPlacement(line: 1, column: 20, symbol: "4"),
            ChordPlacement(line: 2, column: 0, symbol: "5sus"),
        ]
        p.slides[1].objects[0].chords = [ChordPlacement(line: 0, column: 5, symbol: "1sus")]
        p.reflowSource = "the chart"
        return p
    }

    @Test func savingUnchangedCardsMovesNoChord() {
        var p = charted()
        let before = p.slides
        SongSlides.apply(SongSlides.cards(from: p), to: &p)
        #expect(p.slides == before)
    }

    @Test func editingOneSlideLeavesTheOthersExactly() {
        var p = charted()
        let first = p.slides[0]
        var cards = SongSlides.cards(from: p)
        cards[1].lines[0].words = "Holy, forever"
        SongSlides.apply(cards, to: &p)
        #expect(p.slides[0] == first)
        #expect(p.slides[1].objects[0].text == "Holy, forever")
    }

    @Test func editingOneLineLeavesTheOtherLinesChords() {
        var p = charted()
        var cards = SongSlides.cards(from: p)
        cards[0].lines[0].words = "Great is Thy"
        SongSlides.apply(cards, to: &p)
        let chords = p.slides[0].objects[0].chords ?? []
        #expect(chords.filter { $0.line == 1 }.map(\.column) == [18, 20])
        #expect(chords.filter { $0.line == 2 }.map(\.symbol) == ["5sus"])
        // The edited line's chords are read from its chord line, as shown.
        #expect(chords.filter { $0.line == 0 }.map(\.symbol) == ["6m7", "5"])
    }

    @Test func aChordLineRetypedTheSameIsNoEdit() {
        let p = charted()
        let saved = SongSlides.cards(from: p)
        var cards = saved
        cards[1].lines[0].chords += "   "
        #expect(SongSlides.sameContent(cards, saved))
        cards[1].lines[0].chords = "1sus"
        #expect(!SongSlides.sameContent(cards, saved))
    }

    @Test func aChordTypedOverAStoredOneIsSaved() {
        var p = charted()
        var cards = SongSlides.cards(from: p)
        cards[1].lines[0].chords = "4    1sus"
        SongSlides.apply(cards, to: &p)
        #expect(p.slides[1].objects[0].chords?.map(\.symbol) == ["4", "1sus"])
        #expect(p.slides[1].objects[0].chords?.map(\.column) == [0, 5])
    }
}

extension SongSlidesTests {
    /// The song changed while the editor was open (Match Chords, another
    /// Mac) and the operator saves theirs: only the slide they edited is
    /// written; the others keep the newer chords.
    @Test func savingOverANewerSongWritesOnlyTheEditedSlides() {
        var p = song()
        SongSlides.apply([
            SongSlides.Card(section: "Verse 1", lines: [SongSlides.Line(words: "Great is Your", chords: "G")]),
            SongSlides.Card(section: "Chorus", lines: [SongSlides.Line(words: "Holy forever", chords: "C")]),
        ], to: &p)
        let loaded = SongSlides.cards(from: p)
        var cards = loaded
        cards[1].lines[0].words = "Holy, forever"
        // Meanwhile the verse's chords changed.
        p.slides[0].objects[0].chords = [ChordPlacement(line: 0, column: 0, symbol: "D")]
        SongSlides.apply(SongSlides.rebased(cards, loaded: loaded, onto: p), to: &p)
        #expect(p.slides[0].objects[0].chords?.map(\.symbol) == ["D"])
        #expect(p.slides[1].objects[0].text == "Holy, forever")
    }
}
