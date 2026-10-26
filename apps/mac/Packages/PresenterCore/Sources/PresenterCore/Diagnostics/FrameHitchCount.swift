import Foundation

/// Frames seen by a display link while something moves on screen (a panel
/// opening or folding), and how many of them came late. A frame is late
/// when it follows the one before by more than one and a half refresh
/// intervals: the main thread was busy and at least one frame never showed.
/// Free of AppKit, so the counting can be tested; the app feeds it each
/// tick's timestamp and the display's interval.
public struct FrameHitchCount: Equatable, Sendable {
    public static let lateFactor = 1.5

    public private(set) var frames = 0
    /// Frames that followed the previous one by more than `lateFactor`
    /// refresh intervals.
    public private(set) var late = 0
    /// Refreshes that showed nothing new, summed over the late frames.
    public private(set) var missed = 0
    /// The longest gap between two frames, in seconds.
    public private(set) var longest: Double = 0
    /// The refresh interval last reported, in seconds.
    public private(set) var interval: Double = 0
    private var last: Double?

    public init() {}

    /// One display link tick: when its frame showed, and the display's
    /// refresh interval at the time (it changes with ProMotion).
    public mutating func record(timestamp: Double, interval: Double) {
        defer { last = timestamp }
        guard interval > 0 else { return }
        self.interval = interval
        guard let last else { return }
        let gap = timestamp - last
        guard gap > 0 else { return }
        frames += 1
        longest = max(longest, gap)
        if gap > interval * Self.lateFactor {
            late += 1
            missed += max(1, Int((gap / interval).rounded()) - 1)
        }
    }

    /// For the diagnostics log: "62 frames at 120 Hz, 1 late (2 missed),
    /// longest 25.0 ms".
    public var summary: String {
        let hertz = interval > 0 ? Int((1 / interval).rounded()) : 0
        let lateness = late == 0 ? "none late" : "\(late) late (\(missed) missed)"
        return String(format: "%d frames at %d Hz, %@, longest %.1f ms", frames, hertz, lateness, longest * 1000)
    }
}
