import Foundation

/// After the walkout has played a while the room is getting ready for the
/// next service, so the pre-service slides come back. A countdown that
/// fires first simply takes the screens; one due within a couple of
/// minutes of the return is let take them instead, rather than the slides
/// flashing up for a moment.
public enum WalkoutReturn {
    /// A countdown starting this soon after the return is left to take over.
    public static let countdownMargin: TimeInterval = 2 * 60

    public enum Decision: Equatable, Sendable {
        case returnToPreService
        /// Left alone, with why, for Diagnostics.
        case skip(String)
    }

    /// `walkoutStillLive`: the walkout is still the live item, nothing else
    /// having gone up since. `nextCountdown`: when the next scheduled
    /// countdown starts, if one is.
    public static func decide(
        walkoutStillLive: Bool, runsService: Bool, now: Date, nextCountdown: Date?
    ) -> Decision {
        guard runsService else { return .skip("This Mac doesn't run the service.") }
        guard walkoutStillLive else { return .skip("Something else went live.") }
        if let nextCountdown, nextCountdown >= now, nextCountdown.timeIntervalSince(now) <= countdownMargin {
            return .skip("The countdown starts in under two minutes.")
        }
        return .returnToPreService
    }
}
