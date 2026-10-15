import XCTest
@testable import StreamEngine

final class StreamHealthBoundaryTests: XCTestCase {
    func testNoDataCountsAtTheExactGraceBoundary() {
        var tracker = PlatformHealthTracker(graceSeconds: 90, escalationPolls: 1)
        tracker.record("yt", status: "noData", issues: [], elapsed: 90.0.nextDown)
        XCTAssertNil(tracker.verdict("yt"), "No data is ignored before the grace period ends")

        tracker.record("yt", status: "noData", issues: [], elapsed: 90)
        XCTAssertEqual(tracker.verdict("yt"), .noData)
        XCTAssertTrue(tracker.pollsHot("yt"))
    }
}
