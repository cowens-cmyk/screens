import XCTest
@testable import OutputEngine

final class OutputLayoutTilesClampTests: XCTestCase {
    func testOverlapAboveCapIsClampedToTwentyPercent() {
        let tiles = OutputLayout.tiles(columns: 2, overlap: 0.5)
        // clamped = 0.2 -> width = 1.2 / 2 = 0.6; second tile starts at 0.6 - 0.2 = 0.4
        XCTAssertEqual(tiles[0].width, 0.6, accuracy: 0.0001)
        XCTAssertEqual(tiles[1].minX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(tiles[1].maxX, 1.0, accuracy: 0.0001)
    }

    func testOverlapAtCapMatchesOverCap() {
        XCTAssertEqual(
            OutputLayout.tiles(columns: 3, overlap: 0.2),
            OutputLayout.tiles(columns: 3, overlap: 0.9))
    }
}
