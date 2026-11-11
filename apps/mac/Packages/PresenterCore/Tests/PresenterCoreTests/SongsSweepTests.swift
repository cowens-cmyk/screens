import Foundation
import Testing
@testable import PresenterCore

/// Songs: import order, section edits, hand edits to Shepherd's order,
/// updates, Reflow, Quick Edit and SongSelect downloads.
@Suite struct SongsSweepTests {

    private func shepherdSong(sequence: [String], chart: String = iThankGodChart) -> ShepherdClient.SongDetail {
        ShepherdClient.SongDetail(
            id: "f39a", title: "I Thank God", ccliNumber: "7169680", defaultKey: "C",
            arrangements: [ShepherdClient.SongArrangement(id: "53ad", name: "Default", sequence: sequence)],
            chordChart: chart, originalKey: "C", defaultArrangementId: "53ad",
            chart: ShepherdClient.ChartInfo(format: "ChordPro", hasChart: true, writtenKey: "C"))
    }

    private func orderNames(_ presentation: Presentation, arrangement id: String? = nil) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        let arrangement = presentation.arrangements?.first { $0.id == (id ?? presentation.defaultArrangementId) }
        return arrangement?.sectionIds.compactMap { names[$0] } ?? []
    }

    // MARK: Import order (songs-1)

    @Test func importReadsRepeatsAndShortNamesAsSyncDoes() throws {
        let planned = shepherdSong(sequence: ["Intro", "V1", "PreChorus", "C", "V2", "C (2x)", "B", "Chorus x2"])
        let song = try #require(ShepherdSongImport.presentation(song: planned, arrangement: planned.arrangements.first))
        #expect(orderNames(song) == [
            "Intro", "Verse 1", "Pre-Chorus", "Chorus 1", "Verse 2", "Chorus 1", "Chorus 1", "Bridge 1",
            "Chorus 1", "Chorus 1",
        ])
        let short = shepherdSong(sequence: ["V1", "Ch", "Br", "Vs 2", "Ch"])
        let fromShort = try #require(ShepherdSongImport.presentation(song: short, arrangement: short.arrangements.first))
        #expect(orderNames(fromShort) == ["Intro", "Verse 1", "Chorus 1", "Bridge 1", "Verse 2", "Chorus 1"])
    }

    @Test func aVerseTheChartLacksIsNotVerseOne() throws {
        let planned = shepherdSong(sequence: ["V1", "C", "V3", "C"])
        let song = try #require(ShepherdSongImport.presentation(song: planned, arrangement: planned.arrangements.first))
        #expect(orderNames(song) == ["Intro", "Verse 1", "Chorus 1", "Chorus 1"])
        // Sync reports it rather than showing the wrong words.
        let outcome = ShepherdArrangementSync.reconcile(song, song: planned, arrangement: planned.arrangements.first)
        #expect(outcome.warnings == [ShepherdArrangementSync.warning(missing: "Verse 3")])
    }

    // MARK: Section split and delete (songs-2)

    private func threeSectionSong() -> Presentation {
        let sections = ["Verse", "Chorus", "Bridge"].map { PresentationSection(id: $0.lowercased(), name: $0) }
        var slides: [Slide] = []
        for section in sections {
            for n in 1...2 {
                slides.append(Slide(id: "\(section.id)\(n)", name: "", objects: [
                    SlideObject(id: "t\(section.id)\(n)", objectKind: .text, name: "", text: "\(section.name) \(n)"),
                ], sectionId: section.id))
            }
        }
        return Presentation(
            id: "song", name: "Song", presentationKind: .song, themeId: "", slides: slides, sections: sections,
            arrangements: [
                Arrangement(id: "full", name: "Full", sectionIds: ["verse", "chorus", "bridge", "chorus"]),
                Arrangement(id: "sync", name: "Default", sectionIds: ["verse", "chorus"], shepherdArrangementId: "a1"),
            ],
            defaultArrangementId: "full")
    }

    private func played(_ song: Presentation, _ arrangement: String) -> [String] {
        let order = song.arrangements?.first { $0.id == arrangement }?.sectionIds ?? []
        return order.flatMap { id in song.slides.filter { $0.sectionId == id }.map(\.id) }
    }

    @Test func aNewSectionIsSungWhereItsSlidesWere() {
        var song = threeSectionSong()
        let before = played(song, "full")
        SongSections.split(&song, at: 3, into: PresentationSection(id: "chorus2", name: "Chorus 2"))
        #expect(song.slides[3].sectionId == "chorus2" && song.slides[2].sectionId == "chorus")
        #expect(played(song, "full") == before)
        #expect(song.arrangements?.first { $0.id == "full" }?.sectionIds
            == ["verse", "chorus", "chorus2", "bridge", "chorus", "chorus2"])
        // Sync's order is now the operator's, so the next sync leaves it.
        #expect(song.arrangements?.first { $0.id == "sync" }?.shepherdArrangementId
            == ShepherdArrangementSync.editedTag("a1"))
    }

    @Test func aDeletedSectionsSlidesJoinTheOneAbove() {
        var song = threeSectionSong()
        SongSections.delete(&song, sectionId: "bridge")
        #expect(song.slides.filter { $0.sectionId == nil }.isEmpty)
        #expect(song.slides.filter { $0.sectionId == "chorus" }.map(\.id) == ["chorus1", "chorus2", "bridge1", "bridge2"])
        #expect(song.arrangements?.first { $0.id == "full" }?.sectionIds == ["verse", "chorus", "chorus"])
        // Every slide still plays.
        #expect(Set(played(song, "full")) == Set(song.slides.map(\.id)))

        // The first section joins the one below; an order without that one
        // sings it in the deleted one's place.
        var first = threeSectionSong()
        first.arrangements = [Arrangement(id: "short", name: "Short", sectionIds: ["verse", "bridge"])]
        SongSections.delete(&first, sectionId: "verse")
        #expect(first.slides.prefix(2).allSatisfy { $0.sectionId == "chorus" })
        #expect(first.arrangements?.first?.sectionIds == ["chorus", "bridge"])
    }

    // MARK: Hand edits to Shepherd's order (songs-3)

    @Test func anOrderEditedByHandIsNotPutBack() throws {
        let sections = ["Verse 1", "Chorus", "Bridge"].enumerated().map {
            PresentationSection(id: "s\($0.offset)", name: $0.element)
        }
        let slides = sections.map { section in
            Slide(id: "slide-" + section.id, name: "", objects: [
                SlideObject(id: "t-" + section.id, objectKind: .text, name: "", text: section.name),
            ], sectionId: section.id)
        }
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["V1", "C"])
        let detail = ShepherdClient.SongDetail(id: "song-1", title: "Living Hope", arrangements: [shepherd])
        var song = Presentation(
            id: "library", name: "Living Hope", presentationKind: .song, themeId: "", slides: slides,
            sections: sections)
        let first = ShepherdArrangementSync.reconcile(song, song: detail, arrangement: shepherd)
        song.arrangements = try #require(first.arrangements)
        let synced = try #require(song.arrangements?.first { $0.id == first.arrangementId })

        // The operator adds a final chorus.
        var edited = synced
        edited.sectionIds += ["s1"]
        edited = ShepherdArrangementSync.editedByHand(edited, before: synced)
        #expect(edited.shepherdArrangementId == ShepherdArrangementSync.editedTag("a1"))
        song.arrangements = [edited]

        let again = ShepherdArrangementSync.reconcile(song, song: detail, arrangement: shepherd)
        #expect(again.arrangements == nil, "nothing rewritten")
        #expect(again.arrangementId == edited.id, "the plan still plays it")
        #expect(ShepherdArrangementSync.pick(
            current: edited.id, lastSynced: edited.id, target: again.arrangementId, defaultId: nil,
            available: [edited.id], anthemLeads: false) == nil)

        // A change that changes nothing, or to an order sync didn't make, isn't marked.
        #expect(ShepherdArrangementSync.editedByHand(synced, before: synced) == synced)
        let mine = Arrangement(id: "mine", name: "Mine", sectionIds: ["s0"])
        var mineAfter = mine
        mineAfter.sectionIds = ["s1"]
        #expect(ShepherdArrangementSync.editedByHand(mineAfter, before: mine).shepherdArrangementId == nil)
    }

    // MARK: Updates keep slide ids (songs-4)

    @Test func anUpdateKeepsTheSlideIDsInPlace() throws {
        let planned = shepherdSong(sequence: ["V1", "C"])
        let imported = try #require(ShepherdSongImport.presentation(song: planned, arrangement: planned.arrangements.first))
        let newer = shepherdSong(
            sequence: ["V1", "C"], chart: iThankGodChart.replacingOccurrences(of: "solid ground", with: "higher ground"))
        let fresh = try #require(ShepherdSongImport.presentation(song: newer, arrangement: newer.arrangements.first))
        let updated = ShepherdSongImport.replacing(imported, with: fresh)
        #expect(updated.slides.map(\.id) == imported.slides.map(\.id))
        #expect(Set(updated.slides.map(\.id)).count == updated.slides.count)
    }

    // MARK: Reflow (songs-5)

    @Test func reflowKeepsBlanksAndTheSongsOwnHeadings() throws {
        let chart = """
        Verse 1
        [C]Wond'ring into the night

        Instrumental
        [C] [/] [F] [/]

        Final Chorus
        You [C]picked me up
        """
        let planned = shepherdSong(sequence: [], chart: chart)
        let song = try #require(ShepherdSongImport.presentation(song: planned, arrangement: nil))
        #expect(song.sections?.map(\.name) == ["Intro", "Verse 1", "Instrumental", "Final Chorus"])
        let text = try #require(song.reflowSource)

        let parsed = Reflow.parse(text, linesPerSlide: 2, song: song)
        #expect(parsed.sections.map(\.name) == ["Intro", "Verse 1", "Instrumental", "Final Chorus"])
        #expect(parsed.sections[0].slides == [""] && parsed.sections[2].slides == [""])
        #expect(!parsed.sections.flatMap(\.slides).contains { $0.contains("Final Chorus") })

        var after = song
        Reflow.apply(Reflow.build(parsed), to: &after)
        #expect(orderNames(after) == orderNames(song))
        #expect(after.slides.count == song.slides.count)
    }

    // MARK: Quick Edit (songs-7)

    @Test func quickEditMovesChordsWithTheirWords() {
        var object = SlideObject(
            id: "t", objectKind: .text, name: "", text: "Amzing grace how sweet\nThat saved a wretch",
            chords: [
                ChordPlacement(line: 0, column: 0, symbol: "G"),
                ChordPlacement(line: 0, column: 13, symbol: "C"),
                ChordPlacement(line: 1, column: 5, symbol: "D"),
            ])
        object.replaceText(with: "Amazing grace how sweet\nThat saved a wretch")
        #expect(object.text == "Amazing grace how sweet\nThat saved a wretch")
        #expect(object.chords?.map { "\($0.symbol)@\($0.line):\($0.column)" } == ["G@0:0", "C@0:14", "D@1:5"])

        // A whole first line taken out: its chords go, the next line's move up.
        object.replaceText(with: "That saved a wretch")
        #expect(object.chords?.map { "\($0.symbol)@\($0.line):\($0.column)" } == ["D@0:5"])
    }

    // MARK: SongSelect downloads (songs-9)

    @Test func onlyTheSongAskedForIsTakenFromDownloads() {
        let songSelect = """
        Amazing Grace (My Chains Are Gone)

        Verse 1
        Amazing grace how sweet the sound

        CCLI Song # 4768151
        """
        #expect(LyricTextImporter.isSong(songSelect, fileName: "x.txt", title: "Amazing Grace", ccli: 4768151))
        #expect(LyricTextImporter.isSong(songSelect, fileName: "x.txt", title: "Amazing Grace", ccli: nil))
        #expect(!LyricTextImporter.isSong(songSelect, fileName: "x.txt", title: "Amazing Grace", ccli: 22025))
        let notes = "Sunday setlist\nWelcome\nAnnouncements"
        #expect(!LyricTextImporter.isSong(notes, fileName: "notes.txt", title: "Amazing Grace", ccli: 4768151))
        #expect(LyricTextImporter.isSong("Amazing grace how sweet", fileName: "amazing-grace.txt",
                                         title: "Amazing Grace (My Chains Are Gone)", ccli: nil))
    }
}
