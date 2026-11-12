import Foundation

/// Which service start the Before Service stage counts down to: the walk-in
/// counts to the service about to begin, and the walkout, with that service
/// over, to the next one today. After the day's last service there is none.
/// On a day with no services it is the first service of the next day that
/// has any.
public enum ServiceStartClock {
    /// A service that started this recently is still the one counted to, held
    /// at 0:00, so a walk-in running late reads "0:00" and not the time to a
    /// later service. Services run far longer than this, so by the walkout
    /// the next service is the one that shows.
    public static let startingHold: TimeInterval = SermonTimerReset.lateLimit

    /// The start to count to at `now`: the next one still to come, unless one
    /// began within `startingHold` (and the next isn't that close behind it),
    /// then that one, which counts as 0:00. Nil with no service left today.
    public static func target(_ services: [SermonTimerReset.Service], now: Date) -> Date? {
        let times = services.map(\.time).sorted()
        let next = times.first { $0 > now }
        if let started = times.last(where: { $0 <= now }),
           now.timeIntervalSince(started) < startingHold,
           next.map({ $0.timeIntervalSince(started) >= startingHold }) ?? true {
            return started
        }
        return next
    }

    /// How many days ahead the next service is looked for.
    public static let lookAheadDays = 14

    /// The start to count to, looking past today: on a day with no
    /// services, the first one of the next day that has any, so on a
    /// Thursday the walk-in slides count to Sunday's first service. A day
    /// that has services keeps to them: after its last one there is none
    /// (the clock shows), rather than a week's countdown over the walkout.
    public static func target(
        _ today: [SermonTimerReset.Service], later: [SermonTimerReset.Service], now: Date
    ) -> Date? {
        guard today.isEmpty else { return target(today, now: now) }
        return later.map(\.time).filter { $0 > now }.min()
    }

    /// The services of the next day after `now` that has any, asked a day
    /// at a time (at noon, clear of the hour the clocks change); empty when
    /// none is found within `limit` days.
    public static func nextServiceDay(
        after now: Date, limit: Int = lookAheadDays, calendar: Calendar,
        services: (Date) -> [SermonTimerReset.Service]
    ) -> [SermonTimerReset.Service] {
        let today = calendar.startOfDay(for: now)
        for offset in 1 ... max(limit, 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
            else { continue }
            let found = services(noon)
            if !found.isEmpty { return found }
        }
        return []
    }
}
