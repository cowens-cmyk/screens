import Foundation

/// Every service opens with a countdown: a five-minute video, different each
/// week, first in the plan. Scheduling a service starts that video so it hits
/// zero at the service time, then the plan moves on by itself.
public enum ServiceCountdown {
    /// Where countdown videos are filed in the Media library.
    public static let folder = "Countdowns"
    public static let itemName = "Countdown"
    /// Marks the scheduler triggers made for a plan, so rescheduling replaces
    /// them rather than piling up.
    public static let triggerNotePrefix = "countdown:"

    /// The plan's countdown item, if it has one.
    public static func item(in service: Service) -> ServiceItem? {
        service.items.first { $0.isCountdown == true }
    }

    /// "Countdown", "COUNTDOWN" or "Count Down": an item (or a presentation)
    /// named as the countdown.
    public static func looksLikeCountdown(_ name: String) -> Bool {
        name.lowercased().filter(\.isLetter) == "countdown"
    }

    /// The Countdowns folder in Media, or a folder inside it.
    public static func isCountdownFolder(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// How a plan gets its countdown.
    public enum Change: Equatable, Sendable {
        /// An item the plan already has is its countdown: Shepherd's
        /// "COUNTDOWN", or one linked to a countdown video or presentation.
        case mark(itemID: String)
        /// An empty Countdown first, to be given this week's video.
        case insert(ServiceItem)
    }

    /// What gives a plan its countdown; nil when it needs nothing. A
    /// template, a plan that has one, and a plan whose countdown was taken
    /// out are left as they are, though an item that plainly is the
    /// countdown is still marked as one rather than a second added.
    /// `isCountdownLink` says whether an item is linked to a video in the
    /// Countdowns folder or a presentation named Countdown.
    public static func change(
        for service: Service, isCountdownLink: (ServiceItem) -> Bool = { _ in false },
        makeID: () -> String = { UUID().uuidString }
    ) -> Change? {
        guard service.isTemplate != true, item(in: service) == nil else { return nil }
        if let existing = service.items.first(where: { item in
            item.itemKind != .header && (looksLikeCountdown(item.name) || isCountdownLink(item))
        }) {
            return .mark(itemID: existing.id)
        }
        guard service.countdownRemoved != true else { return nil }
        var countdown = ServiceItem(id: makeID(), itemKind: .media, name: itemName, refId: "")
        countdown.isCountdown = true
        return .insert(countdown)
    }

    /// Applies a change to the plan as it stands now: false when there's
    /// nothing left to do (it has a countdown by now, or the item is gone).
    @discardableResult
    public static func apply(_ change: Change, to service: inout Service) -> Bool {
        guard item(in: service) == nil else { return false }
        switch change {
        case .mark(let itemID):
            guard let index = service.items.firstIndex(where: { $0.id == itemID }) else { return false }
            service.items[index].isCountdown = true
        case .insert(let countdown):
            guard service.countdownRemoved != true else { return false }
            service.items.insert(countdown, at: 0)
        }
        return true
    }

    /// The plan with its countdown (see `change(for:)`), nil when it needs
    /// nothing.
    public static func ensuringCountdown(
        _ service: Service, isCountdownLink: (ServiceItem) -> Bool = { _ in false }
    ) -> Service? {
        guard let change = change(for: service, isCountdownLink: isCountdownLink) else { return nil }
        var plan = service
        return apply(change, to: &plan) ? plan : nil
    }

    /// Takes an item out of the plan. Taking out its countdown is
    /// remembered, so the plan isn't given another.
    public static func remove(itemID: String, from service: inout Service) {
        let removedCountdown = service.items.contains { $0.id == itemID && $0.isCountdown == true }
        service.items.removeAll { $0.id == itemID }
        if removedCountdown { service.countdownRemoved = true }
    }

    /// When the countdown starts so it ends at the service time: the video's
    /// length before it, to the second. Without a length, five minutes.
    public static func start(serviceTime: Date, videoSeconds: Double?) -> Date {
        let length = (videoSeconds ?? 0) > 0 ? videoSeconds! : 300
        return serviceTime.addingTimeInterval(-length.rounded(.up))
    }

    /// The service time a countdown starting then ends at: the other way
    /// round from `start(serviceTime:videoSeconds:)`.
    public static func serviceTime(start: Date, videoSeconds: Double?) -> Date {
        let length = (videoSeconds ?? 0) > 0 ? videoSeconds! : 300
        return start.addingTimeInterval(length.rounded(.up))
    }

    /// A one-time trigger that brings up the plan and plays its countdown.
    public static func trigger(
        planID: String, planName: String, countdownItemID: String,
        start: Date, serviceTime: Date, calendar: Calendar = .current
    ) -> ScheduleTrigger {
        var condition = ScheduleCondition(id: UUID().uuidString, kind: .oneTime)
        condition.date = localStamp(start, calendar: calendar)
        var action = SlideAction(id: UUID().uuidString, kind: .fireServiceItem)
        action.serviceId = planID
        action.serviceItemId = countdownItemID
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: serviceTime)
        return ScheduleTrigger(
            id: UUID().uuidString, name: "\(planName) \(time) Countdown",
            conditions: [condition], actions: [action], enabled: true,
            notes: triggerNotePrefix + planID)
    }

    /// The countdown triggers made for a plan.
    public static func isCountdownTrigger(_ trigger: ScheduleTrigger, planID: String) -> Bool {
        trigger.notes == triggerNotePrefix + planID
    }

    /// The service time a countdown trigger was made for, from its start and
    /// the countdown's length.
    public static func startDate(of trigger: ScheduleTrigger, calendar: Calendar = .current) -> Date? {
        trigger.conditions.first { $0.kind == .oneTime }?.date
            .flatMap { ScheduleMath.parseLocalDate($0, calendar: calendar) }
    }

    /// "2026-10-25T10:24:50", the scheduler's local date form.
    public static func localStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
