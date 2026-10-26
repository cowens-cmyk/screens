import Foundation
import SlideScene
import SwiftUI

/// Ticks when a timer's shown second turns over: on the timer's own second
/// boundaries rather than the wall clock's, so a once-a-second update shows
/// each new value on time. A timer that is not counting never ticks.
///
/// The timer rows used to redraw on a half-second periodic timeline, each
/// whole row, whether the timer was running or not.
struct TimerSecondSchedule: TimelineSchedule {
    /// A moment the shown value turned over; nil for a timer standing still.
    let anchor: Date?

    init(_ timer: TimerSnapshot) {
        anchor = Self.anchor(of: timer)
    }

    init(timers: [TimerSnapshot]) {
        // Several timers turn over at different moments; their folder row
        // follows the first live one, which is the one it features.
        anchor = timers.lazy.compactMap(Self.anchor(of:)).first
    }

    static func anchor(of timer: TimerSnapshot) -> Date? {
        switch timer.mode {
        case .countdownToTime:
            return timer.targetTime
        case .countdown, .countUp:
            guard timer.isRunning, let since = timer.runningSince else { return nil }
            return since.addingTimeInterval(-timer.banked)
        }
    }

    /// Just past the boundary, so the value read there is already the new one.
    static let lead: TimeInterval = 0.02

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        guard let anchor else { return Entries(next: startDate, done: false, once: true) }
        let offset = startDate.timeIntervalSince(anchor)
        let first = anchor.addingTimeInterval(offset.rounded(.up) + Self.lead)
        return Entries(next: startDate, following: first)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date
        var following: Date?
        var done = false
        var once = false

        init(next: Date, done: Bool, once: Bool) {
            upcoming = next
            self.done = done
            self.once = once
        }

        init(next: Date, following: Date) {
            upcoming = next
            self.following = following
        }

        mutating func next() -> Date? {
            guard !done else { return nil }
            let current = upcoming
            if once {
                done = true
            } else if let following {
                upcoming = following
                self.following = nil
            } else {
                upcoming = current.addingTimeInterval(1)
            }
            return current
        }
    }
}
