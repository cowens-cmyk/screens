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

private func sunday(services: [String] = ["08:00", "09:30", "11:15"], days: [Int] = [1]) -> ServiceDaySettings {
    ServiceDaySettings(
        services: services.enumerated().map { ServiceDayTime(id: "s\($0.offset)", serviceTime: $0.element, restartTime: "07:00") },
        days: days)
}

/// A five-minute countdown ending at the service time.
private func countdown(_ service: String) -> SermonTimerReset.ScheduledCountdown {
    let time = date(service)
    return .init(start: ServiceCountdown.start(serviceTime: time, videoSeconds: 300), serviceTime: time)
}

@Suite struct SermonTimerResetTests {
    // 2026-10-25 is a Sunday.
    let day = date("2026-10-25T06:00:00")

    @Test func theServiceDaySetupGivesTheTimesWhenNothingElseDoes() {
        let services = SermonTimerReset.services(
            on: day, planTimes: [], scheduled: [], serviceDay: sunday(), calendar: calendar)
        #expect(services.map(\.time) == [date("2026-10-25T08:00:00"), date("2026-10-25T09:30:00"), date("2026-10-25T11:15:00")])
        #expect(services.allSatisfy { $0.source == .serviceDay && $0.countdownStart == nil })
        #expect(services.map(\.resetAt) == services.map(\.time), "with no countdown, the service time itself")

        let monday = SermonTimerReset.services(
            on: date("2026-10-26T06:00:00"), planTimes: [], scheduled: [], serviceDay: sunday(), calendar: calendar)
        #expect(monday.isEmpty, "not one of its days")
    }

    @Test func thePlansShepherdTimesComeFirst() {
        let plan = [date("2026-10-25T09:00:00"), date("2026-10-25T11:00:00"), date("2026-11-01T09:00:00")]
        let services = SermonTimerReset.services(
            on: day, planTimes: plan, scheduled: [countdown("2026-10-25T10:30:00")],
            serviceDay: sunday(), calendar: calendar)
        #expect(services.map(\.time) == [date("2026-10-25T09:00:00"), date("2026-10-25T11:00:00")], "today's only")
        #expect(services.allSatisfy { $0.source == .plan })
    }

    @Test func scheduleServiceComesNextWithItsCountdowns() {
        let services = SermonTimerReset.services(
            on: day, planTimes: [date("2026-11-01T09:00:00")],
            scheduled: [countdown("2026-10-25T09:30:00"), countdown("2026-10-25T08:00:00")],
            serviceDay: sunday(), calendar: calendar)
        #expect(services.map(\.time) == [date("2026-10-25T08:00:00"), date("2026-10-25T09:30:00")])
        #expect(services.map(\.source) == [.scheduled, .scheduled])
        #expect(services.map(\.resetAt) == [date("2026-10-25T07:55:00"), date("2026-10-25T09:25:00")], "when each countdown starts")
    }

    @Test func countdownsMatchTheTimesTheyEndAt() {
        // Shepherd says 8:00 and 9:30; only the 9:30 has a countdown.
        let services = SermonTimerReset.services(
            on: day, planTimes: [date("2026-10-25T09:30:00"), date("2026-10-25T08:00:00")],
            scheduled: [countdown("2026-10-25T09:30:00")], serviceDay: nil, calendar: calendar)
        #expect(services.map(\.countdownStart) == [nil, date("2026-10-25T09:25:00")])
        #expect(services.map(\.resetAt) == [date("2026-10-25T08:00:00"), date("2026-10-25T09:25:00")])

        // A countdown long before a service isn't its own.
        let early = SermonTimerReset.ScheduledCountdown(start: date("2026-10-25T08:30:00"), serviceTime: date("2026-10-25T08:35:00"))
        let late = SermonTimerReset.services(
            on: day, planTimes: [date("2026-10-25T09:30:00")], scheduled: [early], serviceDay: nil, calendar: calendar)
        #expect(late.first?.countdownStart == nil)
    }

    @Test func aDayWithNoTimesHasNoServices() {
        let services = SermonTimerReset.services(on: day, planTimes: [], scheduled: [], serviceDay: nil, calendar: calendar)
        #expect(services.isEmpty)
        #expect(SermonTimerReset.due(services, after: day, now: day.addingTimeInterval(3600)) == nil)
    }

    @Test func theSameTimeTwiceIsOneService() {
        let services = SermonTimerReset.services(
            on: day, planTimes: [date("2026-10-25T09:00:00"), date("2026-10-25T09:00:00")],
            scheduled: [], serviceDay: nil, calendar: calendar)
        #expect(services.count == 1)
    }

    @Test func serviceDayTimesHoldWhenTheClocksChange() {
        // 2026-11-01 the clocks go back at 2:00; 2026-03-08 they go forward.
        for stamp in ["2026-11-01T06:00:00", "2026-03-08T06:00:00"] {
            let times = SermonTimerReset.serviceDayTimes(sunday(services: ["08:00", "11:15"]), on: date(stamp), calendar: calendar)
            let clock = times.map { calendar.dateComponents([.hour, .minute], from: $0) }
            #expect(clock.map(\.hour) == [8, 11])
            #expect(clock.map(\.minute) == [0, 15])
        }
        // An early service in the repeated hour still lands on the day.
        let repeated = SermonTimerReset.serviceDayTimes(sunday(services: ["01:30"]), on: date("2026-11-01T06:00:00"), calendar: calendar)
        #expect(repeated.count == 1)
        #expect(calendar.isDate(repeated[0], inSameDayAs: date("2026-11-01T06:00:00")))
    }

    @Test func aStartIsDueOnceAndOnlyWhileRecent() {
        let services = SermonTimerReset.services(
            on: day, planTimes: [], scheduled: [countdown("2026-10-25T09:30:00")],
            serviceDay: nil, calendar: calendar)
        let start = date("2026-10-25T09:25:00")
        #expect(SermonTimerReset.due(services, after: start.addingTimeInterval(-5), now: start)?.time == date("2026-10-25T09:30:00"))
        #expect(SermonTimerReset.due(services, after: start, now: start.addingTimeInterval(5)) == nil, "already passed")
        #expect(SermonTimerReset.due(services, after: start.addingTimeInterval(-60), now: start.addingTimeInterval(9 * 60)) != nil,
                "a Mac waking a few minutes late still acts")
        #expect(SermonTimerReset.due(services, after: start.addingTimeInterval(-60), now: start.addingTimeInterval(11 * 60)) == nil,
                "too late: the service is under way")
        #expect(SermonTimerReset.next(services, after: date("2026-10-25T09:00:00"))?.resetAt == start)
        #expect(SermonTimerReset.next(services, after: start) == nil)
    }

    @Test func manyServicesInADayEachGetTheirTurn() {
        let services = SermonTimerReset.services(
            on: day, planTimes: [], scheduled: [], serviceDay: sunday(), calendar: calendar)
        var last = date("2026-10-25T07:00:00")
        var fired: [Date] = []
        var now = last
        while now < date("2026-10-25T12:00:00") {
            now = now.addingTimeInterval(5)
            if let due = SermonTimerReset.due(services, after: last, now: now) { fired.append(due.time) }
            last = now
        }
        #expect(fired == services.map(\.time))
    }

    // MARK: The guard

    private let length: Double = 40 * 60

    private func timer(running: Bool, elapsed: Double, duration: Double = 40 * 60) -> SermonTimerReset.TimerState {
        .init(isRunning: running, remaining: duration - elapsed, elapsed: elapsed, duration: duration)
    }

    @Test func aStoppedTimerIsSetBack() {
        #expect(SermonTimerReset.decide(timer(running: false, elapsed: 0), length: length, messageIsLive: false) == .ready)
        #expect(SermonTimerReset.decide(timer(running: false, elapsed: 600), length: length, messageIsLive: false) == .reset,
                "paused partway through the service before")
        #expect(SermonTimerReset.decide(timer(running: false, elapsed: 0, duration: 41 * 60), length: length, messageIsLive: false) == .reset,
                "a minute nudged on goes too")
        #expect(SermonTimerReset.decide(timer(running: false, elapsed: 0), length: 30 * 60, messageIsLive: false) == .reset,
                "this week's message is shorter")
        #expect(SermonTimerReset.decide(nil, length: length, messageIsLive: false) == .reset)
    }

    @Test func aSermonInProgressIsNeverTouched() {
        #expect(SermonTimerReset.decide(timer(running: true, elapsed: 600), length: length, messageIsLive: false)
                == .skip("The sermon timer was running."))
        #expect(SermonTimerReset.decide(timer(running: true, elapsed: 600), length: length, messageIsLive: true)
                == .skip("The message was up."))
    }

    @Test func overtimeFromTheServiceBeforeIsSetBack() {
        #expect(SermonTimerReset.decide(timer(running: true, elapsed: 50 * 60), length: length, messageIsLive: false) == .reset)
        #expect(SermonTimerReset.decide(timer(running: true, elapsed: 3 * 3600), length: length, messageIsLive: false) == .reset)
        #expect(SermonTimerReset.decide(timer(running: true, elapsed: 50 * 60), length: length, messageIsLive: true)
                == .skip("The message was up."), "still preaching, in overtime")
    }

    @Test func theCountdownLengthRoundTrips() {
        let service = date("2026-10-25T09:30:00")
        for seconds in [nil, 0, 300, 310.4] as [Double?] {
            let start = ServiceCountdown.start(serviceTime: service, videoSeconds: seconds)
            #expect(ServiceCountdown.serviceTime(start: start, videoSeconds: seconds) == service)
        }
    }

    @Test func resetSermonTimerHasAFreeKey() {
        let chord = KeyCommand.resetSermonTimer.defaultChords
        #expect(chord == [KeyChord("0", command: true, control: true)])
        #expect(KeyCommandMap().conflictedKeys().isEmpty)
    }
}
