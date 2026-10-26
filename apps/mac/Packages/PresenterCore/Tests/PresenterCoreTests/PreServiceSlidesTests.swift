import Foundation
@testable import PresenterCore
import Testing

struct PreServiceSlidesTests {
    private let song = ServiceItem(id: "s", itemKind: .presentation, name: "Song", refId: "song-deck")

    private func plan(_ items: [ServiceItem], template: Bool = false) -> Service {
        var plan = Service(id: "plan", name: "Sunday", serviceDate: "2026-11-01", items: items)
        if template { plan.isTemplate = true }
        return plan
    }

    // MARK: Which slideshow

    @Test func theServiceDaySlideshowWinsWhileItIsInTheLibrary() {
        let candidates = [PreServiceSlides.Candidate(id: "named", name: "Pre-Service")]
        #expect(PreServiceSlides.sharedID(serviceDayID: "chosen", inLibrary: { $0 == "chosen" }, candidates: candidates) == "chosen")
        #expect(PreServiceSlides.sharedID(serviceDayID: "gone", inLibrary: { _ in false }, candidates: candidates) == "named",
                "a setup slideshow that's been deleted falls back to the name")
        #expect(PreServiceSlides.sharedID(serviceDayID: "", inLibrary: { _ in true }, candidates: candidates) == "named")
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: []) == nil)
    }

    @Test func amongSeveralThePlainNameComesFirstTheSameOnEveryMac() {
        let candidates = [
            PreServiceSlides.Candidate(id: "old", name: "Pre-Service Old"),
            PreServiceSlides.Candidate(id: "foldered", name: "Loop", subkind: "Pre-Service"),
            PreServiceSlides.Candidate(id: "plain", name: "Pre Service"),
            PreServiceSlides.Candidate(id: "songs", name: "Living Hope"),
        ]
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: candidates) == "plain")
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: candidates.reversed()) == "plain",
                "library order doesn't matter")
        let noPlain = candidates.filter { $0.id != "plain" }
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: noPlain) == "old",
                "a name before a folder")
        let twins = [PreServiceSlides.Candidate(id: "b", name: "Pre-Service"), PreServiceSlides.Candidate(id: "a", name: "Pre-Service")]
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: twins) == "a")
        #expect(PreServiceSlides.sharedID(serviceDayID: nil, inLibrary: { _ in true }, candidates: twins.reversed()) == "a")
    }

    @Test func aNewSlideshowIsEmptyAndLoopsEveryTenSeconds() {
        let deck = PreServiceSlides.newSlideshow(id: "new")
        #expect(deck.name == "Pre-Service")
        #expect(deck.slides.isEmpty)
        #expect(deck.autoAdvance == AutoAdvance(delaySeconds: 10, loopToStart: true))
        #expect(ServiceDay.loopingAdvance(deck.autoAdvance) == nil, "already what Service Day wants")
    }

    // MARK: Insert or mark

    @Test func aPlanGetsTheSlideshowFirstOnce() {
        let ensured = PreServiceSlides.ensuring(plan([song]), sharedID: "pre")!
        #expect(ensured.items.count == 2)
        let item = ensured.items[0]
        #expect(item.isPreService == true)
        #expect(item.itemKind == .presentation)
        #expect(item.refId == "pre", "a link to the shared slideshow, not a copy")
        #expect(item.name == "Pre-Service")
        #expect(PreServiceSlides.isShared(item))
        #expect(PreServiceSlides.ensuring(ensured, sharedID: "pre") == nil, "a second pass changes nothing")
    }

    @Test func withNoSlideshowThereIsNothingToAdd() {
        #expect(PreServiceSlides.change(for: plan([song]), sharedID: nil) == nil)
        #expect(PreServiceSlides.change(for: plan([song]), sharedID: "") == nil)
    }

    @Test func anItemLinkedToTheSlideshowIsMarkedNotDoubled() {
        let linked = ServiceItem(id: "l", itemKind: .presentation, name: "Walk-in", refId: "pre")
        let service = plan([song, linked])
        #expect(PreServiceSlides.change(for: service, sharedID: "pre") == .mark(itemID: "l", link: nil))
        let marked = PreServiceSlides.ensuring(service, sharedID: "pre")!
        #expect(marked.items.map(\.id) == ["s", "l"], "a marked item stays where it is")
        #expect(PreServiceSlides.item(in: marked)?.id == "l")
        #expect(PreServiceSlides.ensuring(marked, sharedID: "pre") == nil)
    }

    @Test func namedItemsInAnySpellingAreTakenForIt() {
        for name in ["Pre-Service", "PRE-SERVICE", "Preservice", "Pre Service", "pre service loop", "Announcements Loop", "Pre-Service Slides"] {
            #expect(PreServiceSlides.looksLikePreServiceItem(name), "\(name)")
            let shepherd = ServiceItem(id: "n", itemKind: .info, name: name, refId: "")
            let service = plan([shepherd, song])
            #expect(PreServiceSlides.change(for: service, sharedID: "pre") == .mark(itemID: "n", link: "pre"), "\(name)")
            let marked = PreServiceSlides.ensuring(service, sharedID: "pre")!
            #expect(marked.items.count == 2)
            #expect(marked.items[0].isPreService == true)
            #expect(marked.items[0].itemKind == .presentation)
            #expect(marked.items[0].refId == "pre")
        }
        for name in ["Announcements", "Pre-Service Prayer Meeting", "Service", "Welcome"] {
            #expect(!PreServiceSlides.looksLikePreServiceItem(name), "\(name)")
        }
    }

    @Test func aHeaderIsOnlyAHeading() {
        let header = ServiceItem(id: "h", itemKind: .header, name: "Pre-Service", refId: "")
        let change = PreServiceSlides.change(for: plan([header, song]), sharedID: "pre", makeID: { "new" })
        guard case .insert(let item)? = change else {
            Issue.record("expected an insert, got \(String(describing: change))")
            return
        }
        #expect(item.id == "new")
    }

    @Test func aNamedItemLinkedElsewhereIsLeftAndNoSecondAdded() {
        let own = ServiceItem(id: "o", itemKind: .presentation, name: "Pre-Service", refId: "this-weeks-copy")
        #expect(PreServiceSlides.change(for: plan([own, song]), sharedID: "pre") == nil)
    }

    @Test func aNamedItemWithNoSlideshowYetIsMarkedThenLinkedLater() {
        let shepherd = ServiceItem(id: "n", itemKind: .info, name: "Pre-Service", refId: "")
        let marked = PreServiceSlides.ensuring(plan([shepherd, song]), sharedID: nil)!
        #expect(marked.items[0].isPreService == true)
        #expect(marked.items[0].refId.isEmpty)
        #expect(!PreServiceSlides.isShared(marked.items[0]))
        #expect(PreServiceSlides.ensuring(marked, sharedID: nil) == nil)
        #expect(PreServiceSlides.change(for: marked, sharedID: "pre") == .mark(itemID: "n", link: "pre"))
        let linked = PreServiceSlides.ensuring(marked, sharedID: "pre")!
        #expect(linked.items[0].refId == "pre")
        #expect(linked.items.count == 2)
    }

    @Test func aMarkedItemOnAnotherSlideshowIsLeftByThePass() {
        var item = ServiceItem(id: "p", itemKind: .presentation, name: "Pre-Service", refId: "older")
        item.isPreService = true
        #expect(PreServiceSlides.change(for: plan([item, song]), sharedID: "pre") == nil)
        // Choosing a different slideshow in the Service Day setup moves it.
        let relinked = PreServiceSlides.relinking(plan([item, song]), to: "pre")!
        #expect(relinked.items[0].refId == "pre")
        #expect(PreServiceSlides.relinking(relinked, to: "pre") == nil)
        #expect(PreServiceSlides.relinking(plan([song]), to: "pre") == nil)
    }

    // MARK: Order with the countdown

    @Test func itComesBeforeTheCountdownWhicheverIsAddedFirst() {
        // Slideshow first, then the countdown.
        var service = PreServiceSlides.ensuring(plan([song]), sharedID: "pre")!
        service = ServiceCountdown.ensuringCountdown(service)!
        #expect(service.items.map { $0.isPreService == true ? "pre" : $0.isCountdown == true ? "countdown" : $0.id }
            == ["pre", "countdown", "s"])

        // Countdown first, then the slideshow.
        var other = ServiceCountdown.ensuringCountdown(plan([song]))!
        other = PreServiceSlides.ensuring(other, sharedID: "pre")!
        #expect(other.items.map { $0.isPreService == true ? "pre" : $0.isCountdown == true ? "countdown" : $0.id }
            == ["pre", "countdown", "s"])

        // Both worked out from the same plan and applied in one write, as the app does.
        let fresh = plan([song])
        let preChange = PreServiceSlides.change(for: fresh, sharedID: "pre")!
        let countdownChange = ServiceCountdown.change(for: fresh)!
        var both = fresh
        #expect(PreServiceSlides.apply(preChange, to: &both))
        #expect(ServiceCountdown.apply(countdownChange, to: &both))
        #expect(both.items.map { $0.isPreService == true ? "pre" : $0.isCountdown == true ? "countdown" : $0.id }
            == ["pre", "countdown", "s"])
        #expect(PreServiceSlides.change(for: both, sharedID: "pre") == nil)
        #expect(ServiceCountdown.change(for: both) == nil)
    }

    // MARK: Removal

    @Test func takingItOutIsRemembered() {
        var service = PreServiceSlides.ensuring(plan([song]), sharedID: "pre")!
        let id = service.items[0].id
        PreServiceSlides.remove(itemID: id, from: &service)
        #expect(service.items.map(\.id) == ["s"])
        #expect(service.preServiceRemoved == true)
        #expect(service.countdownRemoved == nil)
        #expect(PreServiceSlides.change(for: service, sharedID: "pre") == nil)

        // Something else taken out isn't remembered as the slideshow.
        var other = plan([song])
        PreServiceSlides.remove(itemID: "s", from: &other)
        #expect(other.preServiceRemoved == nil)

        // Taking out the countdown is still remembered the countdown's way.
        var withCountdown = ServiceCountdown.ensuringCountdown(plan([song]))!
        PreServiceSlides.remove(itemID: ServiceCountdown.item(in: withCountdown)!.id, from: &withCountdown)
        #expect(withCountdown.countdownRemoved == true)
        #expect(withCountdown.preServiceRemoved == nil)
    }

    @Test func aRemovedPlanStillTakesAnItemThatIsPlainlyTheSlideshow() {
        var service = plan([song, ServiceItem(id: "l", itemKind: .presentation, name: "Loop", refId: "pre")])
        service.preServiceRemoved = true
        #expect(PreServiceSlides.change(for: service, sharedID: "pre") == .mark(itemID: "l", link: nil))
    }

    @Test func anInsertWorkedOutEarlierIsDroppedWhenTheSlideshowArrivedMeanwhile() {
        let fresh = plan([song])
        let change = PreServiceSlides.change(for: fresh, sharedID: "pre")!
        var meanwhile = fresh
        meanwhile.items.append(ServiceItem(id: "other-mac", itemKind: .presentation, name: "Pre-Service", refId: "pre"))
        #expect(!PreServiceSlides.apply(change, to: &meanwhile))
        #expect(meanwhile.items.count == 2)
        var removed = fresh
        removed.preServiceRemoved = true
        #expect(!PreServiceSlides.apply(change, to: &removed))
    }

    // MARK: Templates

    @Test func templatesGetItAndPlansMadeFromThemDontGetASecond() {
        let template = PreServiceSlides.ensuring(plan([song], template: true), sharedID: "pre")!
        #expect(PreServiceSlides.item(in: template)?.refId == "pre")
        #expect(ServiceCountdown.change(for: template) == nil, "templates still get no countdown")

        var ids = 0
        let made = PlanTemplate.planItems(from: template, isMessage: { _ in false }, makeID: { ids += 1; return "copy-\(ids)" })
        var newPlan = template
        newPlan.isTemplate = nil
        newPlan.items = made.items
        #expect(made.items.map(\.id) == ["copy-1", "copy-2"])
        #expect(PreServiceSlides.item(in: newPlan)?.refId == "pre")
        #expect(PreServiceSlides.ensuring(newPlan, sharedID: "pre") == nil, "no second slideshow")
        #expect(newPlan.items.filter { $0.refId == "pre" }.count == 1)
    }

    // MARK: Never copied

    @Test func makingAPlanFromATemplateNeverCopiesTheSlideshow() {
        var template = PreServiceSlides.ensuring(plan([song], template: true), sharedID: "pre")!
        // Even a template that names the slideshow as its message, or a
        // message test that matches everything, leaves it shared.
        template.messagePresentationId = "pre"
        let made = PlanTemplate.planItems(from: template, isMessage: { _ in true })
        let preItem = made.items.first { $0.isPreService == true }!
        #expect(preItem.refId == "pre")
        #expect(!made.messageItemIDs.contains(preItem.id))
        #expect(made.messageItemIDs.count == 1, "the song is the only one the test calls a message")

        // The message itself still gets its own.
        var sermon = template
        sermon.messagePresentationId = "message-deck"
        sermon.items.append(ServiceItem(id: "m", itemKind: .presentation, name: "Message", refId: "message-deck"))
        let withMessage = PlanTemplate.planItems(from: sermon, isMessage: { _ in false })
        #expect(withMessage.messageItemIDs.count == 1)
        #expect(withMessage.items.first { withMessage.messageItemIDs.contains($0.id) }?.refId == "message-deck")
    }

    @Test func shepherdResyncKeepsTheSharedLinkOverALinkRule() {
        let rules = ServiceLinkRules(id: "r", rules: [
            ServiceLinkRule(id: "1", normalizedName: ServiceLinkLogic.normalize("Pre-Service"), serviceTypeName: nil,
                            itemKind: .presentation, refId: "some-other-deck"),
        ])
        let feed = [PlanFeed.Item(id: "1", title: "Pre-Service", itemType: "item")]

        // First sync: the rule links it; the pass then sees a named item
        // linked elsewhere and leaves it.
        let first = PlanItemSync.items(for: feed, serviceTypeName: nil, rules: rules, existing: []) { _ in nil }
        #expect(first[0].refId == "some-other-deck")

        // Once it's the shared slideshow, a re-sync keeps it there.
        var shared = first[0]
        shared.isPreService = true
        shared.refId = "pre"
        let again = PlanItemSync.items(for: feed, serviceTypeName: nil, rules: rules, existing: [shared]) { _ in nil }
        #expect(again[0].isPreService == true)
        #expect(again[0].refId == "pre")
        #expect(again[0].id == shared.id)

        // An item the pass put first, local to Screens, stays first.
        let inserted = PreServiceSlides.ensuring(plan(again.filter { $0.isPreService != true }), sharedID: "pre")!
        let local = inserted.items[0]
        let resynced = PlanItemSync.items(for: feed, serviceTypeName: nil, rules: ServiceLinkRules(id: "r", rules: []),
                                          existing: inserted.items) { _ in nil }
        #expect(resynced.first?.id == local.id)
        #expect(resynced.first?.refId == "pre")
    }
}
