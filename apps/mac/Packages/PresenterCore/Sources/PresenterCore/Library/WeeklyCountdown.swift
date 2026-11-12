import Foundation

/// The Schedule tab's Countdowns: on the chosen days, at each start time, the
/// countdown plays from that day's plan. Sunday's plan is a new plan each
/// week, so the countdown is found in it on the day (PlanSchedule), and it
/// plays inside the plan so the plan moves on when it ends.
///
/// The setup is kept in its triggers rather than a settings document: one
/// weekly trigger per start time, marked in its notes, all with the same
/// days, plan and dates. Saving again rewrites them in place.
public enum WeeklyCountdown {
    public static let notePrefix = "weeklycountdown:"
    /// The board folder they're grouped in on every Mac.
    public static let folderID = "countdowns"
    public static let folderName = "Countdowns"
    public static let defaultStartTimes = ["07:55", "09:25", "11:10"]

    public struct Setup: Equatable, Sendable {
        /// Each day's plan of a service type, or made like a template.
        public var series: PlanSchedule.Source
        /// 1 is Sunday.
        public var days: [Int]
        public var everyWeeks: Int
        /// When each countdown starts: "07:55" or "07:54:30".
        public var startTimes: [String]
        public var startDay: String
        /// The last day it runs; nil for never.
        public var endDay: String?
        /// Played in the plan's countdown when that week's has no video.
        public var fallbackVideoID: String?

        public init(
            series: PlanSchedule.Source, days: [Int] = [1], everyWeeks: Int = 1,
            startTimes: [String] = WeeklyCountdown.defaultStartTimes, startDay: String,
            endDay: String? = nil, fallbackVideoID: String? = nil
        ) {
            self.series = series
            self.days = days
            self.everyWeeks = everyWeeks
            self.startTimes = startTimes
            self.startDay = startDay
            self.endDay = endDay
            self.fallbackVideoID = fallbackVideoID
        }
    }

    public static func isWeeklyCountdown(_ trigger: ScheduleTrigger) -> Bool {
        trigger.notes?.hasPrefix(notePrefix) == true
    }

    /// The start times, earliest first, each once.
    public static func sortedTimes(_ times: [String]) -> [String] {
        var seen = Set<String>()
        return times
            .filter { ServiceDay.secondsOfDay($0) != nil }
            .sorted { (ServiceDay.secondsOfDay($0) ?? 0) < (ServiceDay.secondsOfDay($1) ?? 0) }
            .filter { seen.insert(ServiceDay.timeString(secondsOfDay: ServiceDay.secondsOfDay($0) ?? 0)).inserted }
    }

    /// The action every trigger runs: the countdown of the day's plan.
    public static func action(for setup: Setup, id: String) -> SlideAction {
        var countdown = ServiceItem(id: "", itemKind: .media, name: ServiceCountdown.itemName, refId: setup.fallbackVideoID ?? "")
        countdown.isCountdown = true
        var action = PlanSchedule.action(playing: countdown, from: setup.series, id: id)
        // No item of its own: the countdown is found in each plan by what it is.
        action.serviceItemId = nil
        return action
    }

    /// One weekly trigger per start time. Ids inside follow the position,
    /// so saving the same setup changes nothing.
    public static func triggers(for setup: Setup, makeID: () -> String = { UUID().uuidString }) -> [ScheduleTrigger] {
        let days = Array(Set(setup.days.filter { (1 ... 7).contains($0) })).sorted()
        guard !days.isEmpty else { return [] }
        return sortedTimes(setup.startTimes).enumerated().map { index, time in
            let when = PlanSchedule.When(
                repeats: .weekly, days: days, everyWeeks: setup.everyWeeks, time: time,
                startDay: setup.startDay, endDay: setup.endDay)
            return ScheduleTrigger(
                id: makeID(), name: "Countdown \(ServiceDay.displayTime(time))",
                conditions: [PlanSchedule.condition(for: when, id: "weekly-countdown-\(index)-when")],
                actions: [action(for: setup, id: "weekly-countdown-\(index)-play")],
                enabled: true, notes: notePrefix + "\(index)",
                enabledUntil: PlanSchedule.enabledUntil(for: when))
        }
    }

    /// The setup the triggers were saved from; nil when there are none.
    public static func setup(from triggers: [ScheduleTrigger], today: String) -> Setup? {
        let mine = triggers.filter { isWeeklyCountdown($0) && $0.archived != true }
        guard let first = mine.first,
              let action = first.actions.first(where: { $0.kind == .fireServiceItem }),
              let series = PlanSchedule.source(of: action),
              let when = PlanSchedule.when(from: first, today: today)
        else { return nil }
        let times = mine.compactMap { trigger -> String? in
            trigger.conditions.first?.timeOfDay
        }
        return Setup(
            series: series, days: when.repeats == .daily ? Array(1 ... 7) : when.days,
            everyWeeks: when.everyWeeks, startTimes: sortedTimes(times), startDay: when.startDay,
            endDay: when.endDay, fallbackVideoID: action.serviceItemRefId)
    }

    /// What saving does to the scheduler: the triggers there are rewritten
    /// in place, earliest first (their on/off kept), extra times added and
    /// times taken away deleted.
    public static func changes(
        from existing: [ScheduleTrigger], to setup: Setup?, makeID: () -> String = { UUID().uuidString }
    ) -> ServiceDay.Changes {
        let current = existing.filter(isWeeklyCountdown).sorted { a, b in
            (a.conditions.first?.timeOfDay.flatMap(ServiceDay.secondsOfDay) ?? 0, a.id)
                < (b.conditions.first?.timeOfDay.flatMap(ServiceDay.secondsOfDay) ?? 0, b.id)
        }
        let fresh = setup.map { triggers(for: $0, makeID: { "" }) } ?? []
        var changes = ServiceDay.Changes()
        for (index, made) in fresh.enumerated() {
            guard index < current.count else {
                var created = made
                created.id = makeID()
                changes.creates.append(created)
                continue
            }
            var updated = current[index]
            updated.name = made.name
            updated.conditions = made.conditions
            updated.actions = made.actions
            updated.notes = made.notes
            updated.enabledUntil = made.enabledUntil
            updated.conditionLogic = nil
            updated.archived = nil
            if updated != current[index] { changes.updates.append(updated) }
        }
        changes.deletes = current.dropFirst(fresh.count).map(\.id)
        return changes
    }

    /// The triggers in the order they fire in a day, for the board folder.
    public static func triggerIDs(_ triggers: [ScheduleTrigger]) -> [String] {
        triggers
            .filter { isWeeklyCountdown($0) && $0.archived != true }
            .sorted { a, b in
                (a.conditions.first?.timeOfDay.flatMap(ServiceDay.secondsOfDay) ?? 0, a.id)
                    < (b.conditions.first?.timeOfDay.flatMap(ServiceDay.secondsOfDay) ?? 0, b.id)
            }
            .map(\.id)
    }

    /// Whether the plan has its own countdown set for that day with Start
    /// Time… (Schedule Service). That one is timed for this plan's service,
    /// so the weekly one stands aside rather than play the video twice.
    public static func planHasItsOwn(
        _ planID: String, on day: String, triggers: [ScheduleTrigger], calendar: Calendar = .current
    ) -> Bool {
        triggers.contains { trigger in
            ServiceCountdown.isCountdownTrigger(trigger, planID: planID)
                && ServiceCountdown.startDate(of: trigger, calendar: calendar)
                    .map { ScheduleMath.localDayString($0, calendar: calendar) == day } == true
        }
    }

    /// "Sundays", "Sundays and Wednesdays", "Every 2 weeks on Sundays".
    public static func daysLabel(_ setup: Setup) -> String {
        var english = Calendar(identifier: .gregorian)
        english.locale = Locale(identifier: "en_US_POSIX")
        let names = Array(Set(setup.days)).sorted().filter { (1 ... 7).contains($0) }
            .map { english.weekdaySymbols[$0 - 1] + "s" }
        let list = names.count == 7 ? "Every day" : PlanSchedule.listed(names)
        return setup.everyWeeks > 1 ? "Every \(setup.everyWeeks) weeks on \(list)" : list
    }
}

extension SchedulerBoard {
    /// The board with the weekly countdowns gathered first in their folder;
    /// nil when it already is. Called on every Mac, since the board is each
    /// Mac's own. With none left, an empty folder is taken away.
    public func placingWeeklyCountdowns(triggerIDs: [String]) -> SchedulerBoard? {
        var board = self
        let folderID = WeeklyCountdown.folderID
        guard !triggerIDs.isEmpty else {
            guard let folder = board.folder(id: folderID), folder.triggerIds.isEmpty else { return nil }
            board.removeFolder(id: folderID)
            return board
        }
        let managed = Set(triggerIDs)
        if board.folder(id: folderID) == nil {
            board.folders.append(ScheduleFolder(id: folderID, name: WeeklyCountdown.folderName, triggerIds: []))
            board.nodes.insert(folderID, at: 0)
        }
        board.nodes.removeAll { managed.contains($0) }
        for index in board.folders.indices {
            if board.folders[index].id == folderID {
                let others = board.folders[index].triggerIds.filter { !managed.contains($0) }
                board.folders[index].triggerIds = triggerIDs + others
            } else {
                board.folders[index].triggerIds.removeAll { managed.contains($0) }
            }
        }
        return board == self ? nil : board
    }

    /// The Service Day folder, once its pre-service restarts are gone:
    /// taken away when empty. Nil when there's nothing to do.
    public func removingEmptyServiceDayFolder() -> SchedulerBoard? {
        guard let folder = folder(id: ServiceDay.folderID), folder.triggerIds.isEmpty else { return nil }
        var board = self
        board.removeFolder(id: ServiceDay.folderID)
        return board
    }
}
