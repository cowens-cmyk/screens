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

    /// The plan with a countdown first: an empty one (to be given its video)
    /// when it has none. Templates and plans already holding one are left as
    /// they are.
    public static func ensuringCountdown(_ service: Service) -> Service? {
        guard item(in: service) == nil, service.isTemplate != true else { return nil }
        var plan = service
        var countdown = ServiceItem(id: UUID().uuidString, itemKind: .media, name: itemName, refId: "")
        countdown.isCountdown = true
        plan.items.insert(countdown, at: 0)
        return plan
    }

    /// When the countdown starts so it ends at the service time: the video's
    /// length before it, to the second. Without a length, five minutes.
    public static func start(serviceTime: Date, videoSeconds: Double?) -> Date {
        let length = (videoSeconds ?? 0) > 0 ? videoSeconds! : 300
        return serviceTime.addingTimeInterval(-length.rounded(.up))
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
