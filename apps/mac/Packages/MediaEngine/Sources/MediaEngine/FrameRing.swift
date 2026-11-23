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
