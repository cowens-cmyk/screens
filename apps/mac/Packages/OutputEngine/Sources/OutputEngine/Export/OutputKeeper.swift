import Foundation

/// Keeps an output that should be sending trying until it is, and notices
/// when one that was sending stops taking frames. An output assigned to a
/// screen has no one standing by to switch it off and on again during a
/// service, so nothing here ever gives up: a failed open, a helper that
/// went away or never answered, and frames that stop landing all end the
/// same way, in a fresh open after a wait that grows while the trouble
/// lasts.
///
/// Pure logic, so it can be tested without a card: the caller owns the
/// connection, the frames and the clock, reports what happened, calls
/// `tick` about once a second and carries out the step it gets back.
public struct OutputKeeper: Equatable, Sendable {
    public struct Timing: Equatable, Sendable {
        /// An open that hasn't answered by now is stuck in the helper,
        /// which can't be cancelled from outside; the helper is killed. A
        /// cold open of a big card (an 8K Pro allocating 4K frames) takes a
        /// few seconds, so this is well past that.
        public var openTimeout: TimeInterval = 8
        /// After a good open the frames already queued land within a
        /// fraction of a second; none by now means the port isn't taking
        /// them.
        public var confirmTimeout: TimeInterval = 3
        /// A sending port whose frames have been refused (or gone
        /// unanswered) this long is reopened.
        public var stallTimeout: TimeInterval = 3
        public var firstRetryDelay: TimeInterval = 1
        public var maxRetryDelay: TimeInterval = 10
        /// Sending this long counts as recovered: the wait before the next
        /// retry starts short again. Until then each fault waits longer, so
        /// a port that keeps dropping out settles into a slow retry instead
        /// of flapping.
        public var steadyAfter: TimeInterval = 10
        /// Opens that succeed but never take a frame, this many in a row,
        /// mean the helper itself is wedged.
        public var phantomOpensBeforeKill = 2

        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        case stopped
        /// The open is sent and hasn't answered.
        case opening(since: TimeInterval)
        /// The open answered; waiting for the first frame to land.
        case confirming(since: TimeInterval)
        case sending(since: TimeInterval)
        /// The last attempt is over; the next opens at `until`.
        case waiting(until: TimeInterval)
    }

    public enum Step: Equatable, Sendable {
        case none
        /// Open a fresh connection and output.
        case open
        /// Drop the current attempt: its connection, its frames and the
        /// port in the helper. A later tick opens again.
        case abandon(reason: String, killHelper: Bool)
    }

    public let timing: Timing
    public private(set) var phase: Phase = .stopped
    /// Faults since the port last sent steadily.
    public private(set) var failures = 0
    /// What went wrong last, for the status line; cleared once sending.
    public private(set) var problem: String?
    /// Whether this port has sent since it was asked to, so a fault after
    /// that reads as reconnecting rather than starting.
    public private(set) var hasSent = false
    private var phantomOpens = 0

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public var isRunning: Bool { phase != .stopped }

    public var isSending: Bool {
        if case .sending = phase { return true }
        return false
    }

    /// The port is asked to send. Always opens at once, whatever came
    /// before: this is a new request, not a retry.
    public mutating func begin(at now: TimeInterval) -> Step {
        self = OutputKeeper(timing: timing)
        phase = .opening(since: now)
        return .open
    }

    public mutating func stop() {
        self = OutputKeeper(timing: timing)
    }

    /// The open answered without an error.
    public mutating func opened(at now: TimeInterval) {
        guard case .opening = phase else { return }
        phase = .confirming(since: now)
    }

    /// The open answered with an error. Every error is retried: one that
    /// looks permanent (no matching mode, port mapped as an input) also
    /// shows up at launch while the driver is still settling, and a retry
    /// every few seconds costs nothing when it really is permanent.
    public mutating func openFailed(_ message: String, at now: TimeInterval) -> Step {
        guard case .opening = phase else { return .none }
        return fail(message, killHelper: false, at: now)
    }

    /// The first frame of this attempt landed.
    public mutating func frameAccepted(at now: TimeInterval) {
        guard case .confirming = phase else { return }
        confirm(at: now)
    }

    /// The connection went away (helper crashed, was killed or can't be
    /// reached) or the port refused a run of frames.
    public mutating func lost(_ reason: String, at now: TimeInterval) -> Step {
        switch phase {
        case .opening, .confirming, .sending:
            return fail(reason, killHelper: false, at: now)
        case .stopped, .waiting:
            return .none
        }
    }

    /// Called about once a second. `lastOffered` is when the mirror last
    /// handed this attempt a frame (taken or not), `lastAccepted` when the
    /// port last took one; both nil until it happens.
    public mutating func tick(
        at now: TimeInterval, lastOffered: TimeInterval?, lastAccepted: TimeInterval?
    ) -> Step {
        switch phase {
        case .stopped:
            return .none
        case .opening(let since):
            guard now - since >= timing.openTimeout else { return .none }
            return fail("the helper never answered the open", killHelper: true, at: now)
        case .confirming(let since):
            // The first frame's own report can lose the race with this tick.
            if let lastAccepted, lastAccepted >= since {
                confirm(at: lastAccepted)
                return .none
            }
            guard now - since >= timing.confirmTimeout else { return .none }
            phantomOpens += 1
            let wedged = phantomOpens >= timing.phantomOpensBeforeKill
            if wedged { phantomOpens = 0 }
            return fail("opened but no frame landed", killHelper: wedged, at: now)
        case .sending(let since):
            let accepted = max(lastAccepted ?? since, since)
            // Only frames offered and not taken count against the port. A
            // mirror that stopped offering (the app itself stalled) is not
            // the card's fault, and reopening a working port would put a
            // blip on the wall for nothing.
            let stillOffering = lastOffered.map { now - $0 < timing.stallTimeout } ?? false
            if now - accepted >= timing.stallTimeout, stillOffering {
                return fail("frames stopped landing", killHelper: false, at: now)
            }
            if failures > 0, now - since >= timing.steadyAfter {
                failures = 0
            }
            return .none
        case .waiting(let until):
            guard now >= until else { return .none }
            phase = .opening(since: now)
            return .open
        }
    }

    /// Skips the rest of a wait, for when the reason to wait has gone (the
    /// device just showed up).
    public mutating func retrySoon(at now: TimeInterval) {
        guard case .waiting(let until) = phase, until > now else { return }
        phase = .waiting(until: now)
    }

    /// How long the next retry waits after `failures` faults in a row.
    public func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let doubled = timing.firstRetryDelay * pow(2, Double(min(failures - 1, 16)))
        return min(doubled, timing.maxRetryDelay)
    }

    private mutating func confirm(at now: TimeInterval) {
        phase = .sending(since: now)
        hasSent = true
        problem = nil
        phantomOpens = 0
    }

    private mutating func fail(_ reason: String, killHelper: Bool, at now: TimeInterval) -> Step {
        failures += 1
        problem = reason
        phase = .waiting(until: now + retryDelay(afterFailures: failures))
        return .abandon(reason: reason, killHelper: killHelper)
    }
}
