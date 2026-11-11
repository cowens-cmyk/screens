import Foundation

/// Which service start the Before Service stage counts down to: the walk-in
/// counts to the service about to begin, and the walkout, with that service
/// over, to the next one today. After the last service there is none.
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
}
