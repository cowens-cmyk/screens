import Foundation

/// The Sermon timer starts each service at the message's full length. It used
/// to be set back only when the pre-service slides restarted, which needs the
/// last slide of the service before left up; now each service's start sets it
/// back: the moment its countdown starts, or the service time when it has no
/// countdown. A timer still counting down is a sermon in progress and is never
/// touched; the next service's start tries again.
public enum SermonTimerReset {
    /// Where a day's service times came from, best first.
    public enum Source: String, Equatable, Sendable {
        /// The plan's own times, from Shepherd.
        case plan
        /// The times Schedule Service was given.
        case scheduled
        /// The Service Day setup's weekly times.
        case serviceDay
    }

    public struct Service: Equatable, Sendable {
        public var time: Date
        /// When its countdown starts, if one is scheduled for it.
        public var countdownStart: Date?
        public var source: Source

        public init(time: Date, countdownStart: Date? = nil, source: Source) {
            self.time = time
            self.countdownStart = countdownStart
            self.source = source
        }

        /// The moment the service starts: its countdown, else the service
        /// time itself.
        public var resetAt: Date { countdownStart ?? time }
    }

    /// A countdown Schedule Service set: when it starts and the service
    /// time it ends at.
    public struct ScheduledCountdown: Equatable, Sendable {
        public var start: Date
        public var serviceTime: Date

        public init(start: Date, serviceTime: Date) {
            self.start = start
            self.serviceTime = serviceTime
        }
    }

    /// A countdown starting this long or less before a service belongs to
    /// it. Countdowns run about five minutes; anything earlier is the
    /// service before's.
    public static let countdownLeadLimit: TimeInterval = 20 * 60
    /// A moment noticed this late (the Mac asleep through it) is let go:
    /// by then the service is under way.
    public static let lateLimit: TimeInterval = 10 * 60

    /// The day's services, each with the countdown that opens it. The times
    /// come from the plan (Shepherd) if it has any that day, else from
    /// Schedule Service, else from the Service Day setup; the sources are
    /// never mixed, so one service isn't counted twice at slightly
    /// different times. Countdowns from Schedule Service are matched to
    /// whichever times are used.
    public static func services(
        on day: Date, planTimes: [Date], scheduled: [ScheduledCountdown],
        serviceDay: ServiceDaySettings?, calendar: Calendar
    ) -> [Service] {
        func today(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: day) }
        let fromPlan = planTimes.filter(today)
        let fromSchedule = scheduled.map(\.serviceTime).filter(today)
        let fromServiceDay = serviceDay.map { serviceDayTimes($0, on: day, calendar: calendar) } ?? []
        let (times, source): ([Date], Source) =
            !fromPlan.isEmpty ? (fromPlan, .plan)
            : !fromSchedule.isEmpty ? (fromSchedule, .scheduled)
            : (fromServiceDay, .serviceDay)

        // One service per minute, in order.
        var seen = Set<Int>()
        let unique = times.sorted().filter { seen.insert(Int($0.timeIntervalSinceReferenceDate / 60)).inserted }
        let starts = scheduled.map(\.start).filter(today)
        return unique.enumerated().map { index, time in
            // The countdown belongs to this service only if it starts after
            // the service before has begun.
            let earliest = max(time.addingTimeInterval(-countdownLeadLimit), index > 0 ? unique[index - 1] : .distantPast)
            let countdown = starts.filter { $0 > earliest && $0 <= time }.max()
            return Service(time: time, countdownStart: countdown, source: source)
        }
    }

    /// The Service Day setup's times on that day, if it's one of its days.
    /// Set by the calendar's hour and minute, so a service at 8:00 is at
    /// 8:00 on the days the clocks change too.
    public static func serviceDayTimes(_ settings: ServiceDaySettings, on day: Date, calendar: Calendar) -> [Date] {
        guard ServiceDay.days(settings).contains(calendar.component(.weekday, from: day)) else { return [] }
        let start = calendar.startOfDay(for: day)
        return ServiceDay.sorted(settings.services).compactMap { service in
            guard let seconds = ServiceDay.secondsOfDay(service.serviceTime) else { return nil }
            return calendar.date(
                bySettingHour: seconds / 3600, minute: seconds % 3600 / 60, second: seconds % 60, of: start)
        }
    }

    /// The service whose start passed since the last look (after `last`, at
    /// or before `now`), if it passed recently enough to act on. With more
    /// than one, the latest.
    public static func due(_ services: [Service], after last: Date, now: Date) -> Service? {
        services
            .filter { $0.resetAt > last && $0.resetAt <= now && now.timeIntervalSince($0.resetAt) <= lateLimit }
            .max { $0.resetAt < $1.resetAt }
    }

    /// The next service start still to come.
    public static func next(_ services: [Service], after now: Date) -> Service? {
        services.filter { $0.resetAt > now }.min { $0.resetAt < $1.resetAt }
    }

    /// The Sermon timer as a service starts.
    public struct TimerState: Equatable, Sendable {
        public var isRunning: Bool
        /// Seconds left; below zero in overtime.
        public var remaining: Double
        /// Seconds it has run.
        public var elapsed: Double
        /// Its length now (nudges included).
        public var duration: Double

        public init(isRunning: Bool, remaining: Double, elapsed: Double, duration: Double) {
            self.isRunning = isRunning
            self.remaining = remaining
            self.elapsed = elapsed
            self.duration = duration
        }
    }

    public enum Decision: Equatable, Sendable {
        case reset
        /// Stopped at the full length already.
        case ready
        /// Left alone, with why, for Diagnostics.
        case skip(String)
    }

    /// Whether the Sermon timer is set back as a service starts. A timer
    /// still counting down is a sermon in progress; one past zero, or
    /// stopped, is the service before's. While the message is on the
    /// screens nothing that has run is touched, whatever the clock says.
    public static func decide(_ timer: TimerState?, length: Double, messageIsLive: Bool) -> Decision {
        guard let timer else { return .reset }
        if messageIsLive, timer.elapsed > 0 {
            return .skip("The message was up.")
        }
        if timer.isRunning, timer.remaining > 0 {
            return .skip("The sermon timer was running.")
        }
        if !timer.isRunning, timer.elapsed == 0, timer.duration == length { return .ready }
        return .reset
    }
}
