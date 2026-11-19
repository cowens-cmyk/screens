import Testing

@testable import PresenterCore

struct ChordEditsTests {
    private func slide(_ id: String, _ section: String, _ text: String, chords: [ChordPlacement] = []) -> Slide {
        Slide(
            id: id, name: id,
            objects: [SlideObject(
                id: "lyrics", objectKind: .text, name: "Lyrics", text: text, chords: chords.isEmpty ? nil : chords)],
            sectionId: section)
    }

    private func song(_ slides: [Slide], key: String? = "G", edits: [ChordLineEdit]? = nil) -> Presentation {
        Presentation(
            id: "song", name: "Song", presentationKind: .song, themeId: "",
            slides: slides,
            sections: [
                PresentationSection(id: "v1", name: "Verse 1"),
                PresentationSection(id: "v2", name: "Verse 2"),
                PresentationSection(id: "c", name: "Chorus"),
            ],
            musicKey: key, chordEdits: edits)
    }

    private func chords(_ presentation: Presentation, slide: String, line: Int) -> [String] {
        let object = presentation.slides.first { $0.id == slide }?.objects.first
        return (object?.chords ?? []).filter { $0.line == line }.sorted { $0.column < $1.column }
            .map { "\($0.column):\($0.symbol)" }
    }

    @Test func repeatedWordsInASectionAreToldApart() {
        let deck = song([
            slide("a", "c", "Holy forever\nHoly forever"),
            slide("b", "c", "Holy forever"),
        ])
        let lines = ChordEdits.lines(of: deck)
        #expect(lines.map(\.occurrence) == [0, 1, 2])
        #expect(lines.map(\.section) == ["Chorus", "Chorus", "Chorus"])
    }

    @Test func aRecordedEditComesBackAfterTheSlidesAreBuiltAgain() {
        var deck = song([slide("a", "c", "Holy forever\nHoly forever")])
        let second = ChordEdits.lines(of: deck)[1]
        deck.chordEdits = ChordEdits.recording(
            [ChordPlacement(line: 1, column: 5, symbol: "Em7")], for: second, key: "G", in: nil)

        // Rebuilt (new slide ids, split differently), Shepherd's chords on every line.
        var rebuilt = song([
            slide("x", "c", "Holy forever", chords: [ChordPlacement(line: 0, column: 0, symbol: "G")]),
            slide("y", "c", "Holy  forever", chords: [ChordPlacement(line: 0, column: 0, symbol: "G")]),
        ])
        rebuilt.chordEdits = deck.chordEdits
        let applied = ChordEdits.applying(rebuilt)

        #expect(chords(applied, slide: "x", line: 0) == ["0:G"], "the first time isn't the one edited")
        #expect(chords(applied, slide: "y", line: 0) == ["5:Em7"])
    }

    @Test func aChordTakenOutStaysOut() {
        let deck = song([slide("a", "v1", "Amazing grace")])
        let edits = ChordEdits.recording([], for: ChordEdits.lines(of: deck)[0], key: "G", in: nil)
        var rebuilt = song(
            [slide("b", "v1", "Amazing grace", chords: [ChordPlacement(line: 0, column: 0, symbol: "G")])],
            edits: edits)
        rebuilt = ChordEdits.applying(rebuilt)
        #expect(chords(rebuilt, slide: "b", line: 0).isEmpty)
    }

    @Test func editsMoveToTheSongsKeyAndStayWithinTheLine() {
        let edits = [ChordLineEdit(
            section: "Verse 1", text: "Amazing grace", occurrence: 0,
            chords: [ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 0, column: 40, symbol: "D/F#")],
            key: "G")]
        let applied = ChordEdits.applying(song([slide("a", "v1", "Amazing grace")], key: "A", edits: edits))
        #expect(chords(applied, slide: "a", line: 0) == ["0:A", "13:E/G#"])
    }

    @Test func recordingTheSameLineAgainReplacesIt() {
        let deck = song([slide("a", "v1", "Amazing grace")])
        let ref = ChordEdits.lines(of: deck)[0]
        var edits = ChordEdits.recording([ChordPlacement(line: 0, column: 0, symbol: "G")], for: ref, key: "G", in: nil)
        edits = ChordEdits.recording([ChordPlacement(line: 0, column: 8, symbol: "C")], for: ref, key: "G", in: edits)
        #expect(edits.count == 1)
        #expect(edits[0].chords.map(\.symbol) == ["C"])
    }

    @Test func reflowKeepsChordsTypedInTheText() {
        let edits = [ChordLineEdit(
            section: "Verse 1", text: "Amazing grace", occurrence: 0,
            chords: [ChordPlacement(line: 0, column: 0, symbol: "G")], key: "G")]
        let deck = song([
            slide("a", "v1", "Amazing grace\nhow sweet", chords: [ChordPlacement(line: 0, column: 8, symbol: "C")]),
        ], edits: edits)
        let applied = ChordEdits.applying(deck, onlyBare: true)
        #expect(chords(applied, slide: "a", line: 0) == ["8:C"])
    }

    @Test func updateFromShepherdPutsHandChordsBack() {
        let existing = song(
            [slide("a", "v1", "Amazing grace", chords: [ChordPlacement(line: 0, column: 8, symbol: "Cmaj7")])],
            edits: [ChordLineEdit(
                section: "Verse 1", text: "Amazing grace", occurrence: 0,
                chords: [ChordPlacement(line: 0, column: 8, symbol: "Cmaj7")], key: "G")])
        let fresh = song([slide("f", "v1", "Amazing grace", chords: [ChordPlacement(line: 0, column: 8, symbol: "C")])])
        let replaced = ShepherdSongImport.replacing(existing, with: fresh)
        #expect(chords(replaced, slide: "a", line: 0) == ["8:Cmaj7"])
        #expect(replaced.chordEdits == existing.chordEdits)
    }

    @Test func copyingAVersesChordsOntoAnother() {
        let deck = song([
            slide("a", "v1", "Amazing grace\nhow sweet the sound", chords: [
                ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 1, column: 14, symbol: "D"),
            ]),
            slide("b", "v2", "Twas grace\nthat taught", chords: [ChordPlacement(line: 0, column: 2, symbol: "Em")]),
        ])
        let copied = ChordEdits.copyingChords(in: deck, from: "v1", to: "v2")
        #expect(chords(copied, slide: "b", line: 0) == ["0:G"])
        #expect(chords(copied, slide: "b", line: 1) == ["11:D"], "kept within the shorter line")
        #expect(chords(ChordEdits.clearingChords(in: copied, section: "v2"), slide: "b", line: 0).isEmpty)
    }

    @Test func tabStepsWordByWord() {
        let text = "Amazing grace how"
        #expect(ChordEdits.nextWordStart(in: text, after: 0) == 8)
        #expect(ChordEdits.nextWordStart(in: text, after: 9) == 14)
        #expect(ChordEdits.nextWordStart(in: text, after: 14) == nil)
        #expect(ChordEdits.previousWordStart(in: text, before: 14) == 8)
        #expect(ChordEdits.previousWordStart(in: text, before: 10) == 8)
        #expect(ChordEdits.previousWordStart(in: text, before: 0) == nil)
        #expect(ChordEdits.firstWordStart(in: "  hi") == 2)
        #expect(ChordEdits.lastWordStart(in: text) == 14)
    }

    @Test func paletteIsTheKeysChordsThenTheSongs() {
        let deck = song([slide("a", "v1", "Amazing grace", chords: [
            ChordPlacement(line: 0, column: 0, symbol: "Cmaj7"), ChordPlacement(line: 0, column: 8, symbol: "G"),
        ])])
        #expect(ChordEdits.palette(musicKey: "G", in: deck) == ["G", "Am", "Bm", "C", "D", "Em", "Cmaj7"])
        #expect(ChordEdits.palette(musicKey: "Em", in: nil) == ["Em", "G", "Am", "Bm", "C", "D"])
        #expect(ChordEdits.palette(musicKey: "Eb", in: nil).prefix(3) == ["Eb", "Fm", "Gm"])
    }
}
