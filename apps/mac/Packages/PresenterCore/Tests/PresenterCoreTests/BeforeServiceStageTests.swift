import Foundation
import Testing

@testable import PresenterCore

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func date(_ stamp: String) -> Date {
    ScheduleMath.parseLocalDate(stamp, calendar: calendar)!
}

/// A Sunday with services at 9:30 and 11:15, the way the Service Day setup
/// or the plan's Shepherd times give them.
private func twoServices() -> [SermonTimerReset.Service] {
    [date("2026-10-25T09:30:00"), date("2026-10-25T11:15:00")].map {
        SermonTimerReset.Service(time: $0, countdownStart: $0.addingTimeInterval(-300), source: .plan)
    }
}

@Suite struct ServiceStartClockTests {
    @Test func theWalkInCountsToTheNextServiceNotItsCountdown() {
        let target = ServiceStartClock.target(twoServices(), now: date("2026-10-25T09:00:00"))
        #expect(target == date("2026-10-25T09:30:00"), "the service start, not the countdown's start")
    }

    @Test func theWalkoutCountsToTheNextServiceToday() {
        let target = ServiceStartClock.target(twoServices(), now: date("2026-10-25T10:40:00"))
        #expect(target == date("2026-10-25T11:15:00"))
    }

    @Test func afterTheLastServiceThereIsNothingToCountTo() {
        #expect(ServiceStartClock.target(twoServices(), now: date("2026-10-25T12:30:00")) == nil)
        #expect(ServiceStartClock.target([], now: date("2026-10-25T09:00:00")) == nil)
    }

    @Test func aWalkInRunningLateHoldsOnItsServiceRatherThanJumpingToTheNext() {
        let started = date("2026-10-25T09:30:00")
        #expect(ServiceStartClock.target(twoServices(), now: started.addingTimeInterval(1)) == started)
        #expect(ServiceStartClock.target(twoServices(), now: started.addingTimeInterval(9 * 60)) == started)
        // Ten minutes on it has long begun; the next service is the one to show.
        #expect(ServiceStartClock.target(twoServices(), now: started.addingTimeInterval(10 * 60))
                == date("2026-10-25T11:15:00"))
    }

    @Test func aLastServiceThatJustStartedHoldsThenGoesQuiet() {
        let started = date("2026-10-25T11:15:00")
        #expect(ServiceStartClock.target(twoServices(), now: started.addingTimeInterval(30)) == started)
        #expect(ServiceStartClock.target(twoServices(), now: started.addingTimeInterval(11 * 60)) == nil)
    }

    @Test func aServiceStartingRightAfterTheOneBeforeTakesOver() {
        let early = date("2026-10-25T09:00:00")
        let soon = date("2026-10-25T09:05:00")
        let services = [early, soon].map { SermonTimerReset.Service(time: $0, source: .plan) }
        #expect(ServiceStartClock.target(services, now: early.addingTimeInterval(60)) == soon)
    }

    @Test func theServicesNeedNotComeSorted() {
        let services = Array(twoServices().reversed())
        #expect(ServiceStartClock.target(services, now: date("2026-10-25T09:00:00")) == date("2026-10-25T09:30:00"))
    }
}

@Suite struct BeforeServiceStageTests {
    private func item(preService: Bool = false, walkout: Bool = false) -> ServiceItem {
        var item = ServiceItem(id: "i", itemKind: .presentation, name: "Item", refId: "d")
        item.isPreService = preService ? true : nil
        item.isWalkout = walkout ? true : nil
        return item
    }

    @Test func theWalkInSlideshowDoesHoweverItGoesUp() {
        #expect(BeforeServiceStage.applies(
            slideshow: true, item: nil, presentationID: "d", walkoutDeckID: nil, endOfPlan: false))
        #expect(BeforeServiceStage.applies(
            slideshow: false, item: item(preService: true), presentationID: "d", walkoutDeckID: nil, endOfPlan: false))
    }

    @Test func theWalkoutDoesOnEverySlideOfIt() {
        // Not only its last slide: a multi-slide walkout never shows the
        // Message timer or the lyrics layout under it.
        #expect(BeforeServiceStage.applies(
            slideshow: false, item: item(walkout: true), presentationID: "d", walkoutDeckID: nil, endOfPlan: false))
    }

    @Test func theServiceDaysWalkoutPutUpOnItsOwnDoesToo() {
        #expect(BeforeServiceStage.applies(
            slideshow: false, item: nil, presentationID: "w", walkoutDeckID: "w", endOfPlan: false))
        #expect(!BeforeServiceStage.applies(
            slideshow: false, item: nil, presentationID: "x", walkoutDeckID: "w", endOfPlan: false))
        #expect(!BeforeServiceStage.applies(
            slideshow: false, item: nil, presentationID: "", walkoutDeckID: "", endOfPlan: false), "an empty id is none")
    }

    @Test func theEndOfThePlanIsOnlyLookedAtWhenNothingElseDecided() {
        var asked = 0
        func endOfPlan() -> Bool { asked += 1; return true }
        // Results taken first: #expect would itself evaluate what it is given.
        let slideshow = BeforeServiceStage.applies(
            slideshow: true, item: nil, presentationID: "d", walkoutDeckID: nil, endOfPlan: endOfPlan())
        let askedForSlideshow = asked
        let other = BeforeServiceStage.applies(
            slideshow: false, item: item(), presentationID: "d", walkoutDeckID: nil, endOfPlan: endOfPlan())
        #expect(slideshow)
        #expect(askedForSlideshow == 0)
        #expect(other)
        #expect(asked == 1)
    }

    @Test func anythingElseTakesTheStageOffBeforeService() {
        #expect(!BeforeServiceStage.applies(
            slideshow: false, item: item(), presentationID: "d", walkoutDeckID: "w", endOfPlan: false))
    }
}

@Suite struct BeforeServiceLayoutTests {
    @Test func theLayoutIsOneBigCountdownAndNothingElse() throws {
        let layout = ConfidenceLayoutTemplate.preService.make(name: "Before Service")
        let timers = layout.objects.filter { $0.textLink?.source == .timer }
        #expect(timers.count == 1)
        let timer = try #require(timers.first)
        #expect(timer.textLink?.timerId == ConfidenceLayoutTemplate.untilServiceTimerID)
        #expect(timer.textLink?.usesWarningColor == false, "green to the end, never amber or red")
        #expect(timer.textStyle?.tabularFigures == true)
        #expect((timer.textStyle?.fontSize ?? 0) >= 500, "big enough to read from the back of the stage")
        let captions = layout.objects.filter { $0.name == "Caption" }.map(\.text)
        #expect(captions == ["SERVICE STARTS IN", "TIME"])
        // The countdown and its caption show only while a service is ahead;
        // the clock and its caption only when there is none.
        let whenRunning = layout.objects.filter {
            $0.visibilityConditions?.first?.state == .isRunning
        }
        let whenStopped = layout.objects.filter {
            $0.visibilityConditions?.first?.state == .isNotRunning
        }
        #expect(whenRunning.map(\.text) == ["SERVICE STARTS IN", ""])
        #expect(whenStopped.map(\.text) == ["TIME", ""])
        #expect(whenStopped.contains { $0.textLink?.source == .clock })
        #expect(layout.objects.allSatisfy {
            $0.visibilityConditions?.first?.timerId == ConfidenceLayoutTemplate.untilServiceTimerID
        })
    }

    @Test func theBuiltInDefaultIsTheNewDesign() {
        let layouts = BasicTemplates.stageLayouts()
        let preService = layouts.first { $0.id == BasicTemplates.preServiceStageID }
        #expect(preService?.objects.contains { $0.textLink?.timerId == ConfidenceLayoutTemplate.untilServiceTimerID } == true)
        #expect(preService?.objects.contains { $0.textLink?.timerId == ConfidenceLayoutTemplate.untilCountdownTimerID } == false)
    }

    @Test func anUntouchedOldLayoutTakesTheNewDesignOnce() throws {
        var saved = ConfidenceLayoutTemplate.legacyPreService(name: "Stage — Before Service")
        saved.id = BasicTemplates.preServiceStageID
        let upgraded = try #require(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: saved))
        #expect(upgraded.count == 4)
        var fresh = saved
        fresh.objects = upgraded
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: fresh) == nil, "once only")
    }

    @Test func anUntouchedOldLayoutSurvivesTheRoundTrip() throws {
        // What the library hands back: encoded and decoded, as it was stored.
        let saved = ConfidenceLayoutTemplate.legacyPreService(name: "Stage — Before Service")
        let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: stored) != nil)
    }

    @Test func aLayoutTheChurchChangedIsLeftAlone() {
        let base = ConfidenceLayoutTemplate.legacyPreService(name: "Stage — Before Service")

        var moved = base
        moved.objects[1].x = (moved.objects[1].x ?? 0) + 10
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: moved) == nil)

        var recolored = base
        recolored.objects[3].textStyle?.colorHex = "#FF0000FF"
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: recolored) == nil)

        var added = base
        added.objects.append(ConfidenceLayoutTemplate.linked(
            "Extra", .clock, x: 0, y: 0, width: 10, height: 10, size: 10))
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: added) == nil)

        var resized = base
        resized.canvasWidth = 3840
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: resized) == nil)

        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(
            for: ConfidenceLayoutTemplate.worship.make(name: "Stage — Before Service")) == nil)
    }

    @Test func aRenamedButUntouchedLayoutStillUpgrades() {
        let renamed = ConfidenceLayoutTemplate.legacyPreService(name: "Walk-in Screen")
        #expect(ConfidenceLayoutTemplate.upgradedPreServiceObjects(for: renamed) != nil)
    }
}
