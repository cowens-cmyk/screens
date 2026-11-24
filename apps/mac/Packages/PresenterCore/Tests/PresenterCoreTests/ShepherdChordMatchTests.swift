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
}
