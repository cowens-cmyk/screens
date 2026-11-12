import Foundation
import Testing
@testable import PresenterCore

private var eastern: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    eastern.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func trigger(_ when: PlanSchedule.When) -> ScheduleTrigger {
    ScheduleTrigger(
        id: "t", name: "t", conditions: [PlanSchedule.condition(for: when, id: "c", calendar: eastern)],
        actions: [], enabledUntil: PlanSchedule.enabledUntil(for: when))
}

private func item(_ id: String, _ name: String, kind: ServiceItemKind = .presentation, ref: String = "") -> ServiceItem {
    ServiceItem(id: id, itemKind: kind, name: name, refId: ref)
}

private func countdown(_ id: String, ref: String = "") -> ServiceItem {
    var item = ServiceItem(id: id, itemKind: .media, name: "Countdown", refId: ref)
    item.isCountdown = true
    return item
}

private func plan(
    _ id: String, _ date: String, type: String? = "Sunday Morning Worship", name: String? = nil,
    template: Bool = false, items: [ServiceItem]
) -> Service {
    var plan = Service(id: id, name: name ?? "\(date) plan", serviceDate: date, items: items)
    plan.mxuServiceTypeName = type
    plan.isTemplate = template ? true : nil
    return plan
}

private func byID(_ plans: [Service]) -> [String: Service] {
    Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
}

private let kinds: @Sendable (String) -> ServiceItemKind? = { ref in
    ref.hasPrefix("video") ? .media : ref.hasPrefix("deck") ? .presentation : nil
}

// MARK: When

@Test func everyOtherWeekCountsFromTheStartWeek() {
    // Sunday Nov 15, then Nov 29 and Dec 13; never Nov 22.
    let when = PlanSchedule.When(
        repeats: .weekly, days: [1], everyWeeks: 2, time: "09:25", startDay: "2026-11-15")
    let dates = PlanSchedule.upcoming(trigger(when), after: at(2026, 11, 12, 12, 0), count: 3, calendar: eastern)
    #expect(dates == [at(2026, 11, 15, 9, 25), at(2026, 11, 29, 9, 25), at(2026, 12, 13, 9, 25)])
}

@Test func everyOtherWeekKeepsTwoDaysInTheSameWeek() {
    // Started on a Wednesday: that week's Wednesday, then Sunday and
    // Wednesday two weeks on.
    let when = PlanSchedule.When(
        repeats: .weekly, days: [1, 4], everyWeeks: 2, time: "18:00", startDay: "2026-11-11")
    let dates = PlanSchedule.upcoming(trigger(when), after: at(2026, 11, 10, 12, 0), count: 3, calendar: eastern)
    #expect(dates == [at(2026, 11, 11, 18, 0), at(2026, 11, 22, 18, 0), at(2026, 11, 25, 18, 0)])
}

@Test func nothingBeforeTheStartDay() {
    let when = PlanSchedule.When(repeats: .daily, time: "08:00", startDay: "2026-12-01")
    let dates = PlanSchedule.upcoming(trigger(when), after: at(2026, 11, 12, 12, 0), count: 1, calendar: eastern)
    #expect(dates == [at(2026, 12, 1, 8, 0)])
}

@Test func anEndDayStopsAfterItsLastRun() {
    let when = PlanSchedule.When(
        repeats: .weekly, days: [1], time: "09:25", startDay: "2026-11-15", endDay: "2026-11-22")
    let dates = PlanSchedule.upcoming(trigger(when), after: at(2026, 11, 12, 12, 0), count: 5, calendar: eastern)
    #expect(dates == [at(2026, 11, 15, 9, 25), at(2026, 11, 22, 9, 25)])
    #expect(PlanSchedule.enabledUntil(for: when) == "2026-11-22T23:59:59")
}

@Test func neverEndingHasNoEnd() {
    let when = PlanSchedule.When(repeats: .weekly, days: [1], time: "09:25", startDay: "2026-11-15")
    #expect(PlanSchedule.enabledUntil(for: when) == nil)
    #expect(PlanSchedule.upcoming(trigger(when), after: at(2026, 11, 12, 12, 0), count: 10, calendar: eastern).count == 10)
}

@Test func onceRunsOnItsDayAndHasNoEnd() {
    let when = PlanSchedule.When(repeats: .never, time: "19:00", startDay: "2026-12-24", endDay: "2027-01-01")
    let made = trigger(when)
    #expect(made.conditions.first?.kind == .oneTime)
    #expect(made.enabledUntil == nil)
    #expect(PlanSchedule.upcoming(made, after: at(2026, 11, 12, 12, 0), count: 3, calendar: eastern) == [at(2026, 12, 24, 19, 0)])
}

@Test func weeklyWithNoDaysRunsOnTheStartDaysWeekday() {
    let when = PlanSchedule.When(repeats: .weekly, days: [], time: "09:00", startDay: "2026-11-18")
    #expect(PlanSchedule.condition(for: when, calendar: eastern).days == [4])
}

@Test func theSheetReadsBackWhatItWrote() {
    for when in [
        PlanSchedule.When(repeats: .never, time: "19:00", startDay: "2026-12-24"),
        PlanSchedule.When(repeats: .daily, time: "08:00", startDay: "2026-12-01", endDay: "2027-01-01"),
        PlanSchedule.When(repeats: .weekly, days: [1, 4], everyWeeks: 3, time: "09:25:30", startDay: "2026-11-15"),
    ] {
        #expect(PlanSchedule.when(from: trigger(when), today: "2026-11-12", calendar: eastern) == when)
    }
}

@Test func anOlderWeeklyTriggerStartsToday() {
    let old = ScheduleTrigger(
        id: "t", name: "t", conditions: [ScheduleCondition(id: "c", kind: .weekly, days: [1], timeOfDay: "09:00")],
        actions: [])
    let when = PlanSchedule.when(from: old, today: "2026-11-12", calendar: eastern)
    #expect(when == PlanSchedule.When(repeats: .weekly, days: [1], time: "09:00", startDay: "2026-11-12"))
}

@Test func otherConditionsStayInTheFullEditor() {
    let timer = ScheduleTrigger(
        id: "t", name: "t", conditions: [ScheduleCondition(id: "c", kind: .timerReaches)], actions: [])
    #expect(PlanSchedule.when(from: timer, today: "2026-11-12") == nil)
}

@Test func describesTheRuleInWords() {
    let today = "2026-11-12"
    #expect(PlanSchedule.describe(
        .init(repeats: .weekly, days: [1], time: "09:25", startDay: "2026-11-12"), today: today, calendar: eastern)
        == "Every Sunday at 9:25 AM")
    #expect(PlanSchedule.describe(
        .init(repeats: .weekly, days: [1, 4], everyWeeks: 2, time: "18:00", startDay: "2026-11-15", endDay: "2026-12-31"),
        today: today, calendar: eastern)
        == "Every 2 weeks on Sunday and Wednesday at 6:00 PM, starting Nov 15, until Dec 31")
    #expect(PlanSchedule.describe(
        .init(repeats: .never, time: "19:00", startDay: "2026-12-24"), today: today, calendar: eastern)
        == "Once, Thu, Dec 24 at 7:00 PM")
}

// MARK: What

private let sunday15 = plan("p15", "2026-11-15", items: [
    item("a1", "Pre-Service", ref: "deck-pre"), countdown("a2", ref: "video-veil"),
    item("a3", "Announcements", ref: "deck-ann"),
])
private let sunday22 = plan("p22", "2026-11-22", items: [
    item("b1", "Pre-Service", ref: "deck-pre"), countdown("b2"),
    item("b3", "Announcements", ref: "deck-ann"),
])
private let wednesday = plan("w18", "2026-11-18", type: "Wednesday Night", items: [countdown("c2", ref: "video-wed")])
private let template = plan("tmpl", "2026-11-01", name: "Sunday Morning Worship Template", template: true, items: [
    item("t1", "Pre-Service", ref: "deck-pre"), countdown("t2", ref: "video-veil"),
    item("t3", "Announcements", ref: "deck-ann"),
])
private let library = byID([sunday15, sunday22, wednesday, template])

@Test func aTemplateItemPlaysFromThatDaysPlan() {
    let action = PlanSchedule.action(playing: template.items[1], from: .template(id: "tmpl", serviceType: "Sunday Morning Worship"))
    #expect(PlanSchedule.source(of: action) == .template(id: "tmpl", serviceType: "Sunday Morning Worship"))
    guard case .plays(let plan, let played) = PlanSchedule.resolve(action, on: "2026-11-15", plans: library, kindOf: kinds)
    else { Issue.record("should play"); return }
    #expect(plan.id == "p15")
    #expect(played.id == "a2")
    #expect(played.refId == "video-veil")
}

@Test func aCountdownWithNoVideoYetPlaysTheTemplatesInItsPlace() {
    let action = PlanSchedule.action(playing: template.items[1], from: .template(id: "tmpl", serviceType: "Sunday Morning Worship"))
    guard case .plays(let plan, let played) = PlanSchedule.resolve(action, on: "2026-11-22", plans: library, kindOf: kinds)
    else { Issue.record("should play"); return }
    #expect(plan.id == "p22")
    #expect(played.id == "b2")
    #expect(played.refId == "video-veil")
    #expect(played.itemKind == .media)
}

@Test func aServiceTypeSeriesSkipsOtherServicesAndEmptyDays() {
    let action = PlanSchedule.action(playing: sunday15.items[2], from: .serviceType("Sunday Morning Worship"))
    #expect(PlanSchedule.resolve(action, on: "2026-11-18", plans: library, kindOf: kinds)
        == .skipped(reason: "No Sunday Morning Worship plan that day."))
    guard case .plays(let plan, let played) = PlanSchedule.resolve(action, on: "2026-11-22", plans: library, kindOf: kinds)
    else { Issue.record("should play"); return }
    #expect(plan.id == "p22")
    #expect(played.id == "b3")
}

@Test func runNowUsesTheNextPlanWhenThereIsNoneToday() {
    let action = PlanSchedule.action(playing: sunday15.items[2], from: .serviceType("Sunday Morning Worship"))
    guard case .plays(let plan, _) = PlanSchedule.resolve(
        action, on: "2026-11-16", plans: library, upcomingIfNone: true, kindOf: kinds)
    else { Issue.record("should play"); return }
    #expect(plan.id == "p22")
}

@Test func oneChosenPlanPlaysWhateverTheDay() {
    let action = PlanSchedule.action(playing: sunday15.items[2], from: .plan(id: "p15"))
    #expect(!PlanSchedule.repeatsAcrossPlans(action))
    guard case .plays(let plan, let played) = PlanSchedule.resolve(action, on: "2026-11-20", plans: library, kindOf: kinds)
    else { Issue.record("should play"); return }
    #expect(plan.id == "p15")
    #expect(played.id == "a3")
}

@Test func anItemFoundByItsPresentationThenByName() {
    var action = PlanSchedule.action(playing: item("x", "Welcome", ref: "deck-ann"), from: .serviceType("Sunday Morning Worship"))
    #expect(PlanSchedule.item(for: action, in: sunday22)?.id == "b3")
    action.serviceItemRefId = nil
    action.serviceItemName = " announcements "
    #expect(PlanSchedule.item(for: action, in: sunday22)?.id == "b3")
}

@Test func anItemThePlanLacksIsSaidPlainly() {
    let action = PlanSchedule.action(playing: item("x", "Baptism Video", ref: "video-baptism"), from: .serviceType("Sunday Morning Worship"))
    #expect(PlanSchedule.resolve(action, on: "2026-11-15", plans: library, kindOf: kinds)
        == .skipped(reason: "2026-11-15 plan has no Baptism Video."))
}

@Test func aTemplateWithNoServiceTypeMatchesByNameThenALonePlan() {
    let bare = plan("bare", "2026-11-01", type: nil, name: "Christmas Eve Template", template: true, items: [countdown("k1", ref: "video-xmas")])
    let eve = plan("eve", "2026-12-24", type: nil, name: "Christmas Eve", items: [countdown("e1")])
    let action = PlanSchedule.action(playing: bare.items[0], from: .template(id: "bare", serviceType: nil))
    #expect(action.planSeries == "")
    #expect(PlanSchedule.source(of: action) == .template(id: "bare", serviceType: nil))
    #expect(PlanSchedule.dayPlan(for: action, on: "2026-12-24", plans: byID([bare, eve]))?.id == "eve")
    // Renamed, but the only plan that day.
    var renamed = eve
    renamed.name = "Candlelight"
    #expect(PlanSchedule.dayPlan(for: action, on: "2026-12-24", plans: byID([bare, renamed]))?.id == "eve")
}

@Test func theOpenPlanWinsWhenTwoShareADay() {
    let early = plan("e", "2026-11-15", name: "A", items: [countdown("e1", ref: "video-1")])
    let late = plan("l", "2026-11-15", name: "B", items: [countdown("l1", ref: "video-2")])
    let action = PlanSchedule.action(playing: early.items[0], from: .serviceType("Sunday Morning Worship"))
    let plans = byID([early, late])
    #expect(PlanSchedule.dayPlan(for: action, on: "2026-11-15", plans: plans)?.id == "e")
    #expect(PlanSchedule.dayPlan(for: action, on: "2026-11-15", plans: plans, currentID: "l")?.id == "l")
}

@Test func pinningPointsTheRouterAtThisWeeksItem() {
    let action = PlanSchedule.action(playing: template.items[1], from: .template(id: "tmpl", serviceType: "Sunday Morning Worship"))
    let pinned = PlanSchedule.pinned(action, plan: sunday22, item: sunday22.items[1])
    #expect(pinned.serviceId == "p22")
    #expect(pinned.serviceItemId == "b2")
    #expect(pinned.planSeries == nil)
    #expect(pinned.serviceItemRefId == "video-veil")
}
