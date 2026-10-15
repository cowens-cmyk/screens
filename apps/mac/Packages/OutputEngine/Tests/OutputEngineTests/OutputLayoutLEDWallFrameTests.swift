import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class OutputLayoutLEDWallFrameTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func placement(width: Int, height: Int) throws -> OutputPlacement? {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Wall", width: width, height: height))
        outputs.applyLayout(.ledWall, outputCount: 1, overlap: 0, forScreen: screen.id)
        return outputs.placement(forSlice: screen.id)
    }

    func testExactlyHDWallKeepsTheHDFrame() throws {
        // A wall that fills a 1080p frame is stored as no placement; in a 4K frame it
        // would be a half-size placement, so nil proves the frame stayed 1080p.
        XCTAssertNil(try placement(width: 1920, height: 1080))
    }

    func testWallOnePixelOverHDMovesToTheUHDFrame() throws {
        let wider = try XCTUnwrap(placement(width: 1921, height: 1080))
        XCTAssertEqual(wider.frameWidth, 3840)
        XCTAssertEqual(wider.frameHeight, 2160)
        let taller = try XCTUnwrap(placement(width: 1920, height: 1081))
        XCTAssertEqual(taller.frameWidth, 3840)
        XCTAssertEqual(taller.frameHeight, 2160)
    }
}
