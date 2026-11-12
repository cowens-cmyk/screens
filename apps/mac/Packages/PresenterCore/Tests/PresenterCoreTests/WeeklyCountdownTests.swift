import Foundation
import Testing
@testable import PresenterCore

private var eastern: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    eastern.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private func counter() -> () -> String {
    var next = 0
    return { next += 1; return "id\(next)" }
}

private let sundays = WeeklyCountdown.Setup(
    series: .serviceType("Sunday Morning Worship"), days: [1],
    startTimes: ["11:10", "07:55", "09:25"], startDay: "2026-11-15", fallbackVideoID: "veil")

@Test func oneTriggerPerStartTimeEarliestFirst() {
    let made = WeeklyCountdown.triggers(for: sundays, makeID: counter())
    #expect(made.map(\.name) == ["Countdown 7:55 AM", "Countdown 9:25 AM", "Countdown 11:10 AM"])
    #expect(made.allSatisfy(WeeklyCountdown.isWeeklyCountdown))
    #expect(made.allSatisfy(ServiceDay.firesOnlyOnServiceMac))
    let action = made[0].actions[0]
    #expect(action.kind == .fireServiceItem)
    #expect(action.planSeries == "Sunday Morning Worship")
    #expect(action.serviceItemRole == "countdown")
    #expect(action.serviceItemId == nil)
    #expect(action.serviceItemRefId == "veil")
    #expect(PlanSchedule.upcoming(made[0], after: at(11, 12, 12, 0), count: 2, calendar: eastern)
        == [at(11, 15, 7, 55), at(11, 22, 7, 55)])
}

@Test func theSetupReadsBackFromItsTriggers() {
    var setup = sundays
    setup.everyWeeks = 2
    setup.endDay = "2027-05-30"
    let made = WeeklyCountdown.triggers(for: setup, makeID: counter())
    let read = WeeklyCountdown.setup(from: made.reversed(), today: "2026-11-12")
    setup.startTimes = ["07:55", "09:25", "11:10"]
    #expect(read == setup)
}

@Test func noTriggersNoSetup() {
    #expect(WeeklyCountdown.setup(from: [], today: "2026-11-12") == nil)
}

@Test func savingAgainRewritesInPlaceAndKeepsOnOff() {
    var existing = WeeklyCountdown.triggers(for: sundays, makeID: counter())
    existing[1].enabled = false
    #expect(WeeklyCountdown.changes(from: existing, to: sundays).isEmpty)

    var fewer = sundays
    fewer.startTimes = ["08:00", "09:30"]
    let changes = WeeklyCountdown.changes(from: existing, to: fewer, makeID: counter())
    #expect(changes.creates.isEmpty)
    #expect(changes.updates.map(\.id) == ["id1", "id2"])
    #expect(changes.updates[1].enabled == false)
    #expect(changes.updates[0].conditions[0].timeOfDay == "08:00")
    #expect(changes.deletes == ["id3"])

    let removed = WeeklyCountdown.changes(from: existing, to: nil)
    #expect(removed.deletes.count == 3)
}

@Test func aPlanWithItsOwnStartTimeCountdownKeepsIt() {
    let own = ServiceCountdown.trigger(
        planID: "p15", planName: "Sunday", countdownItemID: "cd",
        start: at(11, 15, 10, 25), serviceTime: at(11, 15, 10, 30), calendar: eastern)
    #expect(WeeklyCountdown.planHasItsOwn("p15", on: "2026-11-15", triggers: [own], calendar: eastern))
    #expect(!WeeklyCountdown.planHasItsOwn("p15", on: "2026-11-22", triggers: [own], calendar: eastern))
    #expect(!WeeklyCountdown.planHasItsOwn("p22", on: "2026-11-15", triggers: [own], calendar: eastern))
}

@Test func theCountdownIsFoundInEachWeeksPlan() {
    var countdown = ServiceItem(id: "b2", itemKind: .media, name: "Countdown", refId: "")
    countdown.isCountdown = true
    var plan = Service(id: "p22", name: "Nov 22", serviceDate: "2026-11-22", items: [
        ServiceItem(id: "b1", itemKind: .presentation, name: "Pre-Service", refId: "deck"), countdown,
    ])
    plan.mxuServiceTypeName = "Sunday Morning Worship"
    let action = WeeklyCountdown.triggers(for: sundays)[0].actions[0]
    let resolved = PlanSchedule.resolve(
        action, on: "2026-11-22", plans: ["p22": plan], kindOf: { $0 == "veil" ? .media : nil })
    guard case .plays(let found, let item) = resolved else { Issue.record("should play"); return }
    #expect(found.id == "p22")
    #expect(item.id == "b2")
    #expect(item.refId == "veil")
}

@Test func theBoardGathersThemAndDropsEmptyFolders() {
    let board = SchedulerBoard(id: "b", nodes: ["x", "c1", "c2"], folders: [])
    let placed = board.placingWeeklyCountdowns(triggerIDs: ["c1", "c2"])
    #expect(placed?.nodes == [WeeklyCountdown.folderID, "x"])
    #expect(placed?.folder(id: WeeklyCountdown.folderID)?.triggerIds == ["c1", "c2"])
    #expect(placed?.placingWeeklyCountdowns(triggerIDs: ["c1", "c2"]) == nil)
    var emptied = placed!
    emptied.folders[0].triggerIds = []
    #expect(emptied.placingWeeklyCountdowns(triggerIDs: [])?.folder(id: WeeklyCountdown.folderID) == nil)

    let old = SchedulerBoard(id: "b", nodes: [ServiceDay.folderID, "x"], folders: [
        ScheduleFolder(id: ServiceDay.folderID, name: ServiceDay.folderName, triggerIds: []),
    ])
    #expect(old.removingEmptyServiceDayFolder()?.nodes == ["x"])
}

@Test func daysInWords() {
    #expect(WeeklyCountdown.daysLabel(sundays) == "Sundays")
    var two = sundays
    two.days = [1, 4]
    two.everyWeeks = 2
    #expect(WeeklyCountdown.daysLabel(two) == "Every 2 weeks on Sundays and Wednesdays")
}
