import Foundation
import Testing
@testable import PresenterCore

/// A ChordPro file splits cleanly: every bracket is a chord for the stage
/// display, everything else on a lyric line is words for the audience.
struct ChordProImportTests {

    private let song = """
    # exported from a chord app
    {title: I Thank God}
    {artist: Maverick City Music}
    {key: C}
    {tempo: 72}
    {capo: 2}

    {comment: Intro}
    [C] [F] [Am] [G]

    {start_of_verse: Verse 1}
    [C]Wand'ring into the [F]night
    Wanting a [Am]place to [G]hide
    This weary soul this [F]bag of [Hm]bones
    [N.C.]I try with all my [C7alt]might
    {end_of_verse}

    {start_of_tab}
    e|---0---3---|
    B|---1---0---|
    {end_of_tab}

    {soc}
    [C]I thank [F]God
    For [Am]saving [G]me [*Repeat x2]
    {eoc}

    {start_of_bridge label="Bridge 1"}
    Up from the [Bbadd9(no3)]grave He a[G]rose
    {end_of_bridge}

    {chorus}
    """

    /// The way the app imports a file: cleaned, then built.
    private func imported(removePunctuation: Bool = true) -> Presentation {
        LyricTextImporter.makePresentation(LyricCleanup.clean(song, removePunctuation: removePunctuation))
    }

    private func lyricText(_ p: Presentation) -> String {
        p.slides.compactMap { $0.objects.first?.text }.joined(separator: "\n")
    }

    private func sectionName(_ p: Presentation, _ slide: Slide) -> String? {
        p.sections?.first { $0.id == slide.sectionId }?.name
    }

    @Test func noChordReachesTheAudience() {
        let words = lyricText(imported())
        #expect(!words.contains("["))
        for chord in ["Hm", "N.C.", "NC", "C7alt", "Bbadd9", "Repeat"] {
            #expect(!words.contains(chord), "\(chord) leaked into the lyrics")
        }
        #expect(words.contains("This weary soul this bag of bones"))
        #expect(words.contains("I try with all my might"))
        #expect(words.contains("He arose"))
    }

    @Test func everyChordIsKeptForTheStage() {
        let symbols = imported().slides.flatMap { $0.objects.first?.chords ?? [] }.map(\.symbol)
        for chord in ["C", "F", "Am", "G", "Hm", "N.C.", "C7alt", "Bbadd9(no3)", "*Repeat x2"] {
            #expect(symbols.contains(chord), "\(chord) was lost")
        }
    }

    @Test func chordsSitOnTheirSyllables() {
        let p = imported()
        let slide = p.slides.first { $0.objects.first?.text.contains("He arose") == true }
        let object = slide?.objects.first
        let line = object?.text.components(separatedBy: "\n").firstIndex { $0.contains("He arose") }
        let g = object?.chords?.first { $0.symbol == "G" && $0.line == line }
        // "Up from the grave He a|rose"
        #expect(g?.column == "Up from the grave He a".count)
    }

    @Test func tabsAndCommentsAreNotLyrics() {
        let words = lyricText(imported())
        #expect(!words.contains("---"))
        #expect(!words.contains("exported"))
    }

    @Test func sectionsAndRepeats() {
        let p = imported()
        let names = p.sections?.map(\.name) ?? []
        #expect(names.contains("Intro"))
        #expect(names.contains("Verse 1"))
        #expect(names.contains("Chorus"))
        #expect(names.contains("Bridge 1"))
        let bridge = p.slides.first { $0.objects.first?.text.contains("grave") == true }
        #expect(bridge.flatMap { sectionName(p, $0) } == "Bridge 1")
        // {chorus} sings the chorus again.
        let order = p.arrangements?.first?.sectionIds.compactMap { id in p.sections?.first { $0.id == id }?.name }
        #expect(order?.last == "Chorus")
        #expect(order?.filter { $0 == "Chorus" }.count == 2)
    }

    @Test func headerIsRead() {
        let p = imported()
        #expect(p.name == "I Thank God")
        #expect(p.musicKey == "C")
    }

    @Test func punctuationKeptWhenAsked() {
        let words = lyricText(imported(removePunctuation: false))
        #expect(words.contains("Wand'ring into the night"))
        #expect(!words.contains("N.C."))
    }

    @Test func annotationsShowWithoutTheirMark() {
        #expect(ChordMath.display("*Repeat x2", musicKey: "C", displayKey: "D", notation: .chords) == "Repeat x2")
        #expect(ChordMath.display("N.C.", musicKey: "C", displayKey: "D", notation: .chords) == "N.C.")
        #expect(ChordMath.display("C", musicKey: "C", displayKey: "D", notation: .chords) == "D")
    }

    @Test func labelsInBracketsStayLabels() {
        #expect(!ChordMath.isBracketChord("Chorus"))
        #expect(!ChordMath.isBracketChord("Verse 2"))
        #expect(!ChordMath.isBracketChord(""))
        #expect(ChordMath.isBracketChord("Hm"))
        #expect(ChordMath.isBracketChord("*Coda"))
    }

    @Test func plainLyricsAreUnchanged() {
        let text = "On the mountain we will worship\nIn the valley we will sing"
        #expect(lyricText(LyricTextImporter.makePresentation(text)) == text)
    }
}
