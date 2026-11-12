import Foundation
@testable import PresenterCore
import Testing

struct SharedPlanItemsTests {
    private func item(_ id: String, _ kind: ServiceItemKind = .info, _ name: String, ref: String = "") -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: name, refId: ref)
    }

    private var sunday: Service {
        Service(id: "plan", name: "Sunday", serviceDate: "2026-11-15", items: [
            item("pre", .presentation, "Announcements Loop", ref: "preDeck"),
            item("song1", .presentation, "Glorious Day", ref: "gd"),
            item("ann", .info, "Announcements"),
            item("song2", .presentation, "The Lord Is With Me", ref: "lord"),
            item("h", .header, "MESSAGE"),
            item("msg", .presentation, "Genesis 40-41", ref: "gen40"),
            item("closeHeader", .header, "CLOSING"),
            item("close", .info, "Closing"),
        ])
    }

    private let links: [SharedPlanItems.Slot: String] = [.announcements: "annDeck", .closing: "closeDeck"]

    @Test func namesAreReadLooselyButNotThePreServiceLoop() {
        #expect(SharedPlanItems.slot(forItemNamed: "Announcements") == .announcements)
        #expect(SharedPlanItems.slot(forItemNamed: "ANNOUNCEMENTS") == .announcements)
        #expect(SharedPlanItems.slot(forItemNamed: "Weekly Announcements") == .announcements)
        #expect(SharedPlanItems.slot(forItemNamed: "Closing") == .closing)
        #expect(SharedPlanItems.slot(forItemNamed: "Closing Slides") == .closing)
        #expect(SharedPlanItems.slot(forItemNamed: "Announcements Loop") == nil)
        #expect(SharedPlanItems.slot(forItemNamed: "Pre-Service") == nil)
        #expect(SharedPlanItems.slot(forItemNamed: "Transition") == nil, "StandingItems places the Transition")
        #expect(SharedPlanItems.slot(forItemNamed: "Fall Festival announcement video") == nil)
    }

    @Test func unlinkedItemsLinkToTheSharedPresentations() {
        #expect(SharedPlanItems.slotsNeedingLink(sunday) == [.announcements, .closing])
        let plan = SharedPlanItems.linking(sunday, to: links)!
        #expect(plan.items[2].itemKind == .presentation && plan.items[2].refId == "annDeck")
        #expect(plan.items[7].itemKind == .presentation && plan.items[7].refId == "closeDeck")
        // Headers, the pre-service loop, songs and the message are untouched.
        #expect(plan.items[6].itemKind == .header && plan.items[6].refId.isEmpty)
        #expect(plan.items[0].refId == "preDeck" && plan.items[1].refId == "gd" && plan.items[5].refId == "gen40")
        #expect(SharedPlanItems.slotsNeedingLink(plan).isEmpty)
        #expect(SharedPlanItems.linking(plan, to: links) == nil)
    }

    @Test func templatesAreLinkedSoNewPlansStartLinked() {
        var template = sunday
        template.isTemplate = true
        let linked = SharedPlanItems.linking(template, to: links)!
        #expect(linked.items[2].refId == "annDeck" && linked.items[7].refId == "closeDeck")
    }

    @Test func aLinkMadeByHandIsLeftAlone() {
        var linked = sunday
        linked.items[2].itemKind = .presentation
        linked.items[2].refId = "somethingElse"
        let plan = SharedPlanItems.linking(linked, to: links)!
        #expect(plan.items[2].refId == "somethingElse")
        #expect(SharedPlanItems.linking(sunday, to: [:]) == nil)
    }

    @Test func everyMacPicksTheSameSharedPresentation() {
        let candidates = [
            SharedPlanItems.Candidate(id: "b", name: "Announcements"),
            SharedPlanItems.Candidate(id: "a", name: "ANNOUNCEMENTS"),
            SharedPlanItems.Candidate(id: "c", name: "Announcements Loop"),
            SharedPlanItems.Candidate(id: "d", name: "Closing"),
            SharedPlanItems.Candidate(id: "e", name: "Transition"),
        ]
        #expect(SharedPlanItems.sharedID(.announcements, candidates: candidates) == "a")
        #expect(SharedPlanItems.sharedID(.closing, candidates: candidates) == "d")
        #expect(SharedPlanItems.sharedID(.transition, candidates: candidates) == "e")
        #expect(SharedPlanItems.sharedID(.announcements, candidates: [candidates[2]]) == nil)
    }

    @Test func newPresentationsAreEmptyAndTyped() {
        let announcements = SharedPlanItems.newPresentation(.announcements, id: "new")
        #expect(announcements.name == "Announcements" && announcements.slides.isEmpty)
        #expect(announcements.category == PresentationTypes.announcements)
        #expect(SharedPlanItems.newPresentation(.closing).name == "Closing")
        #expect(SharedPlanItems.newPresentation(.transition).name == "Transition")
    }

    @Test func aPlanWantsATransitionUntilItHasOneOrItWasTakenOut() {
        #expect(SharedPlanItems.wantsTransition(sunday))
        let withOne = StandingItems.ensuring(sunday, transitionID: "bumper", walkoutID: nil, messageItemID: "msg")!
        #expect(!SharedPlanItems.wantsTransition(withOne))
        var removed = sunday
        removed.transitionRemoved = true
        #expect(!SharedPlanItems.wantsTransition(removed))
        var template = sunday
        template.isTemplate = true
        #expect(!SharedPlanItems.wantsTransition(template))
    }
}
