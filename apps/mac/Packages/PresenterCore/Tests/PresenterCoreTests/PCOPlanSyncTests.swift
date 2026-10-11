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
