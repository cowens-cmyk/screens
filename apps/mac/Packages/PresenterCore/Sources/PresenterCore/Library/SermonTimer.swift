import Foundation

/// The one "Sermon" countdown: started when the message goes live, shown
/// big on the stage's Message layout, and adjusted from the Screens column.
public enum SermonTimer {
    public static let name = "Sermon"
    /// Fixed so the Message layout can name it. A Sermon timer made before
    /// this id existed is still found by its name.
    public static let id = "screens.timer.sermon"
    /// A Sunday message: 40 minutes, unless the message (or its plan's
    /// template) says otherwise.
    public static let defaultSeconds: Double = 40 * 60
    /// A Wednesday night message: 30 minutes.
    public static let midweekSeconds: Double = 30 * 60

    /// Whether a plan is a Wednesday night: the midweek service type (from
    /// Shepherd or the Students template), or any plan dated a Wednesday.
    public static func isMidweek(_ plan: Service?, midweekServiceType: String, calendar: Calendar = .current) -> Bool {
        guard let plan else { return false }
        if PlanBrand.of(plan, midweekServiceType: midweekServiceType) == .students { return true }
        return PlanSchedule.weekday(of: plan.serviceDate, calendar: calendar) == 4
    }

    /// The message's length: what the message says, else 30 minutes on a
    /// Wednesday night and 40 otherwise. 40 minutes was every message's
    /// length before Wednesday nights had their own (templates and the
    /// template prompt filled it in), so on a Wednesday it counts as unset.
    public static func seconds(for presentation: Presentation?, midweek: Bool = false) -> Double {
        let dayLength = midweek ? midweekSeconds : defaultSeconds
        guard let seconds = presentation?.sermonTimerSeconds, seconds > 0 else { return dayLength }
        if midweek, seconds == defaultSeconds { return dayLength }
        return seconds
    }

    public static func minutes(for presentation: Presentation?, midweek: Bool = false) -> Int {
        Int((seconds(for: presentation, midweek: midweek) / 60).rounded())
    }

    /// The timer in a list: the fixed id first, then the name.
    public static func find<T>(in timers: [T], id: (T) -> String, name: (T) -> String) -> T? {
        timers.first { id($0) == Self.id }
            ?? timers.first { name($0).caseInsensitiveCompare(Self.name) == .orderedSame }
    }

    /// The length a typed number of minutes asks for, kept between a minute
    /// and five hours.
    public static func seconds(minutes: Int) -> Double {
        Double(min(max(minutes, 1), 300) * 60)
    }

    /// A countdown's length after a nudge: never below zero. Only the length
    /// moves, so the time already run is kept and a running timer keeps going.
    public static func adjusted(duration: Double, byMinutes minutes: Int) -> Double {
        max(0, duration + Double(minutes * 60))
    }

    /// A running timer started this long ago belongs to an earlier service.
    public static let staleSeconds: Double = 45 * 60
    /// A running timer this far past zero belongs to an earlier service.
    public static let staleOvertimeSeconds: Double = 5 * 60

    /// Whether a running Sermon timer should start over as the message goes
    /// live. Going back to the message within a service leaves it running;
    /// one still going from the service before (started more than 45
    /// minutes ago, or longer than the message itself, or more than five
    /// minutes into overtime) starts again.
    public static func restartsWhenMessageGoesLive(elapsed: Double, remaining: Double, duration: Double) -> Bool {
        elapsed > max(staleSeconds, duration) || remaining < -staleOvertimeSeconds
    }
}

extension MediaItem {
    /// What a video does when it finishes. One that plays once goes on to
    /// the next item in the plan unless it's been set otherwise (or has an
    /// auto-advance of its own); a looping video (by its own choice or its
    /// category's, see `playsLooping`) never finishes.
    public var resolvedEndAction: MediaEndAction? {
        guard mediaKind == .video, !playsLooping else { return nil }
        if let endAction { return endAction }
        return autoAdvance == nil ? .next : nil
    }

    /// The advance a plan runs for this item: Next as an advance the moment
    /// the video ends, else the item's own auto-advance.
    public var planAdvance: AutoAdvance? {
        planAdvance(asCountdown: false)
    }

    /// The plan's countdown always goes on to the next item when its video
    /// ends (it's played once, whatever the video's own settings), unless
    /// the video has an auto-advance of its own.
    public func planAdvance(asCountdown: Bool) -> AutoAdvance? {
        if asCountdown, mediaKind == .video {
            return autoAdvance ?? AutoAdvance(delaySeconds: 0, afterPlayback: true)
        }
        if resolvedEndAction == .next { return AutoAdvance(delaySeconds: 0, afterPlayback: true) }
        return autoAdvance
    }
}
