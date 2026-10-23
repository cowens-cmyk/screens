import Foundation
import Testing

@testable import PresenterCore

// Sample answers in the shape of Anthem's show feed contract.

private let setlistJSON = #"""
{
  "id": "set-1023", "name": "Sunday Oct 26",
  "entries": [
    {"entryId": "e1", "songId": "s1", "title": "Build My Life", "ccli": "7070345", "key": "G", "bpm": 68,
     "arrangement": {"id": "a1", "name": "Default", "sections": [
       {"sectionId": "x1", "name": "Intro", "kind": "instrumental", "occurrence": 1, "lengthSeconds": 12.5},
       {"sectionId": "x2", "name": "Verse 1", "kind": "verse", "occurrence": 1, "lengthSeconds": 30},
       {"sectionId": "x3", "name": "Chorus", "kind": "chorus", "occurrence": 1, "lengthSeconds": 28},
       {"sectionId": "x4", "name": "Verse 2", "kind": "verse", "occurrence": 1, "lengthSeconds": 30},
       {"sectionId": "x5", "name": "Chorus", "kind": "chorus", "occurrence": 2, "lengthSeconds": 28},
       {"sectionId": "x6", "name": "Turnaround", "kind": "instrumental", "occurrence": 1, "lengthSeconds": 8},
       {"sectionId": "x7", "name": "Bridge", "kind": "bridge", "occurrence": 1, "lengthSeconds": 40},
       {"sectionId": "x8", "name": "Chorus", "kind": "chorus", "occurrence": 3, "lengthSeconds": 28},
       {"sectionId": "x9", "name": "Chorus", "kind": "chorus", "occurrence": 4, "lengthSeconds": 28}
     ]}},
    {"entryId": "e2", "songId": "s2", "title": "Gratitude (Live)", "ccli": null, "key": "B", "bpm": 72,
     "arrangement": {"id": "a2", "name": "Default", "sections": [
       {"sectionId": "y1", "name": "V1", "kind": "verse", "occurrence": 1, "lengthSeconds": 20},
       {"sectionId": "y2", "name": "CH", "kind": "chorus", "occurrence": 1, "lengthSeconds": 20},
       {"sectionId": "y3", "name": "Tag", "kind": "tag", "occurrence": 1, "lengthSeconds": 10}
     ]}},
    {"entryId": "e3", "songId": "s3", "title": "Firm Foundation", "ccli": 7188203, "key": null, "bpm": null,
     "arrangement": {"id": "a3", "name": "Default", "sections": []}}
  ]
}
"""#

private let statusJSON = #"""
{"setlistId": "set-1023", "liveEntryId": "e1", "cuedEntryId": null, "playing": true,
 "positionSeconds": 41.2, "sectionIndex": 2, "sectionName": "Chorus"}
"""#

private func setlist() throws -> AnthemShow.Setlist {
    guard case .setlist(let setlist) = try AnthemShow.decodeSetlist(Data(setlistJSON.utf8), status: 200) else {
        throw AnthemShow.DecodeError.status(0)
    }
    return setlist
}

private func text(_ words: String) -> SlideObject {
    SlideObject(id: UUID().uuidString, objectKind: .text, name: "Lyrics", text: words)
}

/// A song with one slide per section, in the order given.
private func song(_ id: String, _ name: String, sections: [(String, String, Bool)], arrangements: [Arrangement] = [], ccli: Int? = nil) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "t",
        slides: sections.map { Slide(id: "slide-\($0.0)", name: $0.1, objects: $0.2 ? [text("words")] : [], sectionId: $0.0) },
        sections: sections.map { PresentationSection(id: $0.0, name: $0.1) },
        arrangements: arrangements,
        ccli: ccli.map { CCLIInfo(songNumber: $0) }
    )
}

private let buildMyLife = song("p1", "Build My Life", sections: [
    ("v1", "Verse 1", true), ("c", "Chorus", true), ("v2", "Verse 2", true), ("b", "Bridge", true),
], arrangements: [Arrangement(id: "arr", name: "Sunday", sectionIds: ["v1", "c", "v2", "c", "b", "c"])], ccli: 7070345)

@Suite struct AnthemFeedDecodingTests {
    @Test func decodesTheSetlist() throws {
        let set = try setlist()
        #expect(set.name == "Sunday Oct 26")
        #expect(set.entries.count == 3)
        #expect(set.entries[0].ccliNumber == 7070345)
        #expect(set.entries[0].bpm == 68)
        #expect(set.entries[0].arrangement?.sections.count == 9)
        #expect(set.entries[0].arrangement?.sections[4].occurrence == 2)
        #expect(set.entries[1].ccli == nil)
        // A number where the contract says string still reads.
        #expect(set.entries[2].ccliNumber == 7188203)
        #expect(set.entries[2].key == nil)
    }

    @Test func noActiveSetlistIsNotAnError() throws {
        let answer = try AnthemShow.decodeSetlist(Data(#"{"error":"no active setlist"}"#.utf8), status: 404)
        #expect(answer == .none)
        #expect(throws: AnthemShow.DecodeError.status(500)) {
            try AnthemShow.decodeSetlist(Data(), status: 500)
        }
    }

    @Test func decodesStatusAndInfo() throws {
        let status = try AnthemShow.decodeStatus(Data(statusJSON.utf8), status: 200)
        #expect(status.liveEntryId == "e1")
        #expect(status.cuedEntryId == nil)
        #expect(status.songIsLive)
        #expect(!AnthemShow.Status().songIsLive)
        let info = try AnthemShow.decodeInfo(Data(#"{"app":"Anthem","version":"0.9.0","feed":1}"#.utf8))
        #expect(info.feed == 1)
        #expect(throws: AnthemShow.DecodeError.notAnthem) {
            try AnthemShow.decodeInfo(Data(#"{"app":"Other"}"#.utf8))
        }
    }

    @Test func manualAddressesParse() {
        #expect(AnthemShow.endpoint(fromManual: "10.0.1.20")! == ("10.0.1.20", 7731))
        #expect(AnthemShow.endpoint(fromManual: " band-mac.local:8000 ")! == ("band-mac.local", 8000))
        #expect(AnthemShow.endpoint(fromManual: "http://10.0.1.20:7731/v1/info")! == ("10.0.1.20", 7731))
        #expect(AnthemShow.endpoint(fromManual: "[fe80::1]:7731")! == ("fe80::1", 7731))
        #expect(AnthemShow.endpoint(fromManual: "") == nil)
        #expect(AnthemShow.endpoint(fromManual: "host:notaport") == nil)
    }
}

@Suite struct SectionLabelTests {
    @Test func spellingsOfOneSectionAgree() {
        for name in ["Verse 1", "V1", "verse1", "VERSE 1", "Vs 1", "Verse 1 (x2)"] {
            let label = SectionLabel(name)
            #expect(label.kind == "verse" && label.number == 1, "\(name)")
        }
        for name in ["Chorus", "CH", "C", "chorus x2"] {
            #expect(SectionLabel(name).kind == "chorus", "\(name)")
        }
        for name in ["Pre-Chorus", "Pre Chorus", "PreChorus", "PC", "Pre"] {
            #expect(SectionLabel(name).kind == "pre-chorus", "\(name)")
        }
        #expect(SectionLabel("Turn Around").kind == "turnaround")
        #expect(SectionLabel("TA").kind == "turnaround")
        #expect(SectionLabel("Final Chorus").kind == "chorus")
        #expect(SectionLabel("Final Chorus").cleaned == "final chorus")
        #expect(SectionLabel("Coda 2").kind == "coda")
        #expect(!SectionLabel("Coda 2").known)
    }

    @Test func instrumentalKinds() {
        for name in ["Instrumental", "Interlude", "Turnaround", "Inst 2", "Solo", "Blank"] {
            #expect(SectionLabel(name).isInstrumental, "\(name)")
        }
        for name in ["Intro", "Outro", "Ending"] {
            #expect(!SectionLabel(name).isInstrumental && SectionLabel(name).mayBeInstrumental, "\(name)")
        }
        #expect(!SectionLabel("Vamp").mayBeInstrumental)
        #expect(!SectionLabel("Chorus").mayBeInstrumental)
    }

    @Test func shortAndDisplayNames() {
        #expect(SectionLabel("Verse 2").short == "V2")
        #expect(SectionLabel("Chorus").short == "C")
        #expect(SectionLabel("Pre Chorus").short == "PC")
        #expect(SectionLabel("Bridge 2").short == "B2")
        #expect(SectionLabel("tag").display == "Tag")
        #expect(SectionLabel("v3").display == "Verse 3")
        #expect(SectionLabel("Coda").short == "Coda")
    }
}

@Suite struct AnthemArrangementMatchTests {
    private func shape(_ presentation: Presentation, _ arrangementId: String? = nil) -> ScreensSongShape {
        ScreensSongShape(presentation: presentation, arrangementId: arrangementId)
    }

    @Test func orderComesFromItemThenDefaultThenSlides() {
        var p = buildMyLife
        #expect(shape(p, "arr").order == ["v1", "c", "v2", "c", "b", "c"])
        #expect(shape(p).order == ["v1", "c", "v2", "b"])
        p.defaultArrangementId = "arr"
        #expect(shape(p).order == ["v1", "c", "v2", "c", "b", "c"])
        #expect(shape(p, "gone").arrangementId == "arr")
    }

    @Test func oneChorusShortReadsAsAMismatchWithADiff() throws {
        let sections = try #require(try setlist().entries[0].arrangement?.sections)
        let result = AnthemArrangementMatch.compare(sections, song: shape(buildMyLife, "arr"))
        #expect(!result.matches)
        #expect(result.missing.isEmpty)
        // Intro and turnaround have no slides and are left out.
        #expect(result.diff == "Anthem: V1 C V2 C B C C — Screens: V1 C V2 C B C")
        #expect(result.proposed == ["v1", "c", "v2", "c", "b", "c", "c"])
    }

    @Test func sameOrderMatches() throws {
        let sections = try #require(try setlist().entries[0].arrangement?.sections)
        var p = buildMyLife
        p.arrangements = [Arrangement(id: "arr", name: "Sunday", sectionIds: ["v1", "c", "v2", "c", "b", "c", "c"])]
        #expect(AnthemArrangementMatch.compare(sections, song: shape(p, "arr")).matches)
    }

    @Test func instrumentalsMapToBlankSlidesWhenScreensHasThem() throws {
        let sections = try #require(try setlist().entries[0].arrangement?.sections)
        let p = song("p", "Build My Life", sections: [
            ("i", "Intro", false), ("v1", "Verse 1", true), ("c", "Chorus", true), ("v2", "Verse 2", true),
            ("b", "Bridge", true), ("x", "Instrumental", false),
        ])
        let result = AnthemArrangementMatch.compare(sections, song: shape(p))
        #expect(result.proposed == ["i", "v1", "c", "v2", "c", "x", "b", "c", "c"])
        // Ignored or not, blanks never make a song differ by themselves.
        var arranged = p
        arranged.arrangements = [Arrangement(id: "a", name: "A", sectionIds: ["v1", "c", "v2", "c", "b", "c", "c"])]
        #expect(AnthemArrangementMatch.compare(sections, song: shape(arranged, "a")).matches)
        #expect(!AnthemArrangementMatch.compare(sections, song: shape(arranged, "a"), options: .init(ignoreInstrumental: false)).matches)
        arranged.arrangements = [Arrangement(id: "a", name: "A", sectionIds: result.proposed)]
        #expect(AnthemArrangementMatch.compare(sections, song: shape(arranged, "a"), options: .init(ignoreInstrumental: false)).matches)
    }

    @Test func instrumentalsWithNoSlidesAreMissingWhenNotIgnored() throws {
        let sections = try #require(try setlist().entries[0].arrangement?.sections)
        var p = buildMyLife
        p.arrangements = [Arrangement(id: "arr", name: "Sunday", sectionIds: ["v1", "c", "v2", "c", "b", "c", "c"])]
        let result = AnthemArrangementMatch.compare(sections, song: shape(p, "arr"), options: .init(ignoreInstrumental: false))
        #expect(!result.matches)
        #expect(result.missing.map(\.display) == ["Intro", "Turnaround"])
    }

    @Test func missingLyricSectionsAreReportedNotInvented() throws {
        let sections = try #require(try setlist().entries[1].arrangement?.sections)
        let p = song("g", "Gratitude", sections: [("v1", "Verse", true), ("c", "Chorus", true)])
        let result = AnthemArrangementMatch.compare(sections, song: shape(p))
        #expect(!result.matches)
        #expect(result.missing.map(\.display) == ["Tag"])
        #expect(result.proposed == ["v1", "c"])
        #expect(result.diff == "Anthem: V C T — Screens: V C")
        #expect(AnthemArrangementMatch.missingNote(result.missing) == "Screens has no Tag — add it in the editor.")
    }

    @Test func unnumberedRepeatsFindTheirNumberedSections() {
        let p = song("p", "Song", sections: [("v1", "Verse 1", true), ("v2", "Verse 2", true), ("c", "Chorus", true)])
        let performed = [
            AnthemShow.Section(name: "Verse", occurrence: 1), AnthemShow.Section(name: "Chorus", occurrence: 1),
            AnthemShow.Section(name: "Verse", occurrence: 2), AnthemShow.Section(name: "Chorus 2", occurrence: 1),
        ]
        let result = AnthemArrangementMatch.compare(performed, song: shape(p))
        #expect(result.proposed == ["v1", "c", "v2", "c"])
        // A third verse Screens doesn't have is missing, not the first again.
        let third = AnthemArrangementMatch.compare([AnthemShow.Section(name: "Verse 3")], song: shape(p))
        #expect(third.missing.map(\.display) == ["Verse 3"])
    }

    @Test func aChorusAnthemMarksInstrumentalIsNotTheChorusWords() {
        let p = song("p", "Song", sections: [("c", "Chorus", true), ("x", "Instrumental", false)])
        let performed = [
            AnthemShow.Section(name: "Chorus", kind: "chorus", occurrence: 1),
            AnthemShow.Section(name: "Chorus", kind: "instrumental", occurrence: 2),
        ]
        #expect(AnthemArrangementMatch.compare(performed, song: shape(p)).proposed == ["c", "x"])
    }

    @Test func anthemArrangementReusesOrUpdates() {
        let existing = [Arrangement(id: "a", name: "Default", sectionIds: ["v", "c"])]
        let same = AnthemSongMatch.anthemArrangement(order: ["v", "c"], in: existing, newID: "n")
        #expect(same.arrangement.id == "a" && !same.isNew)
        let fresh = AnthemSongMatch.anthemArrangement(order: ["v", "c", "c"], in: existing, newID: "n")
        #expect(fresh.arrangement == Arrangement(id: "n", name: "Anthem", sectionIds: ["v", "c", "c"]) && fresh.isNew)
        let named = existing + [Arrangement(id: "b", name: "Anthem", sectionIds: ["v"])]
        let updated = AnthemSongMatch.anthemArrangement(order: ["v", "c", "c"], in: named, newID: "n")
        #expect(updated.arrangement == Arrangement(id: "b", name: "Anthem", sectionIds: ["v", "c", "c"]) && !updated.isNew)
    }
}

@Suite struct AnthemSongMatchTests {
    private func item(_ id: String, _ name: String, ref: String, ccli: Int? = nil, arrangement: String? = nil) -> ServiceItem {
        ServiceItem(id: id, itemKind: .presentation, name: name, refId: ref, arrangementId: arrangement, mxuCcliNumber: ccli)
    }

    @Test func pairsByCCLIThenTitle() throws {
        let gratitude = song("g", "Gratitude", sections: [("v1", "Verse", true), ("c", "Chorus", true), ("t", "Tag", true)])
        let songs = [
            AnthemSongMatch.PlanSong(item: item("i1", "Build My Life", ref: "p1", arrangement: "arr"), presentation: buildMyLife),
            AnthemSongMatch.PlanSong(item: item("i2", "Gratitude", ref: "g"), presentation: gratitude),
            AnthemSongMatch.PlanSong(item: item("i3", "Way Maker", ref: "w"), presentation: song("w", "Way Maker", sections: [("v", "Verse", true)])),
        ]
        let report = AnthemSongMatch.report(setlist: try setlist(), songs: songs)
        #expect(report.result(forItem: "i1")?.status == .mismatch)
        #expect(report.result(forItem: "i1")?.entryID == "e1")
        // "Gratitude (Live)" is Gratitude.
        #expect(report.result(forItem: "i2")?.status == .match)
        #expect(report.result(forItem: "i3")?.status == .notInAnthem)
        #expect(report.notInScreens.map(\.title) == ["Firm Foundation"])
        #expect(report.matched == 2)
        #expect(report.followsSetlist)
    }

    @Test func ccliBeatsATitleThatDiffers() throws {
        let renamed = AnthemSongMatch.PlanSong(
            item: item("i1", "BML (Sunday key)", ref: "p1", arrangement: "arr"), presentation: buildMyLife)
        let report = AnthemSongMatch.report(setlist: try setlist(), songs: [renamed])
        #expect(report.result(forItem: "i1")?.entryID == "e1")
    }

    @Test func aSongWithNoSlidesIsNotCompared() throws {
        let planned = AnthemSongMatch.PlanSong(itemID: "i9", ccli: nil, titles: ["Firm Foundation"], shape: nil)
        let report = AnthemSongMatch.report(setlist: try setlist(), songs: [planned])
        #expect(report.result(forItem: "i9")?.status == .noSlides)
    }

    @Test func anUnrelatedPlanDoesNotFollowTheSetlist() throws {
        let songs = (1...6).map { AnthemSongMatch.PlanSong(itemID: "i\($0)", ccli: nil, titles: ["Song \($0)"], shape: nil) }
            + [AnthemSongMatch.PlanSong(item: item("i1", "Build My Life", ref: "p1"), presentation: buildMyLife)]
        let report = AnthemSongMatch.report(setlist: try setlist(), songs: songs)
        #expect(report.matched == 1)
        #expect(!report.followsSetlist)
    }

    @Test func titlesNormalize() {
        #expect(AnthemSongMatch.normalizedTitle("Great Are You Lord (Live)") == "great are you lord")
        #expect(AnthemSongMatch.normalizedTitle("God's Great Dance Floor") == AnthemSongMatch.normalizedTitle("Gods Great Dance-Floor"))
        #expect(AnthemSongMatch.normalizedTitle("Holy & Anointed") == "holy and anointed")
        #expect(AnthemSongMatch.normalizedTitle("Ámen") == "amen")
    }
}

@Suite struct AnthemCueTests {
    @Test func picksTheOccurrenceAfterTheOneOnScreen() {
        let arranged = ["v1", "c", "v2", "c", "b", "c"]
        #expect(AnthemCue.occurrence(of: "c", in: arranged, current: nil) == 1)
        #expect(AnthemCue.occurrence(of: "c", in: arranged, current: 2) == 3)
        #expect(AnthemCue.occurrence(of: "c", in: arranged, current: 3) == 3)
        #expect(AnthemCue.occurrence(of: "c", in: arranged, current: 5) == 5)
        #expect(AnthemCue.occurrence(of: "v1", in: arranged, current: 4) == 0)
        #expect(AnthemCue.occurrence(of: "tag", in: arranged, current: 0) == nil)
    }
}

@Suite struct ProPresenterLibraryTests {
    private let items = [
        ProPresenterCompat.LibraryItem(id: "1", name: "Way Maker", folder: "Songs"),
        ProPresenterCompat.LibraryItem(id: "2", name: "Amazing Grace", folder: "Songs/Hymns"),
        ProPresenterCompat.LibraryItem(id: "3", name: "Welcome", folder: "Announcements"),
        ProPresenterCompat.LibraryItem(id: "4", name: "Loose", folder: ""),
    ]

    @Test func folderNamesFilter() {
        let names = { (list: [[String: Any]]) in list.compactMap { $0["name"] as? String } }
        #expect(names(ProPresenterCompat.libraryItems(items, named: "songs")) == ["Amazing Grace", "Way Maker"])
        #expect(names(ProPresenterCompat.libraryItems(items, named: "Songs/Hymns")) == ["Amazing Grace"])
        #expect(names(ProPresenterCompat.libraryItems(items, named: "folder:Announcements")) == ["Welcome"])
        #expect(ProPresenterCompat.libraryItems(items, named: "Screens").count == 4)
        #expect(ProPresenterCompat.libraryItems(items, named: "Nope").count == 4)
    }

    @Test func librariesListFolders() {
        let names = ProPresenterCompat.libraries(items).compactMap { ($0["id"] as? [String: Any])?["name"] as? String }
        #expect(names == ["Screens", "Announcements", "Songs"])
    }

    @Test func playlistItemsCarryTheArrangement() {
        let item = ServiceItem(id: "i", itemKind: .presentation, name: "Build My Life", refId: "p1", arrangementId: "arr")
        let entry = ProPresenterCompat.playlistItem(item, index: 2, presentation: buildMyLife)
        let info = entry["presentation_info"] as? [String: Any]
        #expect(info?["arrangement_name"] as? String == "Sunday")
        #expect(info?["arrangement_uuid"] as? String == "arr")
        #expect(entry["arrangement_name"] as? String == "Sunday")
        let plain = ProPresenterCompat.playlistItem(
            ServiceItem(id: "j", itemKind: .presentation, name: "X", refId: "p1"), index: 0, presentation: buildMyLife)
        #expect((plain["presentation_info"] as? [String: Any])?["arrangement_name"] as? String == "")
    }
}

@Suite struct AnthemMIDIPresetTests {
    @Test func anthemPresetMatchesAnthemsNotes() {
        let map = MIDIInputPreset.anthem.map
        #expect(map.channel == 1)
        #expect(map.note(for: .nextSlide) == 13)
        #expect(map.note(for: .previousSlide) == 14)
        #expect(map.note(for: .selectServiceItem) == 19)
        #expect(map.note(for: .triggerSlide) == 20)
        // Note on, channel 1, note 20, velocity 3: the third slide.
        let trigger = map.resolve(status: 0x90, data1: 20, data2: 3)
        #expect(trigger?.command == .triggerSlide && trigger?.velocity == 3)
        #expect(map.resolve(status: 0x90, data1: 13, data2: 1)?.command == .nextSlide)
        #expect(map.resolve(status: 0x90, data1: 14, data2: 1)?.command == .previousSlide)
        #expect(map.resolve(status: 0x90, data1: 19, data2: 2)?.command == .selectServiceItem)
        // Other channels are someone else's.
        #expect(map.resolve(status: 0x91, data1: 20, data2: 3) == nil)
    }

    @Test func noTwoCommandsShareANote() {
        for preset in MIDIInputPreset.allCases {
            let notes = MIDICommand.allCases.map { preset.map.note(for: $0) }
            #expect(Set(notes).count == notes.count, "\(preset)")
        }
    }

    @Test func stockMapIsUnchanged() {
        let stock = MIDIInputPreset.proPresenter.map
        #expect(stock == MIDICommandMap())
        #expect(stock.note(for: .triggerSlide) == 19)
        #expect(stock.note(for: .nextSlide) == 12)
        #expect(MIDIInputPreset.matching(MIDICommandMap()) == .proPresenter)
        #expect(MIDIInputPreset.matching(MIDIInputPreset.anthem.map) == .anthem)
        var edited = MIDIInputPreset.anthem.map
        edited.setNote(60, for: .clearAll)
        #expect(MIDIInputPreset.matching(edited) == nil)
    }

    @Test func anthemSourceNames() {
        #expect(AnthemMIDI.isAnthemSource(name: "Anthem"))
        #expect(AnthemMIDI.isAnthemSource(name: "anthem "))
        #expect(!AnthemMIDI.isAnthemSource(name: "Anthems Bus"))
        #expect(!AnthemMIDI.isAnthemSource(name: "IAC Driver Bus 1"))
    }
}

@Suite struct AnthemHTTPResponseTests {
    @Test func plainAndChunkedBodiesRead() throws {
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let parsed = try #require(AnthemShow.parseResponse(plain))
        #expect(parsed.status == 200 && parsed.body == Data("{}".utf8))

        let chunked = Data("HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n{\"error\r\n9\r\n\":\"none\"}\r\n0\r\n\r\n".utf8)
        let missing = try #require(AnthemShow.parseResponse(chunked))
        #expect(missing.status == 404)
        #expect(String(data: missing.body, encoding: .utf8) == #"{"error":"none"}"#)

        #expect(AnthemShow.parseResponse(Data("garbage".utf8)) == nil)
        #expect(String(data: AnthemShow.request(path: "/v1/info", host: "band"), encoding: .utf8)?
            .hasPrefix("GET /v1/info HTTP/1.0\r\nHost: band\r\n") == true)
    }
}
