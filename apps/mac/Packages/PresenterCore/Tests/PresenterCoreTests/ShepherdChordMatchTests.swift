import Foundation
import Testing
@testable import PresenterCore

@Suite struct ShepherdChordMatchTests {

    private static let chart = """
    Verse 1
    [1]I'll praise when I'm [5]sure
    [4]Praise when I'm [1]doubting

    Chorus
    [1]Holy for[1sus]ever [1]
    """

    private func song(_ chart: String = Self.chart) throws -> Presentation {
        let detail = ShepherdClient.SongDetail(
            id: "s1", title: "Praise", defaultKey: "A",
            arrangements: [ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: [])],
            chordChart: chart, originalKey: "A", defaultArrangementId: "a1",
            chart: ShepherdClient.ChartInfo(format: "ChordPro", hasChart: true, writtenKey: "A"))
        return try #require(ShepherdSongImport.presentation(song: detail, arrangement: detail.arrangements.first))
    }

    private func line(_ presentation: Presentation, _ words: String) throws -> ChordEdits.LineRef {
        try #require(ChordEdits.lines(of: presentation).first {
            ShepherdChordMatch.normalized($0.text) == ShepherdChordMatch.normalized(words)
        })
    }

    @Test func aSongAsTheChartBuildsItIsLeftAlone() throws {
        let chart = try song()
        let result = ShepherdChordMatch.matching(chart, to: chart)
        #expect(!result.changed)
        #expect(result.unmatchedLines == 0)
        #expect(result.matchedLines > 0)
    }

    @Test func changedChordsGoBackToTheCharts() throws {
        let chart = try song()
        var mine = chart
        let ref = try line(mine, "Holy forever")
        mine = ChordEdits.settingChords([ChordPlacement(line: ref.line, column: 0, symbol: "1")], at: ref, in: mine)
        let result = ShepherdChordMatch.matching(mine, to: chart)
        #expect(result.changedLines == 1)
        #expect(ChordEdits.chords(at: ref, in: result.presentation).map(\.symbol) == ["1", "1sus", "1"])
    }

    @Test func handEditsOnMatchedLinesAreDropped() throws {
        let chart = try song()
        var mine = chart
        let ref = try line(mine, "Holy forever")
        mine = ChordEdits.settingChords([ChordPlacement(line: ref.line, column: 0, symbol: "4")], at: ref, in: mine)
        mine.chordEdits = ChordEdits.recordingAll(in: mine) { $0.text == ref.text }
        #expect(mine.chordEdits?.count == 1)
        let result = ShepherdChordMatch.matching(mine, to: chart)
        #expect(result.droppedHandEdits == 1)
        #expect(result.presentation.chordEdits == nil)
        #expect(ChordEdits.chords(at: ref, in: result.presentation).map(\.symbol) == ["1", "1sus", "1"])
    }

    @Test func wordsTheChartLacksKeepTheirChords() throws {
        let chart = try song()
        var mine = chart
        // The words on one line changed in Screens.
        let ref = try line(mine, "Holy forever")
        let slide = try #require(mine.slides.firstIndex { $0.id == ref.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == ref.objectID })
        var lines = mine.slides[slide].objects[object].text.components(separatedBy: "\n")
        lines[ref.line] = "Glory to the Lamb"
        mine.slides[slide].objects[object].text = lines.joined(separator: "\n")
        let result = ShepherdChordMatch.matching(mine, to: chart)
        #expect(result.unmatchedLines == 1)
        let kept = try line(result.presentation, "Glory to the Lamb")
        #expect(ChordEdits.chords(at: kept, in: result.presentation) == ChordEdits.chords(at: kept, in: mine))
    }

    @Test func apostrophesDontSplitWords() {
        #expect(ShepherdChordMatch.normalized("I’ll praise when I’m sure") == ShepherdChordMatch.normalized("Ill praise when Im sure"))
    }

    @Test func chordsStayOverTheirWordsWhenPunctuationDiffers() {
        let moved = ShepherdChordMatch.moving(
            [ChordPlacement(line: 0, column: 0, symbol: "1"), ChordPlacement(line: 0, column: 19, symbol: "5")],
            from: "Ill praise when Im sure", to: "I’ll praise, when I’m sure")
        #expect(moved.map(\.column) == [0, 22])
    }

    @Test func chordsFollowTheirWordsAcrossOtherLineBreaks() throws {
        let chart = try song()
        // The verse's two lines as one in Screens, with no chords.
        var mine = chart
        let first = try line(mine, "I'll praise when I'm sure")
        let second = try line(mine, "Praise when I'm doubting")
        #expect(first.slideID == second.slideID)
        let slide = try #require(mine.slides.firstIndex { $0.id == first.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == first.objectID })
        mine.slides[slide].objects[object].text = "\(first.text) \(second.text)"
        mine.slides[slide].objects[object].chords = nil
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let joined = try line(result.presentation, "\(first.text) \(second.text)")
        #expect(ChordEdits.chords(at: joined, in: result.presentation).map(\.symbol) == ["1", "5", "4", "1"])
        #expect(result.unmatchedLines == 0)
    }

    @Test func syllableChordsStayOnTheirLine() throws {
        // Chart and song with words that don't line up at the line's end.
        let chart = try song("""
        Chorus
        And the angels [42]cry Ho [6m7]ly [5]
        All creation [1/3]cries
        """)
        var mine = chart
        let ref = try line(mine, "And the angels cry Ho ly")
        let slide = try #require(mine.slides.firstIndex { $0.id == ref.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == ref.objectID })
        var lines = mine.slides[slide].objects[object].text.components(separatedBy: "\n")
        lines[ref.line] = "And the angels cry Holy"
        mine.slides[slide].objects[object].text = lines.joined(separator: "\n")
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let holy = try line(result.presentation, "And the angels cry Holy")
        #expect(ChordEdits.chords(at: holy, in: result.presentation).map(\.symbol).contains("6m7"))
        let next = try line(result.presentation, "All creation cries")
        #expect(ChordEdits.chords(at: next, in: result.presentation).map(\.symbol) == ["1/3"])
    }

    /// "freedom [4/6] Your stripes": the song breaks the line before "Your",
    /// and the chord starts the second line, as in the chart.
    @Test func aChordInTheGapGoesWithTheWordAfterIt() throws {
        let chart = try song("""
        Bridge 1
        [1] Your cross my freedom [4/6] Your stripes my healing
        """)
        var mine = chart
        let ref = try line(mine, "Your cross my freedom Your stripes my healing")
        let slide = try #require(mine.slides.firstIndex { $0.id == ref.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == ref.objectID })
        mine.slides[slide].objects[object].text = "Your cross my freedom \nYour stripes my healing"
        mine.slides[slide].objects[object].chords = nil
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let first = try line(result.presentation, "Your cross my freedom")
        let second = try line(result.presentation, "Your stripes my healing")
        #expect(ChordEdits.chords(at: first, in: result.presentation).map(\.symbol) == ["1"])
        #expect(ChordEdits.chords(at: second, in: result.presentation).map { "\($0.column):\($0.symbol)" } == ["0:4/6"])
    }

    /// The chart sings a line three times, the song shows it once: the
    /// line gets its chords once, not the other repeats' piled on it.
    @Test func repeatsTheSongLacksDontPileUp() throws {
        let chart = try song("""
        Chorus
        [6m7]Great is Your [1/3]faithfulness to [1]me
        [6m7]Great is Your [1/3]faithfulness to [1]me
        [6m7]Great is Your [1/3]faithfulness to [1]me
        """)
        var mine = chart
        // Only the first line kept.
        for index in mine.slides.indices {
            for object in mine.slides[index].objects.indices where mine.slides[index].objects[object].objectKind == .text {
                let first = mine.slides[index].objects[object].text.components(separatedBy: "\n").first ?? ""
                mine.slides[index].objects[object].text = first
                mine.slides[index].objects[object].chords = nil
            }
        }
        mine.slides = Array(mine.slides.filter { $0.objects.contains { !$0.text.isEmpty } }.prefix(1))
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let ref = try line(result.presentation, "Great is Your faithfulness to me")
        #expect(ChordEdits.chords(at: ref, in: result.presentation).map(\.symbol) == ["6m7", "1/3", "1"])
    }

    /// A song imported before Screens joined a word split around a chord
    /// ("faithful [Gb]- ness") shows it split; matching joins it and puts
    /// the chord inside it, as the chart has it.
    @Test func aWordShownSplitIsJoined() throws {
        let chart = try song("""
        Chorus
        I’m standing on Your [5]faithful [4]- ness
        """)
        var mine = chart
        let ref = try line(mine, "I’m standing on Your faithfulness")
        let slide = try #require(mine.slides.firstIndex { $0.id == ref.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == ref.objectID })
        mine.slides[slide].objects[object].text = "I’m standing on Your faithful ness"
        mine.slides[slide].objects[object].chords = [ChordPlacement(line: 0, column: 20, symbol: "5"),
                                                     ChordPlacement(line: 0, column: 20, symbol: "4")]
        let result = ShepherdChordMatch.matching(mine, to: chart)
        #expect(result.joinedWords == ["faithful ness"])
        let joined = try line(result.presentation, "I’m standing on Your faithfulness")
        #expect(joined.text == "I’m standing on Your faithfulness")
        let theirs = try line(chart, "I’m standing on Your faithfulness")
        #expect(ChordEdits.chords(at: joined, in: result.presentation).map { "\($0.column):\($0.symbol)" }
            == ChordEdits.chords(at: theirs, in: chart).map { "\($0.column):\($0.symbol)" })
        #expect(ChordEdits.chords(at: joined, in: result.presentation).map(\.symbol) == ["5", "4"])
        #expect(result.changed)
    }

    @Test func twoRealWordsAreNotJoined() throws {
        let chart = try song("""
        Verse 1
        [1]Every one of us, every[4]one
        """)
        let result = ShepherdChordMatch.matching(chart, to: chart)
        #expect(result.joinedWords.isEmpty)
    }

    /// An Intro left blank by an older import shows the chart's chord row.
    @Test func aWordlessPartGetsTheChartsChordRows() throws {
        let chart = try song("""
        Intro
        [1] [4] [6m7] [5]

        Verse 1
        [1]I'll praise when I'm [5]sure
        """)
        var mine = chart
        let intro = try #require(mine.slides.firstIndex { slide in
            slide.objects.allSatisfy { ShepherdChordMatch.normalized($0.text).isEmpty } && slide.objects.contains { !($0.chords ?? []).isEmpty }
        })
        mine.slides[intro].objects = []
        let result = ShepherdChordMatch.matching(mine, to: chart)
        #expect(result.chordOnlySlides == 1)
        #expect(result.changed)
        let object = try #require(ChordEdits.lyricObject(of: result.presentation.slides[intro]))
        #expect(object.chords?.map(\.symbol) == ["1", "4", "6m7", "5"])
        #expect(ShepherdChordMatch.normalized(object.text).isEmpty)
        // Matching again changes nothing.
        #expect(!ShepherdChordMatch.matching(result.presentation, to: chart).changed)
    }

    /// The chart writes a bridge three times with other chords each time;
    /// the song has it as three parts. Each gets its own pass's chords.
    @Test func eachPassOfARepeatedPartGetsItsOwnChords() throws {
        let chart = try song("""
        Bridge
        I have [1]decided to follow [4]Jesus

        Bridge
        The cross be[6m]fore me the world be[5]hind me

        Bridge
        I have [6m]decided to follow [5]Jesus
        """)
        // The song: Bridge 1a, Bridge 2, Bridge 1b, from the chart's slides.
        var mine = chart
        let names = ["Bridge 1a", "Bridge 2", "Bridge 1b"]
        mine.sections = names.map { PresentationSection(id: $0, name: $0) }
        var index = 0
        for s in mine.slides.indices where mine.slides[s].objects.contains(where: { !ShepherdChordMatch.normalized($0.text).isEmpty }) {
            mine.slides[s].sectionId = names[min(index, 2)]
            index += 1
            for o in mine.slides[s].objects.indices { mine.slides[s].objects[o].chords = nil }
        }
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let decided = ChordEdits.lines(of: result.presentation).filter { $0.text.contains("decided") }
        #expect(decided.count == 2)
        #expect(decided.map { ChordEdits.chords(at: $0, in: result.presentation).map(\.symbol) } == [["1", "4"], ["6m", "5"]])
    }

    /// "of [1sus]Jesus [1]" ends a chart line; the song runs it on into
    /// "Over every heart". The 1 stays after "Jesus", not over "Over".
    @Test func aChordEndingAChartLineStaysBeforeTheNextWords() throws {
        let chart = try song("""
        Verse 1
        Speak the name of [1sus]Jesus [1]
        [6m7]Over every heart
        """)
        var mine = chart
        let first = try line(mine, "Speak the name of Jesus")
        let slide = try #require(mine.slides.firstIndex { $0.id == first.slideID })
        let object = try #require(mine.slides[slide].objects.firstIndex { $0.id == first.objectID })
        mine.slides[slide].objects[object].text = "Speak the name of Jesus Over every heart"
        mine.slides[slide].objects[object].chords = nil
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let joined = try line(result.presentation, "Speak the name of Jesus Over every heart")
        let placed = ChordEdits.chords(at: joined, in: result.presentation)
        #expect(placed.map(\.symbol) == ["1sus", "1", "6m7"])
        let over = "Speak the name of Jesus ".count
        #expect(placed[1].column < over)
        #expect(placed[2].column == over)
    }

    /// Chords as charts write them: in parentheses ("(4)", "(1sus … 1)"),
    /// with their own parentheses ("2m7(4)"), and after a bracket left open.
    @Test func chartChordsInParenthesesAndOpenBracketsAreKept() throws {
        let chart = try song("""
        Chorus
        You [6m]turned me [2m7(4)]around
        Halle[1]lu [5(4)]- jah[(4)]
        Your name is [1]life [(1sus] [1)]

        Outro
        [1] [1/3 [4] [5/7] [1]
        """)
        let lines = ChordEdits.lines(of: chart)
        func symbols(_ words: String) -> [String] {
            lines.first { ShepherdChordMatch.normalized($0.text) == ShepherdChordMatch.normalized(words) }
                .map { ChordEdits.chords(at: $0, in: chart).map(\.symbol) } ?? []
        }
        #expect(symbols("You turned me around") == ["6m", "2m7(4)"])
        #expect(symbols("Hallelujah") == ["1", "5(4)", "(4)"])
        #expect(symbols("Your name is life") == ["1", "(1sus", "1)"])
        let outro = chart.slides.compactMap { ChordEdits.lyricObject(of: $0) }
            .first { ShepherdChordMatch.normalized($0.text).isEmpty && ($0.chords?.count ?? 0) == 5 }
        #expect(outro?.chords?.map(\.symbol) == ["1", "1/3", "4", "5/7", "1"])
        #expect(ChordMath.display("(Gb)", musicKey: "Db", displayKey: nil, notation: .numbers) == "(4)")
        #expect(ChordMath.display("Ebm7(4)", musicKey: "Db", displayKey: nil, notation: .numbers) == "2m7(4)")
        #expect(ChordMath.display("Gbma9", musicKey: "Db", displayKey: nil, notation: .numbers) == "4ma9")
    }

    /// Screens' "Chorus 1" is the chart's Chorus and Post-Chorus: a chorus
    /// line sharing only "You" and "me" with the post-chorus still gets the
    /// chorus's chords.
    @Test func aLineSharingAFewWordsWithAnotherPartIsntItsLine() throws {
        let chart = try song("""
        Chorus
        [4]Thank You [1]Jesus [6m]You have [5sus]set me free

        Post-Chorus
        [4]Hallelujah it [5]really is
        You [1]welcomed me in and You [5]gave me peace
        """)
        var mine = chart
        // One section holding both parts' words.
        mine.sections = [PresentationSection(id: "c1", name: "Chorus 1")]
        for s in mine.slides.indices { mine.slides[s].sectionId = "c1" }
        for s in mine.slides.indices { for o in mine.slides[s].objects.indices { mine.slides[s].objects[o].chords = nil } }
        let result = ShepherdChordMatch.matching(mine, to: chart)
        let thank = try line(result.presentation, "Thank You Jesus You have set me free")
        #expect(ChordEdits.chords(at: thank, in: result.presentation).map(\.symbol) == ["4", "1", "6m", "5sus"])
    }
}
