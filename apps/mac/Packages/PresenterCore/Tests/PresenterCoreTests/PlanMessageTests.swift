import Testing
@testable import PresenterCore

@Suite struct PlanMessageTests {
    private func item(_ id: String, _ kind: ServiceItemKind = .presentation, name: String = "", ref: String = "",
                      shepherd: String? = nil, mxuKind: String? = nil, duration: Int? = nil) -> ServiceItem {
        var item = ServiceItem(id: id, itemKind: kind, name: name, refId: ref)
        item.mxuSourceItemId = shepherd
        item.mxuKind = mxuKind
        item.duration = duration
        return item
    }

    /// Nov 22: Transition (Screens' own) and Genesis 42-45 (Shepherd's)
    /// under MESSAGE; the message's slides are a plain presentation.
    @Test func shepherdsItemUnderTheMessageHeaderIsTheMessage() throws {
        var transition = item("t", name: "Transition", ref: "transition")
        transition.isTransition = true
        let plan = Service(id: "p", name: "Nov 22", serviceDate: "2026-11-22", items: [
            item("h1", .header, name: "WORSHIP", shepherd: "sh1", mxuKind: "header"),
            item("song", name: "Holy Forever", ref: "holy", shepherd: "sh2", mxuKind: "song", duration: 309),
            item("h2", .header, name: "MESSAGE", shepherd: "sh3", mxuKind: "header"),
            transition,
            item("m", name: "Genesis 42-45", ref: "genesis", shepherd: "sh4", mxuKind: "item", duration: 2400),
            item("h3", .header, name: "CLOSING SONG", shepherd: "sh5", mxuKind: "header"),
            item("close", name: "Close", ref: "closing", shepherd: "sh6", mxuKind: "item", duration: 120),
        ])
        let index = try #require(PlanMessage.plannedItemIndex(in: plan))
        #expect(plan.items[index].id == "m")
        #expect(PlanMessage.itemIndex(in: plan, isSermon: { _ in false }) == index)
        // A deck filed as the message still wins.
        #expect(PlanMessage.itemIndex(in: plan, isSermon: { $0 == "closing" }) == 6)
    }

    @Test func noMessageHeaderNoPlannedMessage() {
        let plan = Service(id: "p", name: "", serviceDate: "", items: [
            item("a", name: "Announcements", ref: "a", shepherd: "s1", mxuKind: "item", duration: 300),
        ])
        #expect(PlanMessage.plannedItemIndex(in: plan) == nil)
    }

    @Test func theLongestShepherdItemUnderMessageWins() {
        let plan = Service(id: "p", name: "", serviceDate: "", items: [
            item("h", .header, name: "MESSAGE", shepherd: "s0", mxuKind: "header"),
            item("bumper", name: "Bumper", ref: "b", shepherd: "s1", mxuKind: "item", duration: 90),
            item("sermon", name: "Sermon", ref: "s", shepherd: "s2", mxuKind: "item", duration: 2400),
        ])
        #expect(PlanMessage.plannedItemIndex(in: plan).map { plan.items[$0].id } == "sermon")
    }
}
