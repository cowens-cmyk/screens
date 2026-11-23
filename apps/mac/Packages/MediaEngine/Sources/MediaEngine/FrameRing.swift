import Foundation

/// The last few frames a playing video has handed out, by presentation
/// time, so that every screen drawing it gets the frame for its own time.
///
/// One player feeds every screen showing its video: the docked previews
/// (at the display's refresh, a little ahead of it), each DeckLink port at
/// its own rate, the side TVs and the stage. The player's video output
/// gives each frame once, so with only the newest kept, whichever screen
/// asked furthest ahead took the next frame and every other screen showed
/// it early, a whole frame early at times. A screen's picture then moved on
/// at another screen's clock, held for one refresh and then three: the
/// judder in the pre-service loop's videos on Nov 22. With the frames kept
/// here each screen picks the newest one whose time has come at its time.
struct FrameRing<Frame> {
    private(set) var frames: [(pts: Double, frame: Frame)] = []
    let capacity: Int

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { frames.isEmpty }
    var newestPTS: Double? { frames.last?.pts }
    var oldestPTS: Double? { frames.first?.pts }

    /// Adds the next frame. One that comes at or before the newest (a seek,
    /// or a loop starting over) begins the ring again.
    mutating func append(pts: Double, frame: Frame) {
        if let newest = frames.last?.pts, pts <= newest {
            frames.removeAll(keepingCapacity: true)
        }
        frames.append((pts, frame))
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }

    /// The frame showing at `time`: the newest whose time has come, within
    /// `tolerance`; a time before every frame held gets the oldest.
    func frame(at time: Double, tolerance: Double) -> Frame? {
        entry(at: time, tolerance: tolerance)?.frame
    }

    /// The same, with the frame's time.
    func entry(at time: Double, tolerance: Double) -> (pts: Double, frame: Frame)? {
        guard let first = frames.first else { return nil }
        return frames.last(where: { $0.pts <= time + tolerance }) ?? first
    }
}

/// Keeps one screen's renders away from the instants where a video's frame
/// changes. A DeckLink port renders on its own steady timer, and where its
/// ticks fall against the video's frames depends on when the video started:
/// when they land within a millisecond or two of a frame's edge, the timer's
/// jitter flips each render between two frames and the screen holds frames
/// unevenly and skips some ("Ways to Give" on the LED wall, Nov 23: 95% of
/// renders near an edge, 16-22% of holds uneven, 50 frames skipped in 10 s).
/// Once a screen's interval is known and fits the video's frame evenly
/// (30 fps at 30, 60 or 15 Hz), the frame is chosen for a time shifted so
/// the renders fall half an interval past an edge, as far from one as they
/// can be; the shift moves again only if the clocks drift it near an edge.
/// Other rates are left as they were: they can't be held evenly.
struct CadenceLock {
    /// What's added to the screen's time to choose its frame (under half
    /// a frame either way), once locked.
    private(set) var bias: Double?
    private var lastTime: Double?
    private var interval: Double?

    /// The time to choose the frame for at `time` (the newest frame at or
    /// before it): the time itself plus a quarter of a frame (the default),
    /// or plus the bias once locked. `gridPTS` is any frame's time, for
    /// where the edges fall.
    mutating func pickTime(for time: Double, frameDuration fd: Double, gridPTS: Double?) -> Double {
        let natural = time + fd / 4
        guard fd > 0 else { return time }
        if let last = lastTime, time > last, time - last < 0.25 {
            let gap = time - last
            interval = interval.map { $0 * 0.9 + gap * 0.1 } ?? gap
        } else {
            interval = nil
            bias = nil
        }
        lastTime = time
        guard let interval, let grid = gridPTS else { return natural }
        let ratio = fd / min(interval, fd)
        // Stricter to lock than to stay locked, so a jittery interval
        // doesn't let go of a lock and take it again.
        guard abs(ratio - ratio.rounded()) < (bias == nil ? 0.08 : 0.25), ratio.rounded() <= 8 else {
            bias = nil
            return natural
        }
        let step = fd / ratio.rounded()
        let margin = step / 6
        if let bias {
            let phase = Self.mod(time + bias - grid, fd)
            if phase >= margin, phase <= fd - margin { return time + bias }
        }
        var shift = step / 2 - Self.mod(time - grid, fd)
        shift -= (shift / fd).rounded() * fd
        bias = shift
        return time + shift
    }

    private static func mod(_ value: Double, _ divisor: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: divisor)
        return r < 0 ? r + divisor : r
    }
}
