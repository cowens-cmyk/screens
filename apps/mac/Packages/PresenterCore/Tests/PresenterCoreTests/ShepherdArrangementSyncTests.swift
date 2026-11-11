import Foundation
import Testing
@testable import PresenterCore

/// A library song that didn't come from Shepherd: sections named the way
/// ProPresenter or a hand-typed song names them.
private func librarySong(
    sections names: [String] = ["Verse 1", "Verse 2", "Chorus", "Pre Chorus", "Bridge"],
    arrangements: [Arrangement]? = nil, defaultArrangementId: String? = nil
) -> Presentation {
    let sections = names.enumerated().map { PresentationSection(id: "s\($0.offset)", name: $0.element) }
    let slides = sections.map { section in
        Slide(id: "slide-" + section.id, name: "", objects: [
            SlideObject(id: "t-" + section.id, objectKind: .text, name: "",
                        text: section.name == "Blank" ? "" : "Words of \(section.name)"),
        ], sectionId: section.id)
    }
    return Presentation(
        id: "library", name: "Living Hope", presentationKind: .song, themeId: "", slides: slides,
        sections: sections, arrangements: arrangements, defaultArrangementId: defaultArrangementId)
}

private func shepherdSong(_ arrangements: [ShepherdClient.SongArrangement]) -> ShepherdClient.SongDetail {
    ShepherdClient.SongDetail(
        id: "song-1", title: "Living Hope", ccliNumber: "7106807", arrangements: arrangements,
        defaultArrangementId: arrangements.first?.id)
}

private func names(_ ids: [String], in presentation: Presentation) -> [String] {
    let byID = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
    return ids.map { byID[$0] ?? "?" }
}

private func applying(_ outcome: ShepherdArrangementSync.Outcome, to presentation: Presentation) -> Presentation {
    var result = presentation
    if let arrangements = outcome.arrangements { result.arrangements = arrangements }
    return result
}

struct ShepherdArrangementSyncTests {

    // MARK: Names

    @Test func sectionNamesAreReadLoosely() throws {
        func label(_ name: String) -> ShepherdArrangementSync.SectionLabel? {
            ShepherdArrangementSync.label(name)?.label
        }
        let verse1 = ShepherdArrangementSync.SectionLabel(kind: "verse", number: "1")
        for name in ["V1", "Verse 1", "verse1", "VERSE  1", " Verse 01 ", "Vs 1"] {
            #expect(label(name) == verse1, "\(name)")
        }
        let preChorus = ShepherdArrangementSync.SectionLabel(kind: "prechorus")
        for name in ["Pre-Chorus", "PreChorus", "Pre Chorus", "PC", "pre-chorus"] {
            #expect(label(name) == preChorus, "\(name)")
        }
        #expect(label("Pre Chorus 2") == .init(kind: "prechorus", number: "2"))
        #expect(label("C") == .init(kind: "chorus"))
        #expect(label("C2") == .init(kind: "chorus", number: "2"))
        #expect(label("B") == .init(kind: "bridge"))
        #expect(label("Tag") == .init(kind: "tag"))
        #expect(label("TA") == .init(kind: "turnaround"))
        #expect(label("Turnaround") == .init(kind: "turnaround"))
        #expect(label("Inst") == .init(kind: "instrumental"))
        #expect(label("Interlude") == .init(kind: "interlude"))
        #expect(label("Outro") == .init(kind: "outro"))
        #expect(label("Ending") == .init(kind: "ending"))
        #expect(label("Verse 1b") == .init(kind: "verse", number: "1b"))
        #expect(label("") == nil && label("2") == nil)

        // Repeats and notes.
        #expect(ShepherdArrangementSync.label("Chorus (2x)")?.repeats == 2)
        #expect(ShepherdArrangementSync.label("Chorus x3")?.repeats == 3)
        #expect(ShepherdArrangementSync.label("Chorus ×2")?.label == .init(kind: "chorus"))
        let bridge = try #require(ShepherdArrangementSync.label("Bridge 1 (2x) (Girl lead)"))
        #expect(bridge.label == .init(kind: "bridge", number: "1") && bridge.repeats == 2)
        #expect(ShepherdArrangementSync.label("Intro (1x)")?.repeats == 1)
        #expect(ShepherdArrangementSync.label("Chorus 2")?.repeats == 1, "a number is not a repeat")

        #expect(label("V3")?.displayName == "Verse 3")
        #expect(label("PC")?.displayName == "Pre-Chorus")
        #expect(label("Vamp")?.displayName == "Vamp")
    }

    @Test func namesFindTheirSection() {
        func index(_ wanted: String, _ sections: [String]) -> Int? {
            let labels = sections.map { ShepherdArrangementSync.label($0)?.label }
            return ShepherdArrangementSync.label(wanted).flatMap {
                ShepherdArrangementSync.sectionIndex(for: $0.label, in: labels)
            }
        }
        #expect(index("Chorus", ["Verse 1", "Chorus 1", "Chorus 2"]) == 1, "unnumbered is the first of its kind")
        #expect(index("Chorus 2", ["Verse 1", "Chorus 1", "Chorus 2"]) == 2)
        #expect(index("Verse 1", ["Verse", "Chorus"]) == 0, "1 is the only unnumbered one")
        #expect(index("Chorus 2", ["Verse", "Chorus"]) == 1, "a later chorus is the song's one chorus")
        #expect(index("Verse 2", ["Verse", "Chorus"]) == nil, "a second verse has other words")
        #expect(index("Bridge 2", ["Bridge 1", "Chorus"]) == nil)
        #expect(index("Tag", ["Verse 1", "Chorus"]) == nil)
    }

    @Test func sequenceMapsOntoTheSongsSections() {
        let song = librarySong()
        let mapping = ShepherdArrangementSync.mapping(
            sequence: ["Intro", "V1", "PreChorus", "C", "V2", "C (2x)", "Instrumental", "B", "Verse 3", "Tag", "C"],
            onto: song)
        #expect(names(mapping.sectionIds, in: song) == [
            "Verse 1", "Pre Chorus", "Chorus", "Verse 2", "Chorus", "Chorus", "Bridge", "Chorus",
        ])
        #expect(mapping.missing == ["Verse 3", "Tag"], "wordless parts are skipped quietly")
        #expect(ShepherdArrangementSync.warning(missing: "Bridge 2")
            == "Shepherd's arrangement has Bridge 2; this song has no Bridge 2")

        // A song that opens on a blank keeps it first.
        let blank = librarySong(sections: ["Blank", "Verse 1", "Chorus"])
        #expect(names(ShepherdArrangementSync.mapping(sequence: ["V1", "C"], onto: blank).sectionIds, in: blank)
            == ["Blank", "Verse 1", "Chorus"])
        // An intro with words isn't a blank.
        let sungIntro = librarySong(sections: ["Intro", "Verse 1", "Chorus"])
        #expect(names(ShepherdArrangementSync.mapping(sequence: ["V1", "C"], onto: sungIntro).sectionIds, in: sungIntro)
            == ["Verse 1", "Chorus"])
    }

    // MARK: The song's arrangement

    @Test func aLibrarySongGetsShepherdsArrangement() throws {
        let short = ShepherdClient.SongArrangement(id: "a2", name: "Short", sequence: ["V1", "C", "B", "C"])
        let detail = shepherdSong([ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["V1"]), short])
        let song = librarySong()
        let outcome = ShepherdArrangementSync.reconcile(song, song: detail, arrangement: short)
        #expect(outcome.arrangementId == "shepherd-a2" && outcome.warnings.isEmpty)
        let made = try #require(outcome.arrangements?.first { $0.id == "shepherd-a2" })
        #expect(made.name == "Short" && made.shepherdArrangementId == "a2")
        #expect(names(made.sectionIds, in: song) == ["Verse 1", "Chorus", "Bridge", "Chorus"])

        // Another Mac, or the next sync, finds nothing to do.
        let after = applying(outcome, to: song)
        #expect(ShepherdArrangementSync.reconcile(after, song: detail, arrangement: short)
            == .init(arrangements: nil, arrangementId: "shepherd-a2"))
    }

    @Test func aHandMadeArrangementIsNeverOverwritten() throws {
        let handMade = Arrangement(id: "mine", name: "Default", sectionIds: ["s0", "s2"])
        let song = librarySong(arrangements: [handMade], defaultArrangementId: "mine")
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["V1", "C", "V2", "C"])
        let detail = shepherdSong([shepherd])
        let outcome = ShepherdArrangementSync.reconcile(song, song: detail, arrangement: shepherd)
        let arrangements = try #require(outcome.arrangements)
        #expect(arrangements.first == handMade)
        let made = try #require(arrangements.first { $0.id == outcome.arrangementId })
        #expect(made.name == "Default (Shepherd)")
        #expect(names(made.sectionIds, in: song) == ["Verse 1", "Chorus", "Verse 2", "Chorus"])

        // One already in Shepherd's order is used as it is.
        let same = Arrangement(id: "mine", name: "default", sectionIds: ["s0", "s2", "s1", "s2"])
        let matching = librarySong(arrangements: [same])
        #expect(ShepherdArrangementSync.reconcile(matching, song: detail, arrangement: shepherd)
            == .init(arrangements: nil, arrangementId: "mine"))

        // "(Shepherd)" taken by hand too: numbered.
        let both = librarySong(arrangements: [handMade, Arrangement(id: "x", name: "Default (Shepherd)", sectionIds: [])])
        let numbered = ShepherdArrangementSync.reconcile(both, song: detail, arrangement: shepherd)
        #expect(numbered.arrangements?.first { $0.id == numbered.arrangementId }?.name == "Default (Shepherd 2)")
    }

    @Test func syncsArrangementFollowsShepherd() throws {
        let handMade = Arrangement(id: "mine", name: "Default", sectionIds: ["s0"])
        var shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["V1", "C"])
        let first = ShepherdArrangementSync.reconcile(
            librarySong(arrangements: [handMade]), song: shepherdSong([shepherd]), arrangement: shepherd)
        let song = applying(first, to: librarySong(arrangements: [handMade]))

        // The sequence changes in Shepherd: sync's follows, the hand-made one doesn't.
        shepherd.sequence = ["V1", "C", "V2", "C", "B"]
        let changed = ShepherdArrangementSync.reconcile(song, song: shepherdSong([shepherd]), arrangement: shepherd)
        let arrangements = try #require(changed.arrangements)
        #expect(arrangements.first == handMade)
        let own = try #require(arrangements.first { $0.id == "shepherd-a1" })
        #expect(own.name == "Default (Shepherd)" && changed.arrangementId == "shepherd-a1")
        #expect(names(own.sectionIds, in: song) == ["Verse 1", "Chorus", "Verse 2", "Chorus", "Bridge"])

        // Renamed in Shepherd: renamed here.
        shepherd.name = "Full"
        let renamed = ShepherdArrangementSync.reconcile(
            applying(changed, to: song), song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(renamed.arrangements?.first { $0.id == "shepherd-a1" }?.name == "Full")

        // An arrangement an earlier sync made before the tag is adopted.
        let legacy = librarySong(arrangements: [Arrangement(id: "shepherd-a1", name: "Full", sectionIds: ["s0"])])
        let adopted = ShepherdArrangementSync.reconcile(legacy, song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(adopted.arrangements?.count == 1 && adopted.arrangements?.first?.shepherdArrangementId == "a1")

        // Two Macs added it at once: one copy stays.
        let doubled = librarySong(arrangements: [
            Arrangement(id: "shepherd-a1", name: "Full", sectionIds: ["s0", "s2"], shepherdArrangementId: "a1"),
            Arrangement(id: "shepherd-a1", name: "Full", sectionIds: ["s0", "s2"], shepherdArrangementId: "a1"),
        ])
        shepherd.sequence = ["V1", "C"]
        let deduped = ShepherdArrangementSync.reconcile(doubled, song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(deduped.arrangements?.count == 1)
    }

    @Test func missingSectionsAreSkippedAndNoted() {
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["V1", "C", "Bridge 2", "Tag", "Turnaround"])
        let song = librarySong(sections: ["Verse 1", "Chorus", "Bridge 1"])
        let outcome = ShepherdArrangementSync.reconcile(song, song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(outcome.arrangementId == "shepherd-a1")
        #expect(outcome.warnings == [
            "Shepherd's arrangement has Bridge 2; this song has no Bridge 2",
            "Shepherd's arrangement has Tag; this song has no Tag",
        ])

        // Nothing matches: no arrangement, the names are noted.
        let nothing = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: ["Tag"])
        let none = ShepherdArrangementSync.reconcile(song, song: shepherdSong([nothing]), arrangement: nothing)
        #expect(none.arrangements == nil && none.arrangementId == nil && none.warnings.count == 1)

        // No sections at all, or no order in Shepherd.
        var unsectioned = song
        unsectioned.sections = nil
        #expect(ShepherdArrangementSync.reconcile(unsectioned, song: shepherdSong([shepherd]), arrangement: shepherd)
            .warnings == ["Shepherd's arrangement can't be used: this song's slides aren't in sections"])
        let empty = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: [])
        #expect(ShepherdArrangementSync.reconcile(song, song: shepherdSong([empty]), arrangement: empty) == .init())
    }

    @Test func theSongsOwnSequenceWhenTheArrangementHasNone() throws {
        var detail = shepherdSong([ShepherdClient.SongArrangement(id: "a1", name: "Default")])
        detail.sequence = ["V1", "V2", "C"]
        let outcome = ShepherdArrangementSync.reconcile(librarySong(), song: detail, arrangement: detail.arrangements[0])
        let made = try #require(outcome.arrangements?.first)
        #expect(names(made.sectionIds, in: librarySong()) == ["Verse 1", "Verse 2", "Chorus"])
    }

    @Test func thePlanUsesTheDefaultArrangementWhenItNamesNone() {
        let detail = shepherdSong([
            ShepherdClient.SongArrangement(id: "a1", name: "Short"),
            ShepherdClient.SongArrangement(id: "a2", name: "Default"),
        ])
        var withDefault = detail
        withDefault.defaultArrangementId = "a2"
        #expect(ShepherdSongMatch.arrangement(in: withDefault, id: nil, name: nil)?.id == "a2")
        #expect(ShepherdSongMatch.arrangement(in: withDefault, id: "a1", name: nil)?.id == "a1")
    }

    // MARK: The item's pick

    @Test func thePickFollowsShepherdButNotOverAnOperator() {
        let all: Set<String> = ["default", "shepherd-a1", "shepherd-a2", "mine"]
        func pick(_ current: String?, _ synced: String?, _ target: String?, anthem: Bool = false)
            -> ShepherdArrangementSync.Pick? {
            ShepherdArrangementSync.pick(
                current: current, lastSynced: synced, target: target, defaultId: "default",
                available: all, anthemLeads: anthem)
        }
        // Never picked: Shepherd's.
        #expect(pick(nil, nil, "shepherd-a1") == .init(arrangementId: "shepherd-a1", syncedArrangementId: "shepherd-a1"))
        // Up to date: nothing to write.
        #expect(pick("shepherd-a1", "shepherd-a1", "shepherd-a1") == nil)
        // The plan moved to another Shepherd arrangement: the item follows.
        #expect(pick("shepherd-a1", "shepherd-a1", "shepherd-a2") == .init(arrangementId: "shepherd-a2", syncedArrangementId: "shepherd-a2"))
        // Someone picked another in Screens since: theirs stays.
        #expect(pick("mine", "shepherd-a1", "shepherd-a2") == nil)
        #expect(pick(nil, "shepherd-a1", "shepherd-a2") == nil, "back to the default by hand")
        // Picked by hand before sync ever set one: theirs stays.
        #expect(pick("mine", nil, "shepherd-a1") == nil)
        // A pick of a deleted arrangement is as good as none.
        #expect(pick("gone", "gone", "shepherd-a1")?.arrangementId == "shepherd-a1")
        // Already showing it as the default: only remembered.
        #expect(pick(nil, nil, "default") == .init(arrangementId: nil, syncedArrangementId: "default"))
        #expect(pick(nil, "default", "default") == nil)
        // Anthem leads, or nothing to pick: left alone.
        #expect(pick(nil, nil, "shepherd-a1", anthem: true) == nil)
        #expect(pick("shepherd-a1", "shepherd-a1", "shepherd-a2", anthem: true) == nil)
        #expect(pick(nil, nil, nil) == nil)
    }

    // MARK: Adding the parts a song lacks

    private let sequenceWithVamp = ["V1", "C", "Vamp", "C", "Bridge", "Outro", "Ending"]

    @Test func warningsReadBackToTheirNames() {
        for name in ["Vamp", "Bridge 2", "Pre-Chorus", "Outro"] {
            #expect(ShepherdArrangementSync.missingName(fromWarning: ShepherdArrangementSync.warning(missing: name)) == name)
        }
        #expect(ShepherdArrangementSync.missingName(
            fromWarning: "Shepherd's arrangement can't be used: this song's slides aren't in sections") == nil)
        #expect(ShepherdArrangementSync.missingName(fromWarning: "Text doesn't fit") == nil)
        #expect(ShepherdArrangementSync.missingName(fromWarning: "Shepherd's arrangement has Vamp; this song has no Outro") == nil)
    }

    @Test func onlyWordlessPartsTakeABlank() {
        let names = ["Vamp", "Outro", "Ending", "Breakdown", "Interlude", "Bridge 2", "Tag", "Verse 3", "Pre-Chorus", "Chorus 2", "Refrain", "Vamp"]
        #expect(ShepherdArrangementSync.blankFixableNames(in: names) == ["Vamp", "Outro", "Ending", "Breakdown", "Interlude"])
    }

    @Test func blankSectionsAreAddedAndNoLongerMissing() throws {
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: sequenceWithVamp)
        let song = librarySong(sections: ["Verse 1", "Chorus", "Bridge"])
        let outcome = ShepherdArrangementSync.reconcile(song, song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(outcome.warnings.compactMap(ShepherdArrangementSync.missingName(fromWarning:)) == ["Vamp", "Outro", "Ending"])
        let before = applying(outcome, to: song)

        let fix = ShepherdArrangementSync.addBlankSections(
            before, missing: ["Vamp", "Outro", "Ending"], sequence: sequenceWithVamp, arrangementId: "shepherd-a1",
            shepherdTag: "a1")
        #expect(fix.added == ["Vamp", "Outro", "Ending"] && fix.resolved == fix.added)
        let after = fix.presentation
        #expect(after.sections?.map(\.name) == ["Verse 1", "Chorus", "Bridge", "Vamp", "Outro", "Ending"])
        for name in fix.added {
            let section = try #require(after.sections?.first { $0.name == name })
            let slides = after.slides.filter { $0.sectionId == section.id }
            #expect(slides.count == 1)
            #expect(slides[0].objects.isEmpty && slides[0].name.isEmpty)
            #expect(slides[0].themeSlideName == "Lyrics" && slides[0].unthemed == nil)
        }
        #expect(after.slides.count == before.slides.count + 3)
        #expect(ShepherdArrangementSync.mapping(sequence: sequenceWithVamp, onto: after).missing.isEmpty)

        // Shepherd's order, with the new parts where it sings them.
        let order = try #require(after.arrangements?.first { $0.id == "shepherd-a1" })
        #expect(names(order.sectionIds, in: after) == ["Verse 1", "Chorus", "Vamp", "Chorus", "Bridge", "Outro", "Ending"])
        // The next sync finds nothing left to say, and the same order.
        let again = ShepherdArrangementSync.reconcile(after, song: shepherdSong([shepherd]), arrangement: shepherd)
        #expect(again.warnings.isEmpty)
        #expect(again.arrangements == nil || again.arrangements?.first { $0.id == "shepherd-a1" }?.sectionIds == order.sectionIds)
    }

    @Test func aSecondRunChangesNothing() {
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: sequenceWithVamp)
        let song = librarySong(sections: ["Verse 1", "Chorus", "Bridge"])
        let start = applying(ShepherdArrangementSync.reconcile(song, song: shepherdSong([shepherd]), arrangement: shepherd), to: song)
        let first = ShepherdArrangementSync.addBlankSections(
            start, missing: ["Vamp", "Outro", "Ending"], sequence: sequenceWithVamp, arrangementId: "shepherd-a1", shepherdTag: "a1")
        let second = ShepherdArrangementSync.addBlankSections(
            first.presentation, missing: ["Vamp", "Outro", "Ending"], sequence: sequenceWithVamp,
            arrangementId: "shepherd-a1", shepherdTag: "a1")
        #expect(second.presentation == first.presentation)
        #expect(second.added.isEmpty)
        #expect(second.resolved == ["Vamp", "Outro", "Ending"], "their warnings can still be cleared")
    }

    @Test func lyricPartsAreLeftForTheEditor() {
        let song = librarySong(sections: ["Verse 1", "Chorus"])
        let fix = ShepherdArrangementSync.addBlankSections(
            song, missing: ["Bridge 2", "Tag", "Verse 2", "Vamp"], sequence: ["V1", "C", "Bridge 2", "Tag", "V2", "Vamp"],
            arrangementId: nil)
        #expect(fix.added == ["Vamp"] && fix.resolved == ["Vamp"])
        #expect(fix.presentation.sections?.map(\.name) == ["Verse 1", "Chorus", "Vamp"])

        let none = ShepherdArrangementSync.addBlankSections(song, missing: ["Bridge 2", "Tag"], sequence: nil, arrangementId: nil)
        #expect(none.presentation == song && none.added.isEmpty && none.resolved.isEmpty)
    }

    @Test func aHandMadeArrangementOnlyGetsTheNewPartsOnItsEnd() throws {
        let mine = Arrangement(id: "mine", name: "Mine", sectionIds: ["s2", "s0", "s2"])
        let other = Arrangement(id: "other", name: "Other", sectionIds: ["s0"])
        let song = librarySong(
            sections: ["Verse 1", "Verse 2", "Chorus"], arrangements: [mine, other], defaultArrangementId: "other")
        let fix = ShepherdArrangementSync.addBlankSections(
            song, missing: ["Vamp", "Outro"], sequence: ["V1", "Vamp", "C", "Outro"], arrangementId: "mine")
        let after = fix.presentation
        let used = try #require(after.arrangements?.first { $0.id == "mine" })
        #expect(names(used.sectionIds, in: after) == ["Chorus", "Verse 1", "Chorus", "Vamp", "Outro"])
        #expect(after.arrangements?.first { $0.id == "other" } == other, "not the one in use: untouched")

        // No pick: the default is the one in use.
        let byDefault = ShepherdArrangementSync.addBlankSections(
            song, missing: ["Vamp"], sequence: nil, arrangementId: nil).presentation
        #expect(names(byDefault.arrangements?.first { $0.id == "other" }?.sectionIds ?? [], in: byDefault) == ["Verse 1", "Vamp"])
        #expect(byDefault.arrangements?.first { $0.id == "mine" } == mine)
    }

    @Test func withoutShepherdsOrderTheNewPartsGoOnTheEnd() throws {
        let shepherd = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: sequenceWithVamp)
        let song = librarySong(sections: ["Verse 1", "Chorus", "Bridge"])
        let start = applying(ShepherdArrangementSync.reconcile(song, song: shepherdSong([shepherd]), arrangement: shepherd), to: song)
        let fix = ShepherdArrangementSync.addBlankSections(
            start, missing: ["Ending", "Vamp"], sequence: nil, arrangementId: "shepherd-a1", shepherdTag: "a1")
        let order = try #require(fix.presentation.arrangements?.first { $0.id == "shepherd-a1" })
        #expect(names(order.sectionIds, in: fix.presentation) == ["Verse 1", "Chorus", "Chorus", "Bridge", "Ending", "Vamp"])

        // Shepherd can't be reached at all: the arrangement in use still gets them.
        let blind = ShepherdArrangementSync.addBlankSections(
            start, missing: ["Vamp"], sequence: nil, arrangementId: "shepherd-a1").presentation
        #expect(names(blind.arrangements?.first { $0.id == "shepherd-a1" }?.sectionIds ?? [], in: blind)
            == ["Verse 1", "Chorus", "Chorus", "Bridge", "Vamp"])
    }

    @Test func anOperatorsOrderInAShepherdArrangementIsNotReshuffled() throws {
        // The arrangement was changed by hand after sync: what is there stays
        // in its order, and the new part goes on the end.
        let tracked = Arrangement(
            id: "shepherd-a1", name: "Default", sectionIds: ["s2", "s0"], shepherdArrangementId: "a1")
        let song = librarySong(sections: ["Verse 1", "Chorus", "Bridge"], arrangements: [tracked], defaultArrangementId: "shepherd-a1")
        let fix = ShepherdArrangementSync.addBlankSections(
            song, missing: ["Vamp"], sequence: ["V1", "C", "Bridge", "Vamp"], arrangementId: "shepherd-a1", shepherdTag: "a1")
        let order = try #require(fix.presentation.arrangements?.first)
        #expect(names(order.sectionIds, in: fix.presentation) == ["Bridge", "Verse 1", "Vamp"])
    }

    @Test func aSongStillAsImportedKeepsFollowingShepherd() throws {
        let chart = "Verse 1\n[C]Amazing grace\n\nChorus\n[G]My chains are gone"
        let sequence = ["Verse 1", "Chorus", "Vamp", "Chorus", "Outro"]
        let arrangement = ShepherdClient.SongArrangement(id: "a1", name: "Default", sequence: sequence)
        let detail = ShepherdClient.SongDetail(
            id: "song-1", title: "Grace", arrangements: [arrangement], chordChart: chart, defaultArrangementId: "a1")
        let imported = try #require(ShepherdSongImport.presentation(song: detail, arrangement: arrangement))
        let hash = ShepherdSongImport.chartHash(song: detail, arrangement: arrangement)
        #expect(ShepherdSongImport.decision(for: imported, chartHash: hash) == .upToDate)

        let outcome = ShepherdArrangementSync.reconcile(imported, song: detail, arrangement: arrangement)
        #expect(outcome.warnings.compactMap(ShepherdArrangementSync.missingName(fromWarning:)) == ["Vamp", "Outro"])
        let fix = ShepherdArrangementSync.addBlankSections(
            imported, missing: ["Vamp", "Outro"], sequence: sequence, arrangementId: nil, shepherdTag: "a1")
        let after = fix.presentation
        #expect(names(after.arrangements?.first?.sectionIds ?? [], in: after) == ["Intro", "Verse 1", "Chorus", "Vamp", "Chorus", "Outro"], "it still opens on its blank")
        #expect(after.shepherdImportHash == ShepherdSongImport.fingerprint(after))
        #expect(after.shepherdImportHash != imported.shepherdImportHash)
        #expect(ShepherdArrangementSync.reconcile(after, song: detail, arrangement: arrangement).warnings.isEmpty)
        // A later change in Shepherd still updates it instead of asking.
        #expect(ShepherdSongImport.decision(for: after, chartHash: "newer") == .update)

        // A song edited by hand first stays "edited".
        var edited = imported
        edited.slides[1].objects[0].text += " changed"
        let kept = ShepherdArrangementSync.addBlankSections(
            edited, missing: ["Vamp"], sequence: sequence, arrangementId: nil, shepherdTag: "a1").presentation
        #expect(kept.shepherdImportHash == imported.shepherdImportHash)
        #expect(ShepherdSongImport.decision(for: kept, chartHash: "newer") == .edited)
    }
}
