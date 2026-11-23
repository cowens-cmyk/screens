import XCTest
@testable import MediaEngine

final class CadenceProbeTests: XCTestCase {
    private let frame = 1.0 / 30

    private func tally(_ shown: [Int], every interval: Double) -> CadenceProbe.Tally {
        var tally = CadenceProbe.Tally()
        for (render, index) in shown.enumerated() {
            let host = Double(render) * interval
            tally.record(hostTime: host, itemTime: host, pts: Double(index) * frame, frameDuration: frame, tolerance: frame / 4)
        }
        tally.finishHold()
        return tally
    }

    func testSteadySixtyHertzHoldsEachFrameTwice() {
        let shown = (0 ..< 120).map { $0 / 2 }
        let tally = tally(shown, every: 1.0 / 60)
        XCTAssertEqual(tally.expectedHold, 2)
        XCTAssertEqual(tally.uneven, 0)
        XCTAssertEqual(tally.skipped, 0)
        XCTAssertEqual(tally.frames, 60)
    }

    func testOneThenThreeIsUneven() {
        var shown: [Int] = []
        for frame in 0 ..< 40 { shown += Array(repeating: frame, count: frame % 2 == 0 ? 1 : 3) }
        let tally = tally(shown, every: 1.0 / 60)
        XCTAssertGreaterThan(tally.uneven, 30)
    }

    func testThirtyHertzSkipsAreCounted() {
        let shown = [0, 1, 2, 4, 5, 6, 8, 9]
        let tally = tally(shown, every: 1.0 / 30)
        XCTAssertEqual(tally.expectedHold, 1)
        XCTAssertEqual(tally.skipped, 2)
    }

    func testSummaryLine() {
        let line = CadenceProbe.summary("output Audience at 60 fps", tally((0 ..< 120).map { $0 / 2 }, every: 1.0 / 60))
        XCTAssertTrue(line.hasPrefix("output Audience at 60 fps: 120 renders at 60.0 Hz, 60 frames, uneven holds 0%"), line)
    }
}
