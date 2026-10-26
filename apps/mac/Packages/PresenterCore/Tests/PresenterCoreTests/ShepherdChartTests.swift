import Foundation
import Testing
@testable import PresenterCore

// "I Thank God" as the church's Shepherd returns it: bare headings repeat
// earlier sections, performance notes ride on headings, and words are split
// where a chord lands ("vaga - [C]bond").
let iThankGodChart = """
Intro (2x)
[C] [/] [/] [/] [|] [F] [/] [C] [/]

Verse 1
[C]Wond'ring into the night, wanting a place to hide
This weary [F]soul, this bag of [C]bones
And I'm a vag - a - [C]bond, ever - y step was wrong

Pre-Chorus
And [G]just when I ran [Am]out of the road
You [F]found me, I'm Yours, For - [C/E]ever

Chorus 1
You [C]picked me up, You [Dm]turned me around
You [F]placed my feet on [C]solid ground

Intro (1x)

Verse 2
[C]Now I'm alive and I'm free
[F]Living in Your victory, (Hallelujah)

Chorus


Bridge 1 (2x) (Girl lead)
[C]Hell lost another one, I am free, I am free
[Am]Hell lost another one, "I am free!"

Vamp 1
[F]I thank God, [C]I thank God
"""

private func song(
    chart: String? = iThankGodChart, lyrics: String? = nil, sequence: [String] = [],
    arrangementChart: String? = nil, writtenKey: String? = "C"
) -> ShepherdClient.SongDetail {
    ShepherdClient.SongDetail(
        id: "f39a", title: "I Thank God", ccliNumber: "7169680", defaultKey: "C",
        arrangements: [ShepherdClient.SongArrangement(
            id: "53ad", name: "Default", lengthSeconds: 360, sequence: sequence, chordChart: arrangementChart)],
        lyrics: lyrics, chordChart: chart, originalKey: "C", defaultArrangementId: "53ad",
        chart: ShepherdClient.ChartInfo(format: "ChordPro", hasChart: chart != nil, writtenKey: writtenKey))
}

@Suite struct ShepherdChartTests {

    @Test func sectionsComeOnceAndBareHeadingsRepeatThem() {
        let chart = ShepherdChart.parse(iThankGodChart)
        #expect(chart.sections.map(\.name) == ["Intro", "Verse 1", "Pre-Chorus", "Chorus 1", "Verse 2", "Bridge 1", "Vamp 1"])
        let names = chart.order.map { chart.sections[$0].name }
        #expect(names == ["Intro", "Verse 1", "Pre-Chorus", "Chorus 1", "Intro", "Verse 2", "Chorus 1", "Bridge 1", "Vamp 1"])
    }

    @Test func headingNotesComeOffTheName() throws {
        let chart = ShepherdChart.parse(iThankGodChart)
        let bridge = try #require(chart.sections.first { $0.name == "Bridge 1" })
        #expect(bridge.repeatCount == 2)
        #expect(bridge.notes == ["Girl lead"])
        #expect(chart.sections.first?.repeatCount == 2)
    }

    @Test func headingRecognition() {
        #expect(ShepherdChart.heading(of: "Pre-Chorus 2")?.name == "Pre-Chorus 2")
        #expect(ShepherdChart.heading(of: "Intro (1x)")?.name == "Intro")
        #expect(ShepherdChart.heading(of: "Intro (1x)")?.repeatCount == 1)
        #expect(ShepherdChart.heading(of: "VERSE 1")?.name == "Verse 1")
        #expect(ShepherdChart.heading(of: "Chorus x2")?.repeatCount == 2)
        #expect(ShepherdChart.heading(of: "[Bridge]")?.name == "Bridge")
        #expect(ShepherdChart.heading(of: "Tag:")?.name == "Tag")
        for name in ["Turnaround", "Outro", "Instrumental", "Interlude", "Ending", "Vamp 2"] {
            #expect(ShepherdChart.heading(of: name)?.name == name)
        }
        #expect(ShepherdChart.heading(of: "Ending Tag")?.name == "Ending Tag")
        #expect(ShepherdChart.heading(of: "Final Chorus")?.name == "Final Chorus")
        // Sung lines stay lyrics.
        #expect(ShepherdChart.heading(of: "Holy (Holy)") == nil)
        #expect(ShepherdChart.heading(of: "Hallelujah (2x)") == nil)
        #expect(ShepherdChart.heading(of: "[C]Chorus of angels") == nil)
        #expect(ShepherdChart.heading(of: "You are good, You are good") == nil)
    }

    @Test func crlfAndEmptyCharts() {
        let crlf = ShepherdChart.parse(iThankGodChart.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(crlf == ShepherdChart.parse(iThankGodChart))
        #expect(ShepherdChart.parse("").sections.isEmpty)
        #expect(ShepherdChart.parse("\n\n  \n").order.isEmpty)
    }

    @Test func chordOnlySectionsHaveNoLyrics() throws {
        let chart = ShepherdChart.parse(iThankGodChart)
        #expect(chart.sections[0].hasLyrics == false)
        #expect(chart.sections[1].hasLyrics)
        #expect(chart.cleanedStanzas(chart.sections[0]).isEmpty)
    }

    @Test func syllableSplitsJoinWithChordsOnTheRightLetter() throws {
        let chart = ShepherdChart.parse(iThankGodChart)
        let verse = chart.cleanedStanzas(chart.sections[1]).joined()
        #expect(verse.contains("And I'm a vaga[C]bond every step was wrong"))
        let pre = chart.cleanedStanzas(chart.sections[2]).joined()
        #expect(pre.contains("You [F]found me I'm Yours For[C/E]ever"))
        let lyrics = chart.lyrics()
        #expect(lyrics.contains("And I'm a vagabond every step was wrong"))
        #expect(lyrics.contains("You found me I'm Yours Forever"))
        #expect(!lyrics.contains("["))
    }

    @Test func punctuationCanStay() {
        let chart = ShepherdChart.parse(iThankGodChart)
        let lyrics = chart.lyrics(removePunctuation: false)
        #expect(lyrics.contains("You found me, I'm Yours, Forever"))
        #expect(lyrics.contains("Wond'ring into the night, wanting a place to hide"))
    }

    @Test func noHeadingsMakesVerses() {
        let chart = ShepherdChart.parse("[G]Amazing grace how [C]sweet\n\n[G]Twas grace that [D]taught")
        #expect(chart.sections.map(\.name) == ["Verse 1", "Verse 2"])
        #expect(chart.order == [0, 1])
    }

    @Test func chordProDirectives() {
        let text = """
        {title: Living Hope}
        {artist: Phil Wickham}
        {key: Bb}
        {start_of_verse: Verse 1}
        How [Bb]great the chasm
        {end_of_verse}
        {soc}
        Hal[Eb]lelujah praise the One
        {eoc}
        {chorus}
        {c: Tag}
        [Bb]Jesus Yours is the victory
        """
        let chart = ShepherdChart.parse(text)
        #expect(chart.title == "Living Hope" && chart.artist == "Phil Wickham" && chart.key == "Bb")
        #expect(chart.sections.map(\.name) == ["Verse 1", "Chorus", "Tag"])
        #expect(chart.order == [0, 1, 1, 2])
    }

    @Test func titleLinesAboveTheFirstHeadingArentLyrics() {
        let chart = ShepherdChart.parse("I Thank God\nMaverick City Music\n\nVerse 1\n[C]Wond'ring into the night")
        #expect(chart.sections.map(\.name) == ["Verse 1"])
        #expect(chart.title == "I Thank God")
    }

    @Test func chordsOverLyricsChartsAreReadToo() {
        let text = """
        Verse 1
        G          C
        Amazing grace how sweet the sound

        Chorus
        D         G
        My chains are gone
        """
        let chart = ShepherdChart.parse(text)
        #expect(chart.sections.map(\.name) == ["Verse 1", "Chorus"])
        #expect(chart.sections[0].stanzas.joined().first?.hasPrefix("[G]Amazing") == true)
    }

    @Test func sameNameNewWordsGetsItsOwnSection() {
        let chart = ShepherdChart.parse("Chorus\n[C]One way\n\nChorus\n[C]Another way\n\nChorus")
        #expect(chart.sections.map(\.name) == ["Chorus", "Chorus 2"])
        #expect(chart.order == [0, 1, 0])
    }

    @Test func sequencesMatchBySectionKind() {
        let chart = ShepherdChart.parse(iThankGodChart)
        let order = chart.order(for: ["Verse 1", "Chorus", "V2", "C", "Bridge", "Tag"])
        #expect(order?.map { chart.sections[$0].name } == ["Verse 1", "Chorus 1", "Verse 2", "Chorus 1", "Bridge 1"])
        #expect(chart.order(for: ["Nothing"]) == nil)
    }

    @Test func markersAndSlashChords() {
        #expect(LyricCleanup.cleanLine("[N.C.] [x] [C/E] [/] [|]", chart: true) == nil)
        #expect(LyricCleanup.cleanLine("[N.C.]Holy [G/B]is the Lord", chart: true) == "Holy [G/B]is the Lord")
    }
}

@Suite struct ShepherdSongImportTests {

    private func texts(_ presentation: Presentation) -> [String] {
        presentation.slides.flatMap { $0.objects.filter { $0.objectKind == .text }.map(\.text) }
    }

    private func orderNames(_ presentation: Presentation) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        let arrangement = presentation.arrangements?.first { $0.id == presentation.defaultArrangementId }
        return arrangement?.sectionIds.compactMap { names[$0] } ?? []
    }

    @Test func buildsSlidesChordsAndOrderFromTheChart() throws {
        let presentation = try #require(ShepherdSongImport.presentation(song: song(), arrangement: song().arrangements.first))
        #expect(presentation.presentationKind == .song)
        #expect(presentation.name == "I Thank God")
        #expect(presentation.musicKey == "C")
        #expect(presentation.ccli?.songNumber == 7169680)
        #expect(presentation.shepherdSongId == "f39a" && presentation.shepherdArrangementId == "53ad")
        #expect(orderNames(presentation) == [
            "Intro", "Verse 1", "Pre-Chorus", "Chorus 1", "Intro", "Verse 2", "Chorus 1", "Bridge 1", "Vamp 1"])
        let all = texts(presentation)
        #expect(all.contains("Wond'ring into the night wanting a place to hide\nThis weary soul this bag of bones"))
        #expect(all.contains("Now I'm alive and I'm free\nLiving in Your victory Hallelujah"))
        #expect(all.contains("Hell lost another one I am free I am free\nHell lost another one I am free"))
        #expect(!all.joined().contains("/"))
        let verse = try #require(presentation.slides.first { $0.objects.first?.text.hasPrefix("Wond'ring") == true })
        #expect(verse.objects.first?.chords?.map(\.symbol) == ["C", "F", "C"])
        // The intro has no words: one blank slide.
        let intro = try #require(presentation.sections?.first)
        #expect(intro.name == "Intro")
        #expect(presentation.slides.filter { $0.sectionId == intro.id }.map(\.objects.isEmpty) == [true])
    }

    @Test func linesPerSlideAndKeys() throws {
        let options = ShepherdSongImport.Options(linesPerSlide: 1, playingKey: "D")
        let presentation = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil, options: options))
        #expect(texts(presentation).contains("This weary soul this bag of bones"))
        #expect(presentation.displayKey == "D")
        #expect(presentation.shepherdArrangementId == nil)
    }

    @Test func arrangementSequenceLeadsTheOrder() throws {
        let planned = song(sequence: ["Verse 1", "Chorus", "Bridge", "Chorus"])
        let presentation = try #require(ShepherdSongImport.presentation(song: planned, arrangement: planned.arrangements.first))
        #expect(orderNames(presentation) == ["Intro", "Verse 1", "Chorus 1", "Bridge 1", "Chorus 1"])
    }

    @Test func arrangementChartWinsAndLyricsFillAChordOnlyChart() throws {
        let own = song(arrangementChart: "Verse 1\n[D]Only this arrangement")
        let fromArrangement = try #require(ShepherdSongImport.presentation(song: own, arrangement: own.arrangements.first))
        #expect(texts(fromArrangement).contains("Only this arrangement"))

        let lyricsOnly = song(chart: nil, lyrics: "Verse 1\nWond'ring into the night, wanting a place to hide\n\nChorus\nYou picked me up!")
        let fromLyrics = try #require(ShepherdSongImport.presentation(song: lyricsOnly, arrangement: nil))
        #expect(texts(fromLyrics).contains("Wond'ring into the night wanting a place to hide"))
        #expect(fromLyrics.chordProSource == nil)

        let chordsOnly = song(chart: "Intro\n[C] [/] [F] [/]", lyrics: "Verse 1\nHello there")
        #expect(ShepherdSongImport.presentation(song: chordsOnly, arrangement: nil).map(texts)?.contains("Hello there") == true)
        #expect(ShepherdSongImport.presentation(song: song(chart: nil, lyrics: nil), arrangement: nil) == nil)
        #expect(ShepherdSongImport.presentation(song: song(chart: "  \n"), arrangement: nil) == nil)
    }

    @Test func sameChartSameHashSoReSyncIsANoOp() throws {
        let a = ShepherdSongImport.chartHash(song: song(), arrangement: nil)
        let crlf = ShepherdSongImport.chartHash(
            song: song(chart: iThankGodChart.replacingOccurrences(of: "\n", with: "\r\n")), arrangement: nil)
        #expect(a == crlf)
        #expect(a != ShepherdSongImport.chartHash(song: song(chart: iThankGodChart + "\n\nTag\n[C]Thank God"), arrangement: nil))
        #expect(a != ShepherdSongImport.chartHash(song: song(sequence: ["Verse 1"]), arrangement: song(sequence: ["Verse 1"]).arrangements.first))

        let imported = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        #expect(ShepherdSongImport.decision(for: imported, chartHash: a) == .upToDate)
    }

    @Test func changedChartUpdatesAnUneditedSongAndKeepsWhatScreensOwns() throws {
        var imported = try #require(ShepherdSongImport.presentation(song: song(), arrangement: song().arrangements.first))
        imported.themeId = "theme-1"
        imported.displayKey = "D"
        imported.slides[1].background = CueMedia(mediaId: "bg")
        let anthem = Arrangement(id: "anthem", name: "Anthem", sectionIds: Array((imported.sections ?? []).prefix(2).map(\.id)))
        imported.arrangements?.append(anthem)
        let newer = song(chart: iThankGodChart.replacingOccurrences(of: "solid ground", with: "higher ground") + "\n\nTag\n[C]Thank God")
        let hash = ShepherdSongImport.chartHash(song: newer, arrangement: newer.arrangements.first)
        #expect(ShepherdSongImport.decision(for: imported, chartHash: hash) == .update)

        let fresh = try #require(ShepherdSongImport.presentation(song: newer, arrangement: newer.arrangements.first))
        #expect(ShepherdSongImport.changeSummary(from: imported, to: fresh) == "Chorus 1 changed, Tag added")
        let updated = ShepherdSongImport.replacing(imported, with: fresh)
        #expect(updated.id == imported.id && updated.themeId == "theme-1" && updated.displayKey == "D")
        #expect(texts(updated).contains { $0.contains("higher ground") })
        #expect(updated.slides[1].background?.mediaId == "bg")
        // Sections kept their ids, so Anthem's arrangement still points at them.
        #expect(updated.arrangements?.first { $0.id == "anthem" }?.sectionIds == anthem.sectionIds)
        #expect(updated.shepherdChartHash == hash)
        #expect(ShepherdSongImport.decision(for: updated, chartHash: hash) == .upToDate)
        #expect(Set(updated.slides.compactMap(\.sectionId)).isSubset(of: Set((updated.sections ?? []).map(\.id))))
    }

    @Test func anEditedSongIsLeftAlone() throws {
        var edited = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        let index = try #require(edited.slides.firstIndex { !$0.objects.isEmpty })
        edited.slides[index].objects[0].text += " (our fix)"
        let hash = ShepherdSongImport.chartHash(song: song(chart: iThankGodChart + "\n\nTag\n[C]Thank God"), arrangement: nil)
        #expect(ShepherdSongImport.decision(for: edited, chartHash: hash) == .edited)

        // A new song order in Screens is an edit too; a theme or key is not.
        var reordered = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        reordered.arrangements?[0].sectionIds.reverse()
        #expect(ShepherdSongImport.decision(for: reordered, chartHash: hash) == .edited)
        var rekeyed = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        rekeyed.musicKey = "D"
        #expect(ShepherdSongImport.decision(for: rekeyed, chartHash: hash) == .edited)
        var restyled = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        restyled.themeId = "other"
        restyled.displayKey = "E"
        restyled.arrangements?.append(Arrangement(id: "anthem", name: "Anthem", sectionIds: []))
        #expect(ShepherdSongImport.decision(for: restyled, chartHash: hash) == .update)
    }

    @Test func anotherPlanArrangementIsAdded() throws {
        let imported = try #require(ShepherdSongImport.presentation(song: song(), arrangement: nil))
        let short = ShepherdClient.SongArrangement(id: "short", name: "Short", sequence: ["V1", "C"])
        let outcome = ShepherdArrangementSync.reconcile(imported, song: song(), arrangement: short)
        let extra = try #require(outcome.arrangements?.first { $0.id == outcome.arrangementId })
        let names = Dictionary(uniqueKeysWithValues: (imported.sections ?? []).map { ($0.id, $0.name) })
        #expect(extra.id == "shepherd-short" && extra.name == "Short" && extra.shepherdArrangementId == "short")
        #expect(extra.sectionIds.compactMap { names[$0] } == ["Intro", "Verse 1", "Chorus 1"])
        // The import's own arrangement is tagged and left to the chart refresh.
        #expect(imported.arrangements?.first?.shepherdArrangementId == "song")
        let planned = song(sequence: ["V1", "C"])
        let tracked = try #require(ShepherdSongImport.presentation(song: planned, arrangement: planned.arrangements[0]))
        #expect(tracked.arrangements?.first?.shepherdArrangementId == "53ad")
        let own = ShepherdArrangementSync.reconcile(tracked, song: planned, arrangement: planned.arrangements[0])
        #expect(own.arrangements == nil && own.arrangementId == "shepherd-53ad")
    }

    @Test func decodesTheSongShepherdSends() throws {
        let json = """
        {"id":"f39a","title":"I Thank God","ccli_number":"7169680","default_key":"C","original_key":"C",
         "chord_chart":"Verse 1\\n[C]Wond'ring into the night",
         "chart":{"format":"ChordPro","has_chart":true,"written_key":"C","arrangements_with_charts":[],"key_charts":[]},
         "lyrics":null,
         "arrangements":[{"id":"53ad","name":"Default","chord_chart":null,"sequence":[],"length_seconds":360,"tempo":null,"time_signature":null}],
         "default_arrangement_id":"53ad","sequence":[],"keys":[{"key":"C","description":"Original"}],"copyright":null}
        """
        let decoded = try ShepherdClient.decoder().decode(ShepherdClient.SongDetail.self, from: Data(json.utf8))
        #expect(decoded.chart?.writtenKey == "C" && decoded.defaultArrangementId == "53ad")
        #expect(decoded.arrangements.first?.mediaLinks == [] && decoded.themes.isEmpty && !decoded.archived)
        #expect(ShepherdSongImport.presentation(song: decoded, arrangement: decoded.arrangements.first) != nil)
    }
}
