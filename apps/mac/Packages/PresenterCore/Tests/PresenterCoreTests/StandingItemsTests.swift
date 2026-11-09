import Foundation
@testable import PresenterCore
import Testing

struct StandingItemsTests {
    private func item(_ id: String, _ kind: ServiceItemKind = .presentation, _ name: String = "", name label: String = "", ref: String = "") -> ServiceItem {
        let name = label.isEmpty ? name : label
        return ServiceItem(id: id, itemKind: kind, name: name.isEmpty ? id : name, refId: ref)
    }

    private var sunday: Service {
        Service(id: "plan", name: "Sunday", serviceDate: "2026-11-15", items: [
            item("pre", name: "Pre-Service", ref: "preDeck"),
            item("song1", name: "Glorious Day", ref: "gd"),
            item("h", .header, "MESSAGE"),
            item("msg", .info, "Genesis 40-41"),
            item("close", name: "The Lord Is With Me", ref: "lord"),
        ])
    }

    private func positions(_ plan: Service) -> [String: ServicePosition] {
        ServicePosition.positions(in: plan.items)
    }

    @Test func theMessageIsFoundUnderItsHeaderOrByThePlan() {
        #expect(StandingItems.messageItemID(in: sunday, positions: positions(sunday)) == "msg")
        var linked = sunday
        linked.items[4].refId = "sermon"
        linked.messagePresentationId = "sermon"
        #expect(StandingItems.messageItemID(in: linked, positions: positions(linked)) == "close")
    }

    @Test func aPlanGetsTheTransitionBeforeTheMessageAndTheWalkoutLast() {
        let message = StandingItems.messageItemID(in: sunday, positions: positions(sunday))
        let plan = StandingItems.ensuring(
            sunday, transitionID: "bumper", walkoutID: "logo", messageItemID: message, makeID: { "new" + String(Int.random(in: 0 ... 9999)) })!
        let names = plan.items.map(\.name)
        #expect(names == ["Pre-Service", "Glorious Day", "MESSAGE", "Transition", "Genesis 40-41", "The Lord Is With Me", "Walkout"])
        #expect(plan.items[3].isTransition == true && plan.items[3].refId == "bumper")
        #expect(plan.items.last?.isWalkout == true && plan.items.last?.refId == "logo")
        // Settled: the transition no longer counts as the message.
        let again = StandingItems.messageItemID(in: plan, positions: positions(plan))
        #expect(again == "msg")
        #expect(StandingItems.ensuring(plan, transitionID: "bumper", walkoutID: "logo", messageItemID: again) == nil)
    }

    @Test func noMessageNoTransition() {
        var plan = sunday
        plan.items.removeAll { $0.id == "msg" || $0.id == "h" }
        let out = StandingItems.ensuring(plan, transitionID: "bumper", walkoutID: nil, messageItemID: nil)
        #expect(out == nil)
    }

    @Test func nothingChosenNothingAddedAndTemplatesAreLeftAlone() {
        #expect(StandingItems.ensuring(sunday, transitionID: nil, walkoutID: "", messageItemID: "msg") == nil)
        var template = sunday
        template.isTemplate = true
        #expect(StandingItems.ensuring(template, transitionID: "b", walkoutID: "w", messageItemID: "msg") == nil)
    }

    @Test func aWalkoutLeftBehindByAReSyncMovesBackToTheEnd() {
        var plan = StandingItems.ensuring(sunday, transitionID: nil, walkoutID: "logo", messageItemID: nil, makeID: { "w" })!
        plan.items.append(item("late", name: "Baptism", ref: "bap"))
        let moved = StandingItems.ensuring(plan, transitionID: nil, walkoutID: "logo", messageItemID: nil)!
        #expect(moved.items.last?.id == "w")
        #expect(moved.items.dropLast().last?.id == "late")
    }

    @Test func namedItemsAreMarkedAndLinkedRatherThanAdded() {
        var plan = sunday
        plan.items.insert(item("t", .info, "Transition"), at: 3)
        plan.items.append(item("wo", .info, "Walk Out"))
        let out = StandingItems.ensuring(plan, transitionID: "bumper", walkoutID: "logo", messageItemID: "msg")!
        #expect(out.items.count == plan.items.count)
        #expect(out.items.first { $0.id == "t" }?.isTransition == true)
        #expect(out.items.first { $0.id == "t" }?.refId == "bumper")
        #expect(out.items.first { $0.id == "t" }?.itemKind == .presentation)
        #expect(out.items.last?.isWalkout == true && out.items.last?.refId == "logo")
    }

    @Test func takingOneOutIsRemembered() {
        var plan = StandingItems.ensuring(sunday, transitionID: "b", walkoutID: "w", messageItemID: "msg", makeID: { UUID().uuidString })!
        let transition = StandingItems.transition(in: plan)!.id
        let walkout = StandingItems.walkout(in: plan)!.id
        PreServiceSlides.remove(itemID: transition, from: &plan)
        PreServiceSlides.remove(itemID: walkout, from: &plan)
        #expect(plan.transitionRemoved == true && plan.walkoutRemoved == true)
        #expect(StandingItems.ensuring(plan, transitionID: "b", walkoutID: "w", messageItemID: "msg") == nil)
    }

    @Test func aNewChoiceRelinksThePlansItems() {
        let plan = StandingItems.ensuring(sunday, transitionID: "b", walkoutID: "w", messageItemID: "msg", makeID: { UUID().uuidString })!
        let relinked = StandingItems.relinking(plan, transitionID: "b2", walkoutID: "w")!
        #expect(StandingItems.transition(in: relinked)?.refId == "b2")
        #expect(StandingItems.walkout(in: relinked)?.refId == "w")
        #expect(StandingItems.relinking(relinked, transitionID: "b2", walkoutID: "w") == nil)
    }

    @Test func walkoutMinutesDefaultToEight() {
        #expect(StandingItems.walkoutReturnMinutes(nil) == 8)
        var settings = ServiceDaySettings(services: [])
        settings.walkoutReturnMinutes = 0
        #expect(StandingItems.walkoutReturnMinutes(settings) == 8)
        settings.walkoutReturnMinutes = 5
        #expect(StandingItems.walkoutReturnMinutes(settings) == 5)
    }
}

struct WalkoutReturnTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func returnsWhenTheWalkoutIsStillUp() {
        #expect(WalkoutReturn.decide(walkoutStillLive: true, runsService: true, now: now, nextCountdown: nil) == .returnToPreService)
        #expect(WalkoutReturn.decide(
            walkoutStillLive: true, runsService: true, now: now, nextCountdown: now.addingTimeInterval(600)) == .returnToPreService)
    }

    @Test func leavesItWhenSomethingElseTookOverOrTheCountdownIsClose() {
        if case .skip = WalkoutReturn.decide(walkoutStillLive: false, runsService: true, now: now, nextCountdown: nil) {} else { Issue.record() }
        if case .skip = WalkoutReturn.decide(walkoutStillLive: true, runsService: false, now: now, nextCountdown: nil) {} else { Issue.record() }
        if case .skip = WalkoutReturn.decide(
            walkoutStillLive: true, runsService: true, now: now, nextCountdown: now.addingTimeInterval(90)) {} else { Issue.record() }
    }
}

struct SermonTimerWorshipTests {
    private func timer(running: Bool, remaining: Double, elapsed: Double, duration: Double = 2400) -> SermonTimerReset.TimerState {
        .init(isRunning: running, remaining: remaining, elapsed: elapsed, duration: duration)
    }

    @Test func worshipBeforeTheMessageSetsARunTimerBack() {
        #expect(SermonTimerReset.decideOnWorship(
            timer(running: false, remaining: -60, elapsed: 2460), length: 2400,
            songIsBeforeMessage: true, cameFromMessage: false) == .reset)
        // Left running after the sermon: the next service has started.
        #expect(SermonTimerReset.decideOnWorship(
            timer(running: true, remaining: 300, elapsed: 2100), length: 2400,
            songIsBeforeMessage: true, cameFromMessage: false) == .reset)
        #expect(SermonTimerReset.decideOnWorship(
            timer(running: false, remaining: 1200, elapsed: 1200), length: 2400,
            songIsBeforeMessage: true, cameFromMessage: true) == .reset)
    }

    @Test func untouchedOrAfterTheMessageIsLeft() {
        #expect(SermonTimerReset.decideOnWorship(
            timer(running: false, remaining: 2400, elapsed: 0), length: 2400,
            songIsBeforeMessage: true, cameFromMessage: false) == .ready)
        #expect(SermonTimerReset.decideOnWorship(nil, length: 2400, songIsBeforeMessage: true, cameFromMessage: false) == .ready)
        if case .skip = SermonTimerReset.decideOnWorship(
            timer(running: false, remaining: -10, elapsed: 2410), length: 2400,
            songIsBeforeMessage: false, cameFromMessage: false) {} else { Issue.record() }
        // A slip back to a song mid-sermon doesn't stop the clock.
        if case .skip = SermonTimerReset.decideOnWorship(
            timer(running: true, remaining: 900, elapsed: 1500), length: 2400,
            songIsBeforeMessage: true, cameFromMessage: true) {} else { Issue.record() }
    }
}

struct MediaDetailsTests {
    private func media(_ kind: MediaKind, detail: String = MediaDetails.addedInBrowser, duration: Double? = nil) -> MediaItem {
        MediaItem(
            id: "m", name: "Bumper", mediaKind: kind, classification: .foreground, fileHash: "h", fileName: "Bumper.mov",
            fileStatus: .ready, statusDetail: detail, tags: [], favorite: false, collections: [], loops: false,
            durationSeconds: duration)
    }

    @Test func browserItemsAndLengthlessVideosAreRead() {
        #expect(MediaDetails.needsProbe(media(.image)))
        #expect(MediaDetails.needsProbe(media(.video, detail: "")))
        #expect(!MediaDetails.needsProbe(media(.video, detail: "", duration: 12)))
        #expect(!MediaDetails.needsProbe(media(.image, detail: "")))
    }

    @Test func whatTheFileSaysIsKeptAndItIsNotReadAgain() {
        let probe = MediaDetails.Probe(status: .ready, detail: "", duration: 31.5, width: 1920, height: 1080)
        let filled = MediaDetails.applying(probe, to: media(.video))
        #expect(filled.durationSeconds == 31.5 && filled.pixelWidth == 1920 && filled.statusDetail.isEmpty)
        #expect(!MediaDetails.needsProbe(filled))

        let unplayable = MediaDetails.applying(
            .init(status: .needsTranscode, detail: "unsupported codec: ap4h", duration: 10, width: nil, height: nil),
            to: media(.video))
        #expect(unplayable.fileStatus == .needsTranscode && !MediaDetails.needsProbe(unplayable))

        let lengthless = MediaDetails.applying(
            .init(status: .ready, detail: "", duration: nil, width: nil, height: nil), to: media(.video))
        #expect(!MediaDetails.needsProbe(lengthless))
    }
}
