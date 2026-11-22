import XCTest
@testable import MediaEngine

final class FrameRingTests: XCTestCase {
    private let frame = 1.0 / 30

    private func ring(_ count: Int, capacity: Int = 8) -> FrameRing<Int> {
        var ring = FrameRing<Int>(capacity: capacity)
        for index in 0 ..< count { ring.append(pts: Double(index) * frame, frame: index) }
        return ring
    }

    func testEachTimeGetsTheNewestFrameWhoseTimeHasCome() {
        let ring = ring(6)
        XCTAssertEqual(ring.frame(at: 0, tolerance: frame / 4), 0)
        XCTAssertEqual(ring.frame(at: frame * 0.5, tolerance: frame / 4), 0)
        XCTAssertEqual(ring.frame(at: frame * 0.8, tolerance: frame / 4), 1, "within the tolerance of the next frame")
        XCTAssertEqual(ring.frame(at: frame * 2.1, tolerance: frame / 4), 2)
        XCTAssertEqual(ring.frame(at: frame * 40, tolerance: frame / 4), 5, "ahead of every frame: the newest")
    }

    func testATimeBeforeEveryFrameGetsTheOldest() {
        var ring = FrameRing<Int>(capacity: 4)
        for index in 10 ..< 20 { ring.append(pts: Double(index) * frame, frame: index) }
        XCTAssertEqual(ring.frames.count, 4)
        XCTAssertEqual(ring.frame(at: 0, tolerance: frame / 4), 16)
    }

    func testAFrameAtOrBeforeTheNewestStartsOver() {
        var ring = ring(5)
        ring.append(pts: 0, frame: 100)
        XCTAssertEqual(ring.frames.map(\.frame), [100], "a loop's next pass or a seek")
        XCTAssertEqual(ring.frame(at: frame * 3, tolerance: frame / 4), 100)
    }

    func testEmptyHasNoFrame() {
        XCTAssertNil(FrameRing<Int>().frame(at: 1, tolerance: 0.01))
    }

    /// Two screens on different clocks each get a steady cadence from the
    /// same frames: a 60 Hz screen holds every 30 fps frame for exactly two
    /// refreshes, whatever a 50 Hz screen running ahead has taken.
    func testScreensOnDifferentClocksEachGetTheirOwnCadence() {
        var ring = FrameRing<Int>()
        var pulled = -1
        var sixty: [Int] = []
        var a = 0, b = 0
        while sixty.count < 300 {
            let ahead = Double(a) / 50 + 0.025
            let display = Double(b) / 60
            let (time, isSixty) = ahead <= display ? (ahead, false) : (display, true)
            if isSixty { b += 1 } else { a += 1 }
            while Double(pulled + 1) * frame <= time + frame / 4 {
                pulled += 1
                ring.append(pts: Double(pulled) * frame, frame: pulled)
            }
            if isSixty, let shown = ring.frame(at: time, tolerance: frame / 4) { sixty.append(shown) }
        }
        var holds: [Int] = []
        var run = 1
        for (previous, next) in zip(sixty, sixty.dropFirst()) {
            if next == previous { run += 1 } else { holds.append(run); run = 1 }
        }
        XCTAssertEqual(Set(holds.dropFirst()), [2], "holds \(holds.prefix(20))")
    }
}
