import Automerge
import Foundation
import Testing
@testable import PresenterCore

private func planItem(
    _ id: String, _ title: String, type: String,
    songID: String? = nil, ccli: Int? = nil, key: String? = nil
) -> PlanFeed.Item {
    PlanFeed.Item(
        id: id, title: title, itemType: type, keyName: key,
        song: songID.map { PlanFeed.Song(id: $0, title: title, ccliNumber: ccli) })
}

@Test func planOrderBecomesServiceWithRulesAndSongs() {
    let rules = ServiceLinkRules(id: "r", rules: [
        ServiceLinkRule(id: "1", normalizedName: "countdown", serviceTypeName: "Sunday Morning",
                        itemKind: .media, refId: "countdown-video"),
    ])
    let items = PlanItemSync.items(
        for: [
            planItem("1", "COUNTDOWN", type: "header"),
            planItem("2", "Countdown", type: "item"),
            planItem("3", "Living Hope", type: "song", songID: "s1", ccli: 7106807, key: "B"),
            planItem("4", "Genesis 34", type: "item"),
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
    linked.mxuSourceItemId = "4"
    linked.mxuItemHexId = "4"
    let local = ServiceItem(id: "local", itemKind: .presentation, name: "Baptism Video", refId: "v")
    let items = PlanItemSync.items(
        for: [
            planItem("3", "Living Hope", type: "song", songID: "s1"),
            planItem("4", "Genesis 34", type: "item"),
        ],
        serviceTypeName: nil, rules: ServiceLinkRules(id: "r", rules: []),
        existing: [linked, local]
    ) { _ in nil }
    #expect(items.map(\.id).contains("keep-me"))
    #expect(items.first { $0.id == "keep-me" }?.refId == "sermon-deck")
    #expect(items.last?.id == "local", "a local item stays after the synced item it followed")
}

@Test func resyncKeepsTheCountdownAndItsVideo() {
    let rules = ServiceLinkRules(id: "r", rules: [
        ServiceLinkRule(id: "1", normalizedName: "countdown", serviceTypeName: nil,
                        itemKind: .media, refId: "last-weeks-video"),
    ])
    var countdown = ServiceItem(id: "cd", itemKind: .media, name: "COUNTDOWN", refId: "this-weeks-video")
    countdown.mxuSourceItemId = "1"
    countdown.isCountdown = true
    let items = PlanItemSync.items(
        for: [planItem("1", "COUNTDOWN", type: "item"), planItem("2", "Welcome", type: "item")],
        serviceTypeName: nil, rules: rules, existing: [countdown]
    ) { _ in nil }
    #expect(items[0].id == "cd")
    #expect(items[0].isCountdown == true, "kept across the sync, like color and hidden")
    #expect(items[0].refId == "this-weeks-video", "the video picked in Screens, not the standing rule's")
    #expect(items[1].isCountdown == nil)

    // Not yet given a video: the rule still fills it in.
    countdown.refId = ""
    let unpicked = PlanItemSync.items(
        for: [planItem("1", "COUNTDOWN", type: "item")],
        serviceTypeName: nil, rules: rules, existing: [countdown]
    ) { _ in nil }
    #expect(unpicked[0].refId == "last-weeks-video" && unpicked[0].isCountdown == true)
}

@Test func resyncKeepsTheLightingChoiceAndMacros() {
    var song = ServiceItem(id: "song", itemKind: .presentation, name: "Living Hope", refId: "lh")
    song.mxuSourceItemId = "3"
    song.lightingCue = "communion"
    var macro = SlideAction(id: "a", kind: .fireCombo)
    macro.comboId = "c"
    song.actions = [macro]
    let items = PlanItemSync.items(
        for: [planItem("3", "Living Hope", type: "song", songID: "s1")],
        serviceTypeName: nil, rules: ServiceLinkRules(id: "r", rules: []), existing: [song]
    ) { _ in nil }
    #expect(items[0].lightingCue == "communion")
    #expect(items[0].actions?.first?.comboId == "c")
}

@Test func arrangementFollowsPlanSequence() {
    let sections = [
        PresentationSection(id: "v1", name: "Verse 1"),
        PresentationSection(id: "c", name: "Chorus"),
        PresentationSection(id: "b", name: "Bridge"),
    ]
    let order = PlanItemSync.arrangement(
        named: "Phil Wickham", sequence: ["V1", "Chorus", "Verse 1", "C", "Bridge", "Chorus"], sections: sections)
    #expect(order?.sectionIds == ["v1", "c", "v1", "c", "b", "c"])
    #expect(PlanItemSync.arrangement(named: "", sequence: ["Chorus"], sections: sections)?.name == "Shepherd")
}

/// Services synced before the rename stored their plan ids under mxuPco* keys;
/// they still decode, so re-sync keeps matching their items.
@Test func serviceItemReadsLegacySourceKeys() throws {
    let legacy = """
    {"id":"a","itemKind":"presentation","name":"Living Hope","refId":"song",
     "mxuPcoItemId":"plan-1","mxuPcoSongId":"s1","mxuPcoArrangementId":"arr","mxuPcoKeyId":"k"}
    """
    let item = try JSONDecoder().decode(ServiceItem.self, from: Data(legacy.utf8))
    #expect(item.mxuSourceItemId == "plan-1" && item.mxuSourceSongId == "s1" && item.mxuSourceArrangementId == "arr")

    let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
    #expect(encoded.contains(#""mxuSourceItemId":"plan-1""#) && !encoded.contains("mxuPco"))
    #expect(try JSONDecoder().decode(ServiceItem.self, from: Data(encoded.utf8)) == item)

    var both = item
    both.mxuSourceItemId = "new"
    let mixed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(both)) as! [String: Any]
    var withOld = mixed
    withOld["mxuPcoItemId"] = "old"
    let preferNew = try JSONDecoder().decode(
        ServiceItem.self, from: JSONSerialization.data(withJSONObject: withOld))
    #expect(preferNew.mxuSourceItemId == "new")
}

/// The same through Automerge, which is how services are stored: the old key
/// decodes, and saving drops it.
@Test func automergeServiceItemMigratesLegacyKeys() throws {
    let doc = Document()
    let encoder = AutomergeEncoder(doc: doc)
    try encoder.encode(LegacyServiceItem(
        id: "a", itemKind: "presentation", name: "Living Hope", refId: "song",
        mxuPcoItemId: "plan-1", mxuPcoSongId: "s1", mxuPcoArrangementId: "arr", mxuPcoKeyId: "k"))
    let item = try AutomergeDecoder(doc: doc).decode(ServiceItem.self)
    #expect(item.mxuSourceItemId == "plan-1" && item.mxuSourceSongId == "s1" && item.mxuSourceArrangementId == "arr")

    try encoder.encode(item)
    let keys = doc.keys(obj: .ROOT)
    #expect(keys.contains("mxuSourceItemId") && !keys.contains { $0.hasPrefix("mxuPco") })
    #expect(try AutomergeDecoder(doc: doc).decode(ServiceItem.self) == item)
}

private struct LegacyServiceItem: Codable {
    var id: String
    var itemKind: String
    var name: String
    var refId: String
    var mxuPcoItemId: String
    var mxuPcoSongId: String
    var mxuPcoArrangementId: String
    var mxuPcoKeyId: String
}
