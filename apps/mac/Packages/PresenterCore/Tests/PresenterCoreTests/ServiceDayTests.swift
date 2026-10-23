import Foundation
@testable import PresenterCore
import Testing

struct ServiceDayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ stamp: String) -> Date {
        ScheduleMath.parseLocalDate(stamp, calendar: calendar)!
    }

    private func ids(_ prefix: String = "id") -> () -> String {
        var next = 0
        return {
            next += 1
            return "\(prefix)\(next)"
        }
    }

    private func settings(
        _ times: [(String, String)], days: [Int]? = [1], deck: String? = "deck", clear: Bool? = nil
    ) -> ServiceDaySettings {
        ServiceDaySettings(
            services: times.enumerated().map { ServiceDayTime(id: "s\($0.offset)", serviceTime: $0.element.0, restartTime: $0.element.1) },
            days: days, preServicePresentationId: deck, clearFirst: clear)
    }

    // MARK: Defaults

    @Test func defaultsAreSundayAtEightNineThirtyAndElevenFifteen() {
        let defaults = ServiceDay.defaultSettings(preServicePresentationId: "deck", makeID: ids())
        #expect(defaults.days == [1])
        #expect(defaults.services.map(\.serviceTime) == ["08:00", "09:30", "11:15"])
        // The first service has nothing before it; later ones start once
        // the one before is usually out.
        #expect(defaults.services.map(\.restartTime) == ["07:30", "09:05", "10:50"])
        #expect(defaults.clearFirst == true)
        #expect(defaults.preServicePresentationId == "deck")
    }

    @Test func anAddedServiceFollowsTheLastOne() {
        let added = ServiceDay.nextService(after: settings([("08:00", "07:30"), ("09:30", "09:05")]).services, makeID: ids())
        #expect(added.serviceTime == "11:15")
        #expect(added.restartTime == "10:50")
        let first = ServiceDay.nextService(after: [], makeID: ids())
        #expect(first.serviceTime == "10:00")
        #expect(first.restartTime == "09:30")
    }

    @Test func timesReadAndWrite() {
        #expect(ServiceDay.secondsOfDay("08:00") == 8 * 3600)
        #expect(ServiceDay.secondsOfDay("07:54:50") == 7 * 3600 + 54 * 60 + 50)
        #expect(ServiceDay.secondsOfDay("25:00") == nil)
        #expect(ServiceDay.timeString(secondsOfDay: -15 * 60) == "23:45", "wraps back past midnight")
        #expect(ServiceDay.restartTime(forService: "00:10", isFirst: true) == "23:40")
        #expect(ServiceDay.displayTime("08:00") == "8:00 AM")
        #expect(ServiceDay.displayTime("12:05") == "12:05 PM")
        #expect(ServiceDay.displayTime("00:00") == "12:00 AM")
        #expect(ServiceDay.displayTime("18:30:15") == "6:30:15 PM")
    }

    @Test func thePreServiceSlideshowIsFoundByName() {
        #expect(ServiceDay.looksLikePreService("Pre-Service"))
        #expect(ServiceDay.looksLikePreService("pre service loop"))
        #expect(ServiceDay.looksLikePreService("PreService"))
        #expect(!ServiceDay.looksLikePreService("Service Order"))
        let candidates = [
            ServiceDay.Candidate(id: "song", name: "Amazing Grace", autoAdvances: true),
            ServiceDay.Candidate(id: "plain", name: "Pre-Service", autoAdvances: false),
            ServiceDay.Candidate(id: "loop", name: "Pre Service Loop", autoAdvances: true),
        ]
        #expect(ServiceDay.suggestedPresentation(candidates) == "loop", "one that already advances wins")
        #expect(ServiceDay.suggestedPresentation(Array(candidates.prefix(2))) == "plain")
        #expect(ServiceDay.suggestedPresentation(Array(candidates.prefix(1))) == nil)
    }

    @Test func theSlideshowLoopsEveryTenSecondsUnlessItHasItsOwnTiming() {
        #expect(ServiceDay.loopingAdvance(nil) == AutoAdvance(delaySeconds: 10, loopToStart: true))
        #expect(ServiceDay.loopingAdvance(AutoAdvance(delaySeconds: 8)) == AutoAdvance(delaySeconds: 8, loopToStart: true))
        #expect(ServiceDay.loopingAdvance(AutoAdvance(delaySeconds: 8, loopToStart: true)) == nil)
    }

    // MARK: Triggers

    @Test func eachServiceGetsAWeeklyRestartThatClearsThenStartsTheSlides() {
        let made = ServiceDay.triggers(for: settings([("09:30", "09:05"), ("08:00", "07:30")], days: [1, 7]), makeID: ids("t"))
        #expect(made.count == 2)
        #expect(made.map(\.name) == ["Pre-Service for 8:00 AM", "Pre-Service for 9:30 AM"], "in time order")
        let first = made[0]
        #expect(first.notes == "preservice:s1")
        #expect(ServiceDay.isRestartTrigger(first))
        #expect(ServiceDay.serviceID(of: first) == "s1")
        #expect(first.conditions.count == 1)
        #expect(first.conditions[0].kind == .weekly)
        #expect(first.conditions[0].days == [1, 7])
        #expect(first.conditions[0].timeOfDay == "07:30")
        #expect(first.actions.map(\.kind) == [.clearAll, .firePresentation])
        #expect(first.actions[1].presentationId == "deck")
        #expect(first.actions[1].slideIndex == 0)
        #expect(first.actions[1].serviceId == nil, "the slideshow plays on its own, the plan stays as it is")
        #expect(ScheduleMath.nextDue(for: first, after: date("2026-10-24T12:00:00"), calendar: calendar) == date("2026-10-25T07:30:00"))
    }

    @Test func clearingIsAChoiceAndNoSlideshowMeansNoTriggers() {
        let kept = ServiceDay.triggers(for: settings([("08:00", "07:30")], clear: false), makeID: ids())
        #expect(kept[0].actions.map(\.kind) == [.firePresentation])
        #expect(ServiceDay.triggers(for: settings([("08:00", "07:30")], deck: nil), makeID: ids()).isEmpty)
        #expect(ServiceDay.triggers(for: settings([("08:00", "07:30")], deck: ""), makeID: ids()).isEmpty)
        #expect(ServiceDay.triggers(for: settings([("8 am", "07:30")]), makeID: ids()).isEmpty, "a time that doesn't read is skipped")
    }

    @Test func savingTheSameSetupAgainChangesNothing() {
        let setup = settings([("08:00", "07:30"), ("09:30", "09:05"), ("11:15", "10:50")])
        let first = ServiceDay.changes(from: [], to: setup, makeID: ids("t"))
        #expect(first.creates.count == 3)
        #expect(first.updates.isEmpty && first.deletes.isEmpty)
        let other = ScheduleTrigger(id: "other", name: "Other", conditions: [], actions: [], notes: "countdown:plan")
        let again = ServiceDay.changes(from: first.creates + [other], to: setup, makeID: ids("u"))
        #expect(again.isEmpty)
    }

    @Test func editingReplacesInPlaceKeepingOnOffAndRemovesWhatsGone() {
        let before = settings([("08:00", "07:30"), ("09:30", "09:05"), ("11:15", "10:50")])
        var existing = ServiceDay.changes(from: [], to: before, makeID: ids("t")).creates
        existing[1].enabled = false
        existing[1].disabledUntil = "2026-10-25T12:00"
        let countdown = ScheduleTrigger(id: "cd", name: "Countdown", conditions: [], actions: [], notes: "countdown:plan")

        // 9:30's restart moves; 11:15 goes; a 6:00 PM service is added.
        var after = before
        after.services[1].restartTime = "09:10"
        after.services.remove(at: 2)
        after.services.append(ServiceDayTime(id: "evening", serviceTime: "18:00", restartTime: "17:30"))
        let changes = ServiceDay.changes(from: existing + [countdown], to: after, makeID: ids("n"))

        #expect(changes.updates.count == 1)
        #expect(changes.updates[0].id == existing[1].id, "rewritten in place")
        #expect(changes.updates[0].conditions[0].timeOfDay == "09:10")
        #expect(changes.updates[0].enabled == false, "its on/off is the operator's")
        #expect(changes.updates[0].disabledUntil == "2026-10-25T12:00")
        #expect(changes.deletes == [existing[2].id], "the countdown is never touched")
        #expect(changes.creates.map(\.notes) == ["preservice:evening"])
        #expect(changes.creates[0].id == "n1")
    }

    @Test func choosingAnotherSlideshowRewritesEveryRestart() {
        let before = settings([("08:00", "07:30"), ("09:30", "09:05")])
        let existing = ServiceDay.changes(from: [], to: before, makeID: ids("t")).creates
        var after = before
        after.preServicePresentationId = "new-deck"
        let changes = ServiceDay.changes(from: existing, to: after, makeID: ids())
        #expect(changes.updates.count == 2)
        #expect(changes.updates.allSatisfy { $0.actions.last?.presentationId == "new-deck" })
        var none = before
        none.preServicePresentationId = nil
        #expect(Set(ServiceDay.changes(from: existing, to: none, makeID: ids()).deletes) == Set(existing.map(\.id)))
    }

    // MARK: The board

    @Test func restartsGatherInTheServiceDayFolderFirstOnTheBoard() {
        let made = ServiceDay.triggers(for: settings([("08:00", "07:30"), ("09:30", "09:05")]), makeID: ids("t"))
        let order = ServiceDay.restartTriggerIDs(made.reversed() + [ScheduleTrigger(id: "x", name: "X", conditions: [], actions: [])])
        #expect(order == ["t1", "t2"])

        var board = SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: ["x", "f", "t2"], folders: [
            ScheduleFolder(id: "f", name: "Other", triggerIds: ["t1", "y"]),
        ])
        board = board.placingServiceDay(triggerIDs: order)!
        #expect(board.nodes == [ServiceDay.folderID, "x", "f"])
        #expect(board.folder(id: ServiceDay.folderID)?.triggerIds == ["t1", "t2"])
        #expect(board.folder(id: ServiceDay.folderID)?.name == "Service Day")
        #expect(board.folder(id: "f")?.triggerIds == ["y"])
        #expect(board.placingServiceDay(triggerIDs: order) == nil, "in place: no write")
        #expect(board.placingServiceDay(triggerIDs: []) == nil)

        // Something the operator filed in the folder stays, after them.
        board.moveTrigger(id: "x", intoFolder: ServiceDay.folderID)
        #expect(board.placingServiceDay(triggerIDs: order) == nil)
        #expect(board.folder(id: ServiceDay.folderID)?.triggerIds == ["t1", "t2", "x"])
    }

    // MARK: The day at a glance

    @Test func theDayReadsInOrderWithTheScheduledCountdowns() {
        let setup = settings([("08:00", "07:30"), ("09:30", "09:05"), ("11:15", "10:50")])
        let countdowns = [date("2026-10-25T07:54:50"), date("2026-10-25T09:24:50"), date("2026-11-01T07:55:00")]
        // Friday: the coming Sunday, whole.
        let day = ServiceDay.upcomingDay(setup, countdownStarts: countdowns, after: date("2026-10-23T12:00:00"), calendar: calendar)!
        #expect(day.day == date("2026-10-25T00:00:00"))
        #expect(day.events.map(\.kind) == [.preService, .countdown, .service, .preService, .countdown, .service, .preService, .service])
        #expect(day.events.first?.date == date("2026-10-25T07:30:00"))
        #expect(day.events[1].date == date("2026-10-25T07:54:50"))

        // Sunday mid-morning: what's left of today.
        let later = ServiceDay.upcomingDay(setup, countdownStarts: countdowns, after: date("2026-10-25T09:10:00"), calendar: calendar)!
        #expect(later.events.map(\.kind) == [.countdown, .service, .preService, .service])

        // After the last service: next Sunday.
        let next = ServiceDay.upcomingDay(setup, countdownStarts: countdowns, after: date("2026-10-25T11:20:00"), calendar: calendar)!
        #expect(next.day == date("2026-11-01T00:00:00"))
        #expect(next.events[1] == ServiceDay.Event(kind: .countdown, date: date("2026-11-01T07:55:00")))

        var noDeck = setup
        noDeck.preServicePresentationId = nil
        let bare = ServiceDay.upcomingDay(noDeck, countdownStarts: [], after: date("2026-10-23T12:00:00"), calendar: calendar)!
        #expect(bare.events.map(\.kind) == [.service, .service, .service])
        #expect(ServiceDay.upcomingDay(settings([]), countdownStarts: [], after: date("2026-10-23T12:00:00"), calendar: calendar) == nil)
    }

    // MARK: The guard

    @Test func theRestartTakesWhatAFinishedServiceLeaves() {
        typealias S = PreServiceGuard.Situation
        #expect(PreServiceGuard.decide(S()) == .restart, "nothing up")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 30, finalSlideIsUp: true)) == .restart, "the service just ended")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 5000, finalSlideIsUp: true, slideIsInLastItem: true)) == .restart, "left up and walked away")
        #expect(PreServiceGuard.decide(S(otherContentIsUp: true, finalSlideIsUp: true)) == .restart, "the plan's closing video has played")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 900, preServiceIsUp: true)) == .restart, "the slideshow stopped: start it over")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 900, preServiceIsUp: true, videoPlaying: true)) == .restart, "its own video doesn't hold it")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 30, finalSlideIsUp: true, slideIsInLastItem: true, messageIsUp: true, sermonTimerRunning: true)) == .restart, "the message ended the service")
        // The plan's last item left untouched for twenty minutes.
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: PreServiceGuard.longQuietSeconds, slideIsInLastItem: true)) == .restart)
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: PreServiceGuard.longQuietSeconds - 1, slideIsInLastItem: true)) != .restart)
    }

    @Test func theRestartLeavesAServiceThatsStillGoing() {
        typealias S = PreServiceGuard.Situation
        let midService = PreServiceGuard.Decision.skip("A slide from the service was still up.")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 60)) == midService)
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 600)) == midService, "a prayer slide up for ten minutes")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 3600)) == midService, "only the plan's last item has the long-quiet way out")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 600, slideIsInLastItem: true)) == midService)
        #expect(PreServiceGuard.decide(S(otherContentIsUp: true)) == .skip("Something was still on the screens."))
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 5000, slideIsInLastItem: true, messageIsUp: true, sermonTimerRunning: true)) == .skip("The message was up with its timer running."))
        #expect(PreServiceGuard.decide(S(videoPlaying: true)) == .skip("A video was playing."))
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 900, finalSlideIsUp: true, videoPlaying: true)) == .skip("A video was playing."), "a video in the last slide still going")
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 900, preServiceIsUp: true, videoPlaying: true, countdownPlaying: true)) == .skip("The countdown was playing."))
        #expect(PreServiceGuard.decide(S(secondsSinceSlideChange: 5, preServiceIsUp: true)) == .skip("The pre-service slides were already running."))
    }

    @Test func aLoopingBackgroundIsNotAVideoPlaying() {
        #expect(PreServiceGuard.countsAsPlaying(isPlaying: true, isLooping: false, foreground: false), "a slide's background video playing once")
        #expect(!PreServiceGuard.countsAsPlaying(isPlaying: true, isLooping: true, foreground: false), "a motion background")
        #expect(PreServiceGuard.countsAsPlaying(isPlaying: true, isLooping: true, foreground: true), "a looping video put up on its own")
        #expect(!PreServiceGuard.countsAsPlaying(isPlaying: false, isLooping: false, foreground: true), "paused or finished")
    }

    @Test func onlyTheServicesOwnTriggersWaitForTheServiceMac() {
        let restart = ServiceDay.triggers(for: settings([("08:00", "07:30")]), makeID: ids())[0]
        #expect(ServiceDay.firesOnlyOnServiceMac(restart))
        let countdown = ServiceCountdown.trigger(
            planID: "plan", planName: "Sunday", countdownItemID: "cd",
            start: date("2026-10-25T10:24:50"), serviceTime: date("2026-10-25T10:30:00"), calendar: calendar)
        #expect(ServiceDay.firesOnlyOnServiceMac(countdown))
        var other = countdown
        other.notes = "lights"
        #expect(!ServiceDay.firesOnlyOnServiceMac(other))
        other.notes = nil
        #expect(!ServiceDay.firesOnlyOnServiceMac(other))
    }
}
