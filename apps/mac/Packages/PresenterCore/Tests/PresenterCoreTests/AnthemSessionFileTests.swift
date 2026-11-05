import Foundation
import Testing
@testable import PresenterCore

/// A session file as Anthem writes one (its decision 0060): stored entries,
/// ZIP64 sizes and offsets in extras, a ZIP64 end record and locator, and
/// an end record with a comment. `zip64: false` writes a plain ZIP, as an
/// archive rezipped by hand would be.
private func archive(_ files: [(String, Data)], zip64: Bool = true) -> Data {
    var out = Data()
    var directory = Data()
    func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    func u32(_ v: UInt64, _ d: inout Data) { for i in 0..<4 { d.append(UInt8(v >> (8 * UInt64(i)) & 0xFF)) } }
    func u64(_ v: UInt64, _ d: inout Data) { for i in 0..<8 { d.append(UInt8(v >> (8 * UInt64(i)) & 0xFF)) } }
    let big: UInt64 = 0xFFFF_FFFF
    for (name, data) in files {
        let offset = UInt64(out.count)
        let size = UInt64(data.count)
        let nameBytes = Data(name.utf8)
        u32(0x0403_4b50, &out); u16(45, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0, &out)
        u32(0, &out)
        u32(zip64 ? big : size, &out); u32(zip64 ? big : size, &out)
        u16(nameBytes.count, &out); u16(zip64 ? 20 : 0, &out)
        out.append(nameBytes)
        if zip64 { u16(1, &out); u16(16, &out); u64(size, &out); u64(size, &out) }
        out.append(data)

        u32(0x0201_4b50, &directory); u16(3 << 8 | 45, &directory); u16(45, &directory)
        u16(0x0800, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
        u32(0, &directory)
        u32(zip64 ? big : size, &directory); u32(zip64 ? big : size, &directory)
        u16(nameBytes.count, &directory); u16(zip64 ? 28 : 0, &directory); u16(0, &directory)
        u16(0, &directory); u16(0, &directory); u32(0, &directory)
        u32(zip64 ? big : offset, &directory)
        directory.append(nameBytes)
        if zip64 { u16(1, &directory); u16(24, &directory); u64(size, &directory); u64(size, &directory); u64(offset, &directory) }
    }
    let directoryOffset = UInt64(out.count)
    out.append(directory)
    if zip64 {
        let recordOffset = UInt64(out.count)
        u32(0x0606_4b50, &out); u64(44, &out); u16(45, &out); u16(45, &out); u32(0, &out); u32(0, &out)
        u64(UInt64(files.count), &out); u64(UInt64(files.count), &out)
        u64(UInt64(directory.count), &out); u64(directoryOffset, &out)
        u32(0x0706_4b50, &out); u32(0, &out); u64(recordOffset, &out); u32(1, &out)
    }
    let comment = Data("Anthem session, format 2. Open it in Anthem (File › Open Session…).".utf8)
    u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out)
    u16(files.count, &out); u16(files.count, &out)
    u32(UInt64(directory.count), &out); u32(directoryOffset, &out)
    u16(comment.count, &out)
    out.append(comment)
    return out
}

private let songA = "A9F3C1D2-0000-4000-8000-000000000001"
private let songB = "B9F3C1D2-0000-4000-8000-000000000002"

private let sessionJSON = """
{
  "appVersion" : "0.37.0",
  "createdAt" : "2026-11-01T15:02:11Z",
  "formatVersion" : 2,
  "setlist" : {
    "entries" : [
      { "id" : "E1", "songID" : "\(songA.lowercased())", "keyOffsetOverride" : 2, "arrangementID" : "SHORT",
        "transitionToNext" : { "kind" : "stop" } },
      { "id" : "E2", "songID" : "00000000-0000-4000-8000-0000000000FF",
        "placeholder" : { "ccliNumber" : " 7138371 ", "planKey" : "C", "title" : "Firm Foundation" } },
      { "id" : "E3", "songID" : "\(songB)" },
      { "id" : "E4", "songID" : "C0000000-0000-4000-8000-000000000003" }
    ],
    "id" : "S1", "name" : "Sunday 9:00", "notes" : "", "pad" : { }
  },
  "additionalSetlists" : [ { "id" : "S2", "name" : "Rehearsal", "entries" : [ ], "pad" : { }, "notes" : "" } ],
  "songs" : [
    { "document" : "songs/\(songA)/song.json", "id" : "\(songA)", "title" : "Living Hope" },
    { "document" : "songs/\(songB)/song.json", "id" : "\(songB)", "title" : "Gratitude" }
  ],
  "shepherdLinks" : [ { "planID" : "plan-123", "setlistID" : "S1", "planDate" : "2026-11-08T14:00:00Z",
                        "generatedName" : "x", "songCount" : 3, "flagged" : [ ], "notes" : [ ] } ]
}
"""

private let songAJSON = """
{ "schemaVersion" : 1, "song" : {
  "id" : "\(songA)", "title" : "Living Hope", "ccliNumber" : "7106807", "originalKey" : "Bb",
  "accidentalPreference" : "conventional", "sampleRate" : 48000,
  "sections" : [
    { "id" : "INTRO", "kind" : "intro", "startBeat" : 0 },
    { "id" : "V1", "name" : "Verse 1", "kind" : "verse", "startBeat" : 8 },
    { "id" : "CH", "name" : "Chorus", "kind" : "chorus", "startBeat" : 40 },
    { "id" : "V2", "name" : "Verse 2", "kind" : "verse", "startBeat" : 72 },
    { "id" : "BR", "name" : "Bridge", "kind" : "bridge", "startBeat" : 104 }
  ],
  "arrangement" : [ "INTRO", "V1", "CH", "V2", "CH", "BR", "CH" ],
  "defaultArrangementName" : "Sunday",
  "savedArrangements" : [ { "id" : "SHORT", "name" : "Short", "order" : [ "V1", "GONE", "CH", "CH" ] } ]
} }
"""

/// No order at all: every section once, by where it starts.
private let songBJSON = """
{ "song" : {
  "id" : "\(songB)", "title" : "Gratitude", "ccliNumber" : "", "originalKey" : "D#m",
  "playbackKeyOffsetSemitones" : 0, "accidentalPreference" : "sharps",
  "sections" : [
    { "id" : "B2", "name" : "Chorus", "kind" : "chorus", "startBeat" : 32 },
    { "id" : "B1", "kind" : "verse", "startBeat" : 0 },
    { "id" : "B3", "name" : " chorus ", "kind" : "chorus", "startBeat" : 64 }
  ],
  "arrangement" : [ ]
} }
"""

private func sessionFile(_ files: [(String, Data)]? = nil, zip64: Bool = true) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("anthem-\(UUID().uuidString).anthem")
    let contents = files ?? [
        ("session.json", Data(sessionJSON.utf8)),
        ("README.txt", Data("Anthem".utf8)),
        ("songs/\(songA)/song.json", Data(songAJSON.utf8)),
        ("songs/\(songB)/song.json", Data(songBJSON.utf8)),
        ("audio/0123456789abcdef/Click.wav", Data(repeating: 7, count: 4096)),
        ("manifest.json", Data("{}".utf8)),
    ]
    try archive(contents, zip64: zip64).write(to: url)
    return url
}

@Suite("Anthem session files")
struct AnthemSessionFileTests {
    @Test func readsTheSetlistsAsAnthemsFeedWouldSendThem() throws {
        let url = try sessionFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let lists = try AnthemSessionFile.read(url)
        #expect(lists.map(\.setlist.name) == ["Sunday 9:00", "Rehearsal"])
        #expect(lists[0].shepherdPlanID == "plan-123")
        #expect(lists[0].planDate == ISO8601DateFormatter().date(from: "2026-11-08T14:00:00Z"))
        #expect(lists[1].planDate == nil)

        let entries = lists[0].setlist.entries
        #expect(entries.map(\.title) == ["Living Hope", "Firm Foundation", "Gratitude", "Missing song"])

        // The entry's own layout, a section the song lost skipped, a
        // repeated chorus counted; its key overrides the song's offset.
        let hope = entries[0]
        #expect(hope.ccliNumber == 7_106_807)
        #expect(hope.key == "C")
        #expect(hope.arrangement?.name == "Short")
        #expect(hope.arrangement?.sections.map(\.name) == ["Verse 1", "Chorus", "Chorus"])
        #expect(hope.arrangement?.sections.map(\.occurrence) == [1, 1, 2])

        // A song with no tracks: its plan's title, CCLI and key only.
        let placeholder = entries[1]
        #expect(placeholder.songId == nil)
        #expect(placeholder.ccli == "7138371")
        #expect(placeholder.key == "C")
        #expect(placeholder.arrangement == nil)

        // No order: every section once by start beat; a blank name is the
        // kind's; names count the same however they're spaced or cased.
        let gratitude = entries[2]
        #expect(gratitude.ccli == nil)
        #expect(gratitude.key == "D#m")
        #expect(gratitude.arrangement?.name == "Main")
        #expect(gratitude.arrangement?.sections.map(\.name) == ["Verse", "Chorus", " chorus "])
        #expect(gratitude.arrangement?.sections.map(\.occurrence) == [1, 1, 2])
    }

    /// A file Anthem itself wrote reads as Anthem's feed describes the same
    /// setlist (but for tempo and section lengths, which the file isn't read
    /// for).
    @Test func aFileAnthemWroteSaysWhatItsFeedSays() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).anthem")
        try AnthemSessionFixture.anthemFile.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lists = try AnthemSessionFile.read(url)
        #expect(lists.map(\.setlist.name) == ["Sunday 9:00", "Rehearsal"])
        guard case .setlist(var feed) = try AnthemShow.decodeSetlist(Data(AnthemSessionFixture.feedJSON.utf8), status: 200)
        else { Issue.record("feed fixture"); return }
        for index in feed.entries.indices {
            feed.entries[index].bpm = nil
            if var arrangement = feed.entries[index].arrangement {
                for section in arrangement.sections.indices { arrangement.sections[section].lengthSeconds = nil }
                feed.entries[index].arrangement = arrangement
            }
        }
        #expect(lists[0].setlist == feed)
        #expect(feed.entries.map(\.key) == ["C", "C", "D#m", "Bb"])
        #expect(feed.entries[0].arrangement?.sections.map(\.name) == ["Verse 1", "Chorus", "Chorus"])
    }

    @Test func aPlainZipReadsToo() throws {
        let url = try sessionFile(zip64: false)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AnthemSessionFile.read(url).first?.setlist.entries.count == 4)
    }

    @Test func anEntryOnTheDefaultLayoutPlaysTheSongsOrder() throws {
        let json = sessionJSON.replacingOccurrences(of: "\"arrangementID\" : \"SHORT\"", with: "\"arrangementID\" : \"DELETED\"")
        let lists = try AnthemSessionFile.setlists(sessionJSON: Data(json.utf8)) { path in
            path.contains(songA) ? Data(songAJSON.utf8) : Data(songBJSON.utf8)
        }
        let hope = lists[0].setlist.entries[0]
        #expect(hope.arrangement?.name == "Sunday")
        #expect(hope.arrangement?.id == songA)
        #expect(hope.arrangement?.sections.map(\.name)
            == ["Intro", "Verse 1", "Chorus", "Verse 2", "Chorus", "Bridge", "Chorus"])
    }

    @Test func refusesWhatIsntASessionOrIsTooNew() throws {
        let notZip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).anthem")
        try Data("hello".utf8).write(to: notZip)
        defer { try? FileManager.default.removeItem(at: notZip) }
        #expect(throws: AnthemSessionFile.ReadError.notASession) { try AnthemSessionFile.read(notZip) }

        let newer = sessionJSON.replacingOccurrences(of: "\"formatVersion\" : 2", with: "\"formatVersion\" : 3")
        #expect(throws: AnthemSessionFile.ReadError.newerFormat(3, app: "0.37.0")) {
            try AnthemSessionFile.setlists(sessionJSON: Data(newer.utf8)) { _ in nil }
        }

        let noSession = try sessionFile([("manifest.json", Data("{}".utf8))])
        defer { try? FileManager.default.removeItem(at: noSession) }
        #expect(throws: AnthemSessionFile.ReadError.notASession) { try AnthemSessionFile.read(noSession) }
    }

    @Test func aFileCutShortIsRefused() throws {
        let url = try sessionFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 40).write(to: url)
        #expect(throws: (any Error).self) { try AnthemSessionFile.read(url) }
    }

    @Test func keysAreSpelledAsAnthemSpellsThem() {
        typealias Key = AnthemSessionFile.Key
        #expect(Key(parsing: "Bb")?.transposed(by: 2).name(.conventional) == "C")
        #expect(Key(parsing: "A")?.transposed(by: 1).name(.conventional) == "Bb")
        #expect(Key(parsing: "E")?.transposed(by: 2).name(.conventional) == "F#")
        #expect(Key(parsing: "C#m")?.name(.conventional) == "C#m")
        #expect(Key(parsing: "D#m")?.name(.conventional) == "Ebm")
        #expect(Key(parsing: "Bb")?.name(.sharps) == "A#")
        #expect(Key(parsing: "C♯ minor")?.name(.flats) == "Dbm")
        #expect(Key(parsing: "GM")?.name(.conventional) == "G")
        #expect(Key(parsing: "G-")?.name(.conventional) == "Gm")
        #expect(Key(parsing: "B")?.transposed(by: -12).name(.conventional) == "B")
        #expect(Key(parsing: "H") == nil)
        #expect(Key(parsing: "Csus") == nil)
    }
}

@Suite("Importing an Anthem session into a plan")
struct AnthemSessionImportTests {
    private func song(_ id: String, _ title: String, source: String? = nil) -> ServiceItem {
        var item = ServiceItem(id: id, itemKind: .presentation, name: title, refId: "p-\(id)")
        item.mxuSongTitle = title
        item.mxuSourceItemId = source
        return item
    }

    private func header(_ id: String) -> ServiceItem {
        ServiceItem(id: id, itemKind: .header, name: id, refId: "")
    }

    private func setlist(_ titles: [String]) -> AnthemShow.Setlist {
        AnthemShow.Setlist(id: "S", name: "Sunday", entries: titles.enumerated().map {
            AnthemShow.Entry(entryId: "e\($0.offset)", title: $0.element, ccli: $0.element == "New" ? "123" : nil, key: "G")
        })
    }

    @Test func songsTakeAnthemsOrderInThePlacesSongsHad() {
        let items = [header("Worship"), song("a", "A"), song("b", "B"), header("Message"), song("c", "C")]
        let arranged = AnthemSessionImport.arrange(
            items: items, setlist: setlist(["C", "A", "B"]), pairs: ["e0": "c", "e1": "a", "e2": "b"])
        #expect(arranged.items.map(\.id) == ["Worship", "c", "a", "Message", "b"])
        #expect(arranged.moved == 3)
        #expect(arranged.added.isEmpty)
        #expect(arranged.songOrder == ["c", "a", "b"])
    }

    @Test func anthemsSongsThePlanLacksAreAddedAfterTheSongBefore() {
        let items = [header("Worship"), song("a", "A", source: "shep-a"), song("b", "B"), header("Message")]
        var ids = ["n1", "n2", "n3"].makeIterator()
        let arranged = AnthemSessionImport.arrange(
            items: items, setlist: setlist(["Opener", "A", "New", "B"]), pairs: ["e1": "a", "e3": "b"],
            newID: { ids.next()! })
        #expect(arranged.items.map(\.id) == ["Worship", "n1", "a", "n2", "b", "Message"])
        #expect(arranged.moved == 0)
        let added = arranged.added.first { $0.id == "n2" }
        #expect(added?.itemKind == .info)
        #expect(added?.refId == "")
        #expect(added?.mxuSongTitle == "New")
        #expect(added?.mxuCcliNumber == 123)
        #expect(added?.mxuSongKey == "G")
        // A Shepherd item is named by Shepherd's ID, which survives a sync.
        #expect(arranged.songOrder == ["n1", "shep-a", "n2", "b"])
    }

    @Test func withNoSongInCommonTheSetIsAddedAtTheEnd() {
        let items = [header("Welcome")]
        let arranged = AnthemSessionImport.arrange(items: items, setlist: setlist(["X", "Y"]), pairs: [:])
        #expect(arranged.items.map(\.name) == ["Welcome", "X", "Y"])
    }

    @Test func aSyncInShepherdsOrderGetsAnthemsOrderBack() {
        let synced = [header("Worship"), song("1", "A", source: "sa"), song("2", "B", source: "sb"),
                      header("Message"), song("3", "C", source: "sc"), song("local", "Added")]
        let order = ["sc", "local", "sa"]
        let result = AnthemSessionImport.applyOrder(order, to: synced)
        #expect(result.map(\.id) == ["Worship", "3", "2", "Message", "local", "1"])
        #expect(AnthemSessionImport.applyOrder(nil, to: synced) == synced)
        #expect(AnthemSessionImport.applyOrder(["gone"], to: synced) == synced)
    }

    @Test func theTargetIsTheShepherdPlanThenItsDayThenAFollowingPlan() {
        let utc = TimeZone(identifier: "America/New_York")!
        let sunday = Service(id: "sun", name: "Sunday", serviceDate: "2026-11-08", items: [],
                             origin: ShepherdPlanSync.origin, mxuPlanHexId: "plan-123")
        let local = Service(id: "local", name: "Youth", serviceDate: "2026-11-06", items: [])
        let later = Service(id: "later", name: "Next", serviceDate: "2026-11-15", items: [])
        let plans = [local, sunday, later]
        func info(planID: String? = nil, date: String? = nil) -> AnthemSessionFile.SetlistInfo {
            AnthemSessionFile.SetlistInfo(
                setlist: setlist(["A"]), planDate: date.flatMap { ISO8601DateFormatter().date(from: $0) },
                shepherdPlanID: planID)
        }
        #expect(AnthemSessionImport.targetPlan(for: info(planID: "plan-123"), plans: plans, today: "2026-11-04",
                                               timeZone: utc, follows: { _ in false })?.id == "sun")
        // 2 a.m. UTC on the 16th is the 15th in Tennessee.
        #expect(AnthemSessionImport.targetPlan(for: info(date: "2026-11-16T02:00:00Z"), plans: plans,
                                               today: "2026-11-04", timeZone: utc, follows: { _ in false })?.id == "later")
        #expect(AnthemSessionImport.targetPlan(for: info(), plans: plans, today: "2026-11-04",
                                               timeZone: utc, follows: { $0.id == "later" })?.id == "later")
        // Nothing says: the next Shepherd plan, as Build Sunday picks it.
        #expect(AnthemSessionImport.targetPlan(for: info(), plans: plans, today: "2026-11-04",
                                               timeZone: utc, follows: { _ in false })?.id == "sun")
    }
}
