import Foundation
import Testing
@testable import PresenterCore

private func planItem(
    _ id: String, _ title: String, type: String, sequence: Int,
    songID: String? = nil, ccli: Int? = nil, key: String? = nil
) -> PCOClient.Item {
    PCOClient.Item(
        id: id, title: title, itemType: type, sequence: sequence,
        description: nil, keyName: key, length: nil, servicePosition: "during",
        customArrangementSequence: nil, updatedAt: "",
        song: songID.map { PCOClient.Song(id: $0, title: title, author: nil, copyright: nil, ccliNumber: ccli) },
        arrangement: nil, key: key.map { PCOClient.Key(id: "k-\(id)", startingKey: $0) })
}

@Test func planOrderBecomesServiceWithRulesAndSongs() {
    let rules = ServiceLinkRules(id: "r", rules: [
        ServiceLinkRule(id: "1", normalizedName: "countdown", serviceTypeName: "Sunday Morning",
                        itemKind: .media, refId: "countdown-video"),
    ])
    let items = PCOPlanSync.items(
        for: [
            planItem("1", "COUNTDOWN", type: "header", sequence: 1),
            planItem("2", "Countdown", type: "item", sequence: 2),
            planItem("3", "Living Hope", type: "song", sequence: 3, songID: "s1", ccli: 7106807, key: "B"),
            planItem("4", "Genesis 34", type: "item", sequence: 4),
        ],
        serviceTypeName: "Sunday Morning", rules: rules, existing: []
    ) { item in item.song?.ccliNumber == 7106807 ? ("living-hope", "arr") : nil }

    #expect(items.map(\.itemKind) == [.header, .media, .presentation, .info])
    #expect(items[1].refId == "countdown-video")
    #expect(items[2].refId == "living-hope" && items[2].arrangementId == "arr")
    #expect(items[2].mxuSongKey == "B")
    #expect(items.allSatisfy { $0.mxuItemHexId != nil })
}

@Test func resyncKeepsIdsManualLinksAndLocalItems() {
    var linked = ServiceItem(id: "keep-me", itemKind: .presentation, name: "Genesis 34", refId: "sermon-deck")
    linked.mxuPcoItemId = "4"
    linked.mxuItemHexId = "4"
    let local = ServiceItem(id: "local", itemKind: .presentation, name: "Baptism Video", refId: "v")
    let items = PCOPlanSync.items(
        for: [
            planItem("3", "Living Hope", type: "song", sequence: 1, songID: "s1"),
            planItem("4", "Genesis 34", type: "item", sequence: 2),
        ],
        serviceTypeName: nil, rules: ServiceLinkRules(id: "r", rules: []),
        existing: [linked, local]
    ) { _ in nil }
    #expect(items.map(\.id).contains("keep-me"))
    #expect(items.first { $0.id == "keep-me" }?.refId == "sermon-deck")
    #expect(items.last?.id == "local", "a local item stays after the synced item it followed")
}

@Test func arrangementFollowsPCOSequence() {
    let sections = [
        PresentationSection(id: "v1", name: "Verse 1"),
        PresentationSection(id: "c", name: "Chorus"),
        PresentationSection(id: "b", name: "Bridge"),
    ]
    let order = PCOPlanSync.arrangement(
        named: "Phil Wickham", sequence: ["V1", "Chorus", "Verse 1", "C", "Bridge", "Chorus"], sections: sections)
    #expect(order?.sectionIds == ["v1", "c", "v1", "c", "b", "c"])
}

@Test func decodesSongsAndArrangements() throws {
    let songs = """
    {"data":[{"type":"Song","id":"23035018","attributes":{"title":"Holy Forever","author":"Chris Tomlin","ccli_number":7201044}}],"links":{}}
    """
    let document = try JSONDecoder().decode(PCOClient.Document.self, from: Data(songs.utf8))
    let song = PCOClient.song(document.data[0])
    #expect(song.title == "Holy Forever" && song.ccliNumber == 7201044)

    let arrangements = """
    {"data":[{"type":"Arrangement","id":"1","attributes":{"name":"Chris Tomlin","chord_chart_key":"Bb","bpm":72,"meter":"4/4",
    "sequence":["Verse 1","Chorus","Verse 2","Chorus","Bridge"],
    "chord_chart":"VERSE 1\\nBb          F\\nA thousand generations\\n\\nCHORUS\\nEb         Bb\\nHoly forever",
    "lyrics":null}}]}
    """
    let arrangement = PCOClient.arrangement(
        try JSONDecoder().decode(PCOClient.Document.self, from: Data(arrangements.utf8)).data[0])
    #expect(arrangement.sequence.count == 5 && arrangement.chordChartKey == "Bb" && arrangement.bpm == 72)
    let presentation = LyricTextImporter.makePresentation(
        ChordChartImport.chordPro(fromChart: arrangement.chordChart ?? ""), fallbackTitle: "Holy Forever")
    let order = PCOPlanSync.arrangement(
        named: arrangement.name, sequence: arrangement.sequence, sections: presentation.sections ?? [])
    #expect(order?.sectionIds.count == 3, "Verse 1, Chorus, Chorus — Verse 2 and Bridge aren't in this short chart")
    #expect(presentation.slides.contains { !($0.objects.first?.chords ?? []).isEmpty })
}
