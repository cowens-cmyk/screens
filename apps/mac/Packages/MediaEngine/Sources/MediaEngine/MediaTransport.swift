import Foundation

public struct MediaTransportState: Sendable, Equatable {

    public var duration: Double

    public var position: Double
    public var isPlaying: Bool
    public var isLooping: Bool
    public var capturedAt: Date

    public var rate: Double

    /// Paused and moved by hand (the scrubber, Skip to End) since it last
    /// played. Seeking stops a frame short of the end, which would
    /// otherwise look like a video that played out.
    public var parkedBySeek: Bool

    public init(
        duration: Double, position: Double, isPlaying: Bool, isLooping: Bool,
        capturedAt: Date, rate: Double = 1, parkedBySeek: Bool = false
    ) {
        self.rate = rate
        self.parkedBySeek = parkedBySeek
        self.duration = duration
        self.position = position
        self.isPlaying = isPlaying
        self.isLooping = isLooping
        self.capturedAt = capturedAt
    }

    public func position(at date: Date) -> Double {
        let clamped = min(max(0, position), max(0, duration))
        guard isPlaying, duration > 0 else { return clamped }
        let projected = position + date.timeIntervalSince(capturedAt) * max(rate, 0)
        if isLooping {
            let wrapped = projected.truncatingRemainder(dividingBy: duration)
            return wrapped < 0 ? wrapped + duration : wrapped
        }
        return min(max(0, projected), duration)
    }

    public func remaining(at date: Date) -> Double {
        max(0, duration - position(at: date))
    }

    /// Real seconds left: a clip at 2x runs out in half its media time.
    public func wallClockRemaining(at date: Date) -> Double {
        remaining(at: date) / wallClockRate
    }

    /// The play rate that turns media seconds into real ones.
    public var wallClockRate: Double { rate > 0 ? rate : 1 }

    /// Played through to its end and stopped there. A video paused and
    /// scrubbed to its last frame hasn't: that's someone checking the
    /// frame, and the plan mustn't move on for it.
    public func hasPlayedOut(at date: Date) -> Bool {
        !isPlaying && !isLooping && !parkedBySeek && duration > 0
            && position(at: date) >= duration - 0.05
    }
}

extension MediaTransportState {

    public static let playingTolerance = 0.3

    public static let pausedTolerance = 1.0 / 120

    public func tracks(_ other: MediaTransportState, at date: Date) -> Bool {
        let tolerance = isPlaying ? Self.playingTolerance : Self.pausedTolerance
        let gap = abs(position(at: date) - other.position(at: date))

        let distance = isLooping && duration > 0 ? min(gap, duration - gap) : gap
        return duration == other.duration && isPlaying == other.isPlaying
            && isLooping == other.isLooping && rate == other.rate
            && parkedBySeek == other.parkedBySeek && distance < tolerance
    }
}
