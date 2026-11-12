import Foundation

/// A schedule made in the scheduler's Schedule sheet: one time rule (once,
/// every day, or some days of the week every week or every few weeks, from a
/// start date until an end date or for good) and one thing it plays: a
/// presentation from the library, an item in one plan, or an item in each
/// week's plan.
///
/// Each week's plan is the point. Sunday's plan is a new plan every week
/// (from Shepherd, or made from a template), so a schedule can't hold its id.
/// It holds the series instead (the service type, or the template) and what
/// the item is (the countdown, the pre-service slideshow, or the
/// presentation or video it plays), and finds both again on the day it runs.
/// The schedules are ordinary scheduler triggers, so the engine, history,
/// snooze and folders all work on them as on any other.
public enum PlanSchedule {

    // MARK: When

    public enum Repeat: String, CaseIterable, Sendable {
        case never, daily, weekly
    }

    public struct When: Equatable, Sendable {
        public var repeats: Repeat
        /// 1 is Sunday, as the scheduler counts days. Weekly only.
        public var days: [Int]
        /// Weekly only: 1 for every week, 2 for every other week.
        public var everyWeeks: Int
        /// "09:25", or "09:25:30" when the second matters.
        public var time: String
        /// "2026-11-15": the one day it runs, or the first day it can.
        public var startDay: String
        /// The last day it can run; nil when it never ends.
        public var endDay: String?

        public init(
            repeats: Repeat, days: [Int] = [], everyWeeks: Int = 1, time: String,
            startDay: String, endDay: String? = nil
        ) {
            self.repeats = repeats
            self.days = days
            self.everyWeeks = everyWeeks
            self.time = time
            self.startDay = startDay
            self.endDay = endDay
        }
    }

    /// The trigger condition for a rule. A weekly rule with no days picked
    /// runs on its start date's day.
    public static func condition(
        for when: When, id: String = UUID().uuidString, calendar: Calendar = .current
    ) -> ScheduleCondition {
        switch when.repeats {
        case .never:
            var condition = ScheduleCondition(id: id, kind: .oneTime)
            condition.date = when.startDay + "T" + when.time
            return condition
        case .daily:
            var condition = ScheduleCondition(
                id: id, kind: .weekly, days: Array(1 ... 7), timeOfDay: when.time)
            condition.startDate = when.startDay
            return condition
        case .weekly:
            var days = Array(Set(when.days.filter { (1 ... 7).contains($0) })).sorted()
            if days.isEmpty { days = [weekday(of: when.startDay, calendar: calendar) ?? 1] }
            var condition = ScheduleCondition(id: id, kind: .weekly, days: days, timeOfDay: when.time)
            condition.startDate = when.startDay
            condition.intervalWeeks = when.everyWeeks > 1 ? when.everyWeeks : nil
            return condition
        }
    }

    /// The trigger's end, the last second of the end day. A one-time rule
    /// has none: it runs once and goes to History.
    public static func enabledUntil(for when: When) -> String? {
        guard when.repeats != .never, let end = when.endDay, !end.isEmpty else { return nil }
        return end + "T23:59:59"
    }

    /// The rule a trigger runs on, when it is one the sheet can show: a
    /// single once or weekly condition. Nil for anything else (a timer, a
    /// calendar event, several conditions), which stays in the full editor.
    public static func when(from trigger: ScheduleTrigger, today: String, calendar: Calendar = .current) -> When? {
        guard trigger.conditions.count == 1, let condition = trigger.conditions.first else { return nil }
        let endDay = trigger.enabledUntil.map { String($0.prefix(10)) }
        switch condition.kind {
        case .oneTime:
            guard let raw = condition.date else { return nil }
            let parts = raw.split(separator: "T")
            guard parts.count == 2 else { return nil }
            return When(repeats: .never, time: String(parts[1]), startDay: String(parts[0]))
        case .weekly:
            let days = (condition.days?.isEmpty == false) ? condition.days! : Array(1 ... 7)
            let every = ScheduleMath.interval(of: condition)
            let start = condition.startDate.map { String($0.prefix(10)) } ?? today
            let time = condition.timeOfDay ?? "09:00"
            if Set(days) == Set(1 ... 7), every == 1 {
                return When(repeats: .daily, time: time, startDay: start, endDay: endDay)
            }
            return When(
                repeats: .weekly, days: days.sorted(), everyWeeks: every, time: time,
                startDay: start, endDay: endDay)
        case .timerReaches, .calendarEvent, .planTime:
            return nil
        }
    }

    /// "Every 2 weeks on Sunday and Wednesday at 9:25 AM, starting Nov 16,
    /// until Dec 31". The start shows only when it's after today.
    public static func describe(_ when: When, today: String, calendar: Calendar = .current) -> String {
        let time = ServiceDay.displayTime(when.time)
        var text: String
        switch when.repeats {
        case .never:
            return "Once, \(dayLabel(when.startDay, weekday: true, calendar: calendar)) at \(time)"
        case .daily:
            text = "Every day at \(time)"
        case .weekly:
            // Full English names whatever calendar it's given.
            var english = calendar
            english.locale = Locale(identifier: "en_US_POSIX")
            let names = condition(for: when, calendar: calendar).days?.compactMap { day -> String? in
                (1 ... 7).contains(day) ? english.weekdaySymbols[day - 1] : nil
            } ?? []
            let list = listed(names)
            text = when.everyWeeks > 1
                ? "Every \(when.everyWeeks) weeks on \(list) at \(time)"
                : "Every \(list) at \(time)"
        }
        if when.startDay > today {
            text += ", starting \(dayLabel(when.startDay, weekday: false, calendar: calendar))"
        }
        if let end = when.endDay, !end.isEmpty {
            text += ", until \(dayLabel(end, weekday: false, calendar: calendar))"
        }
        return text
    }

    /// The next times a trigger runs, up to its end.
    public static func upcoming(
        _ trigger: ScheduleTrigger, after: Date, count: Int, calendar: Calendar = .current
    ) -> [Date] {
        let end = ScheduleMath.plannedEnd(trigger, calendar: calendar)
        var dates: [Date] = []
        var cursor = after
        while dates.count < count,
              let next = ScheduleMath.nextDue(for: trigger, after: cursor, calendar: calendar) {
            if let end, next >= end { break }
            dates.append(next)
            cursor = next
        }
        return dates
    }

    public static func weekday(of day: String, calendar: Calendar) -> Int? {
        ScheduleMath.parseLocalDate(day + "T12:00", calendar: calendar)
            .map { calendar.component(.weekday, from: $0) }
    }

    static func dayLabel(_ day: String, weekday: Bool, calendar: Calendar) -> String {
        guard let date = ScheduleMath.parseLocalDate(day + "T12:00", calendar: calendar) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = weekday ? "EEE, MMM d" : "MMM d"
        return formatter.string(from: date)
    }

    public static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    // MARK: What

    /// The items every plan has one of, found by what they are rather than
    /// by name, since each plan's copy has its own id.
    public enum Role: String, Sendable {
        case countdown, preService, transition, walkout
    }

    public static func role(of item: ServiceItem) -> Role? {
        if item.isCountdown == true { return .countdown }
        if item.isPreService == true { return .preService }
        if item.isTransition == true { return .transition }
        if item.isWalkout == true { return .walkout }
        return nil
    }

    /// Where a plan item comes from.
    public enum Source: Hashable, Sendable {
        /// That one plan.
        case plan(id: String)
        /// Each day's plan made like this template: of its service type,
        /// or named like it when it has none.
        case template(id: String, serviceType: String?)
        /// Each day's plan of this service type ("Sunday Morning Worship").
        case serviceType(String)

        public var repeatsAcrossPlans: Bool {
            if case .plan = self { return false }
            return true
        }
    }

    /// The action that plays an item from a plan, a template, or a series.
    public static func action(
        playing item: ServiceItem, from source: Source, id: String = UUID().uuidString
    ) -> SlideAction {
        var action = SlideAction(id: id, kind: .fireServiceItem)
        switch source {
        case .plan(let planID):
            action.serviceId = planID
        case .template(let templateID, let serviceType):
            action.serviceId = templateID
            action.planSeries = serviceType.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        case .serviceType(let name):
            action.planSeries = name
        }
        action.serviceItemId = item.id
        action.serviceItemRole = role(of: item)?.rawValue
        action.serviceItemName = item.name
        action.serviceItemRefId = item.refId.isEmpty ? nil : item.refId
        return action
    }

    /// Where an action's item comes from. A template's action always
    /// carries a series (empty when the template has no service type), so
    /// it is told from a single plan without looking the plan up.
    public static func source(of action: SlideAction) -> Source? {
        guard action.kind == .fireServiceItem else { return nil }
        if let series = action.planSeries {
            if let templateID = action.serviceId, !templateID.isEmpty {
                return .template(id: templateID, serviceType: series.isEmpty ? nil : series)
            }
            return series.isEmpty ? nil : .serviceType(series)
        }
        return action.serviceId.map { .plan(id: $0) }
    }

    public static func repeatsAcrossPlans(_ action: SlideAction) -> Bool {
        source(of: action)?.repeatsAcrossPlans == true
    }

    // MARK: Finding the day's plan and item

    /// "Sunday Morning Worship Template" → "Sunday Morning Worship".
    public static func baseName(ofTemplate name: String) -> String {
        let suffix = " Template"
        return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
    }

    /// Whether a plan belongs to the action's series.
    static func belongs(_ plan: Service, to source: Source, plans: [String: Service]) -> Bool {
        guard plan.isTemplate != true else { return false }
        switch source {
        case .plan(let id):
            return plan.id == id
        case .serviceType(let name):
            return plan.mxuServiceTypeName == name
        case .template(let id, let serviceType):
            if let serviceType { return plan.mxuServiceTypeName == serviceType }
            guard let template = plans[id] else { return false }
            return normalized(plan.name) == normalized(baseName(ofTemplate: template.name))
        }
    }

    /// The plan an action plays from on a day ("2026-11-15"). One plan is
    /// itself, whatever the day. A series is its plan dated that day; the
    /// open plan when two are, else the first by name. A template with no
    /// service type also takes a day's only plan, when none is named like it.
    public static func dayPlan(
        for action: SlideAction, on day: String, plans: [String: Service], currentID: String? = nil
    ) -> Service? {
        guard let source = source(of: action) else { return nil }
        if case .plan(let id) = source { return plans[id] }
        let onDay = plans.values.filter { $0.isTemplate != true && $0.serviceDate.prefix(10) == day }
        var matches = onDay.filter { belongs($0, to: source, plans: plans) }
        if matches.isEmpty, case .template(_, nil) = source, onDay.count == 1 { matches = onDay }
        if let currentID, let open = matches.first(where: { $0.id == currentID }) { return open }
        return matches.min { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The series' next plan on or after a day: Run Now on a weekday plays
    /// Sunday's, so a schedule can be tried before it's due.
    public static func nextPlan(
        for action: SlideAction, from day: String, plans: [String: Service]
    ) -> Service? {
        guard let source = source(of: action) else { return nil }
        if case .plan(let id) = source { return plans[id] }
        return plans.values
            .filter { belongs($0, to: source, plans: plans) && String($0.serviceDate.prefix(10)) >= day }
            .min { ($0.serviceDate, $0.name, $0.id) < ($1.serviceDate, $1.name, $1.id) }
    }

    /// The action's item in a plan: the very item when the plan has it
    /// (one plan, or the template itself), else the same kind of item (the
    /// countdown, the pre-service slideshow), else the item playing the
    /// same presentation or video, else one with the same name.
    public static func item(for action: SlideAction, in plan: Service) -> ServiceItem? {
        let candidates = plan.items.filter { $0.itemKind != .header }
        if let id = action.serviceItemId, let exact = candidates.first(where: { $0.id == id }) {
            return exact
        }
        if let raw = action.serviceItemRole, let role = Role(rawValue: raw) {
            return candidates.first { self.role(of: $0) == role }
        }
        if let ref = action.serviceItemRefId, !ref.isEmpty,
           let same = candidates.first(where: { $0.refId == ref }) {
            return same
        }
        if let name = action.serviceItemName.map(normalized), !name.isEmpty {
            return candidates.first { normalized($0.name) == name }
        }
        return nil
    }

    /// The item as it plays: one with nothing linked (a week's countdown
    /// with no video chosen) plays what the schedule's own copy had, in
    /// this plan's place so the plan still moves on after it.
    public static func playable(
        _ item: ServiceItem, for action: SlideAction, kindOf: (String) -> ServiceItemKind?
    ) -> ServiceItem? {
        if !item.refId.isEmpty { return item }
        guard let ref = action.serviceItemRefId, !ref.isEmpty, let kind = kindOf(ref) else { return nil }
        var filled = item
        filled.refId = ref
        filled.itemKind = kind
        return filled
    }

    /// The action pinned to the plan and item it plays this time, for the
    /// router. The fallback content stays, for an item with nothing linked.
    public static func pinned(_ action: SlideAction, plan: Service, item: ServiceItem) -> SlideAction {
        var pinned = action
        pinned.serviceId = plan.id
        pinned.planSeries = nil
        pinned.serviceItemId = item.id
        return pinned
    }

    public enum Resolution: Equatable, Sendable {
        case plays(plan: Service, item: ServiceItem)
        case skipped(reason: String)
    }

    /// What an action plays on a day, or why it can't, in words for the
    /// history and the sheet's preview. `upcomingIfNone` lets Run Now use
    /// the next plan when there's none that day.
    public static func resolve(
        _ action: SlideAction, on day: String, plans: [String: Service], currentID: String? = nil,
        upcomingIfNone: Bool = false, kindOf: (String) -> ServiceItemKind?
    ) -> Resolution {
        guard let source = source(of: action) else { return .skipped(reason: "No plan chosen.") }
        var plan = dayPlan(for: action, on: day, plans: plans, currentID: currentID)
        if plan == nil, upcomingIfNone { plan = nextPlan(for: action, from: day, plans: plans) }
        guard let plan else {
            switch source {
            case .plan: return .skipped(reason: "The plan is gone.")
            case .serviceType(let name): return .skipped(reason: "No \(name) plan that day.")
            case .template(let id, let type):
                let name = type ?? plans[id].map { baseName(ofTemplate: $0.name) } ?? "matching"
                return .skipped(reason: "No \(name) plan that day.")
            }
        }
        let label = action.serviceItemName.flatMap { $0.isEmpty ? nil : $0 } ?? "The item"
        guard let found = item(for: action, in: plan) else {
            return .skipped(reason: "\(plan.name) has no \(label).")
        }
        guard let ready = playable(found, for: action, kindOf: kindOf) else {
            return .skipped(reason: "\(found.name) in \(plan.name) has nothing to play yet.")
        }
        return .plays(plan: plan, item: ready)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
