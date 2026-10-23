import Foundation

/// The one "Sermon" countdown: started when the message goes live, shown
/// big on the stage's Message layout, and adjusted from the Screens column.
public enum SermonTimer {
    public static let name = "Sermon"
    /// Fixed so the Message layout can name it. A Sermon timer made before
    /// this id existed is still found by its name.
    public static let id = "screens.timer.sermon"
    /// 40 minutes, unless the message (or its plan's template) says otherwise.
    public static let defaultSeconds: Double = 40 * 60

    public static func seconds(for presentation: Presentation?) -> Double {
        guard let seconds = presentation?.sermonTimerSeconds, seconds > 0 else { return defaultSeconds }
        return seconds
    }

    public static func minutes(for presentation: Presentation?) -> Int {
        Int((seconds(for: presentation) / 60).rounded())
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
}

extension MediaItem {
    /// What a video does when it finishes. One that plays once goes on to
    /// the next item in the plan unless it's been set otherwise (or has an
    /// auto-advance of its own); a looping video never finishes.
    public var resolvedEndAction: MediaEndAction? {
        guard mediaKind == .video, !loops else { return nil }
        if let endAction { return endAction }
        return autoAdvance == nil ? .next : nil
    }

    /// The advance a plan runs for this item: Next as an advance the moment
    /// the video ends, else the item's own auto-advance.
    public var planAdvance: AutoAdvance? {
        if resolvedEndAction == .next { return AutoAdvance(delaySeconds: 0, afterPlayback: true) }
        return autoAdvance
    }
}
