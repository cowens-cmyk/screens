import XCTest
@testable import MediaEngine

final class ArrivalWindowGapBoundaryTests: XCTestCase {

    // Times are multiples of 1/32 so every difference is exact in binary and
    // the comparison against the gap is not blurred by rounding.
    private func filledWindow() -> (ArrivalWindow, last: Double) {
        var window = ArrivalWindow()
        let count = ArrivalWindow.minimumCount + 10
        for frame in 0..<count { window.record(Double(frame) / 32) }
        return (window, Double(count - 1) / 32)
    }

    func testAGapExactlyAtTheLimitKeepsTheWindow() {
        var (window, last) = filledWindow()
        window.record(last + ArrivalWindow.gap)
        XCTAssertNotNil(window.cadence)
    }

    func testAGapJustOverTheLimitRestartsTheWindow() {
        var (window, last) = filledWindow()
        window.record(last + ArrivalWindow.gap + 1.0 / 32)
        XCTAssertNil(window.cadence)
    }
}
