import XCTest
@testable import MediaEngine

final class CadenceLockTests: XCTestCase {
    /// A video's frames, every `fd` from zero; a screen rendering every
    /// `interval` from `start`, each render up to `jitter` early or late
    /// (a seeded sequence, so the test is the same every run). Returns the
    /// frame index each render chose, locked or not.
    private func renders(
        fd: Double, interval: Double, start: Double, jitter: Double, count: Int, locked: Bool
    ) -> [Int] {
        var lock = CadenceLock()
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var chosen: [Int] = []
        for k in 0 ..< count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(seed >> 11) / Double(1 << 53)
            let time = start + Double(k) * interval + (unit * 2 - 1) * jitter
            let pick = locked
                ? lock.pickTime(for: time, frameDuration: fd, gridPTS: 0)
                : time + fd / 4
            chosen.append(Int((pick / fd).rounded(.down)))
        }
        return chosen
    }

    /// How long each frame was held, in renders, the first and last left out.
    private func holds(_ chosen: [Int]) -> [Int] {
        var holds: [Int] = []
        var run = 1
        for i in 1 ..< chosen.count {
            if chosen[i] == chosen[i - 1] { run += 1 } else { holds.append(run); run = 1 }
        }
        return Array(holds.dropFirst())
    }

    private func skips(_ chosen: [Int]) -> Int {
        zip(chosen, chosen.dropFirst()).filter { $1 - $0 > 1 }.count
    }

    func testA30HzScreenOnAFrameEdgeHoldsEveryFrameOnce() {
        let fd = 1.0 / 30
        // Renders a fraction of a millisecond from where the default choice
        // flips frames, with 1.5 ms of timer jitter: the LED wall on Nov 23.
        let start = 0.75 * fd + 0.0002
        let loose = renders(fd: fd, interval: fd, start: start, jitter: 0.0015, count: 600, locked: false)
        XCTAssertGreaterThan(skips(loose), 20, "the default choice should show the problem")
        let locked = renders(fd: fd, interval: fd, start: start, jitter: 0.0015, count: 600, locked: true)
        XCTAssertEqual(skips(Array(locked.dropFirst(30))), 0)
        XCTAssertEqual(Set(holds(Array(locked.dropFirst(30)))), [1])
    }

    func testA60HzScreenHoldsEachFrameForTwoRefreshes() {
        let fd = 1.0 / 30
        let start = 0.75 * fd - 0.0001
        let locked = renders(fd: fd, interval: 1.0 / 60, start: start, jitter: 0.0015, count: 1200, locked: true)
        XCTAssertEqual(skips(Array(locked.dropFirst(30))), 0)
        XCTAssertEqual(Set(holds(Array(locked.dropFirst(30)))), [2])
    }

    func testAScreenClockThatDriftsRecentresRarely() {
        let fd = 1.0 / 30
        // 0.1% fast: a frame's worth of drift every 33 s; 2 minutes here.
        let locked = renders(
            fd: fd, interval: fd * 0.999, start: 0.75 * fd, jitter: 0.001, count: 3600, locked: true)
        let held = holds(Array(locked.dropFirst(30)))
        XCTAssertLessThanOrEqual(held.filter { $0 != 1 }.count, 8)
    }

    func testTheChoiceStaysWithinHalfAFrame() {
        let fd = 1.0 / 30
        var lock = CadenceLock()
        for k in 0 ..< 300 {
            let time = 0.37 + Double(k) / 60
            let pick = lock.pickTime(for: time, frameDuration: fd, gridPTS: 0)
            XCTAssertLessThanOrEqual(abs(pick - time), fd / 2 + 1e-9)
        }
    }

    func testRatesThatCantBeEvenAreLeftAlone() {
        let fd = 1.0 / 25
        var lock = CadenceLock()
        for k in 0 ..< 120 {
            let time = Double(k) / 60
            XCTAssertEqual(lock.pickTime(for: time, frameDuration: fd, gridPTS: 0), time + fd / 4, accuracy: 1e-12)
        }
        XCTAssertNil(lock.bias)
    }

    func testAJumpBackStartsOver() {
        let fd = 1.0 / 30
        var lock = CadenceLock()
        for k in 0 ..< 10 { _ = lock.pickTime(for: 1 + Double(k) * fd, frameDuration: fd, gridPTS: 0) }
        XCTAssertNotNil(lock.bias)
        XCTAssertEqual(lock.pickTime(for: 0.2, frameDuration: fd, gridPTS: 0), 0.2 + fd / 4, accuracy: 1e-12)
        XCTAssertNil(lock.bias)
    }
}
