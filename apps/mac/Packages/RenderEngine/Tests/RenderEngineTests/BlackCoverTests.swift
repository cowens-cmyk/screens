import CoreGraphics
import XCTest
@testable import RenderEngine

final class BlackCoverTests: XCTestCase {
    private func busyScene() -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 1280, height: 720))
        scene.addItem(
            RenderItem(
                id: "lower-third", frame: CGRect(x: 0, y: 500, width: 600, height: 120),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))),
            to: .slide)
        return scene
    }

    func testCoverIsOneOpaqueBlackFrameOverTheWholeCanvas() throws {
        let cover = busyScene().blackedOut()
        let items = cover.layers.filter { !$0.isHidden }.flatMap(\.items)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.frame, CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(item.opacity, 1)
        guard case .solid(let color) = item.content else { return XCTFail("not a solid") }
        XCTAssertEqual(color.alpha, 1)
        XCTAssertEqual([color.red, color.green, color.blue], [0, 0, 0])
        XCTAssertEqual(cover.canvasSize, CGSize(width: 1280, height: 720))
    }

    /// A cleared livestream is transparent; the cover must not be, and the
    /// ATEM follower keys off this classification to put the keyer on air.
    func testCoverReadsAsFullScreenWhereAClearSceneReadsTransparent() {
        XCTAssertEqual(StreamCoverage.classify(RenderScene()), .transparent)
        XCTAssertEqual(StreamCoverage.classify(busyScene().blackedOut()), .fullScreen)
    }

    func testCoverDropsEverythingUnderneath() {
        let cover = busyScene().blackedOut()
        XCTAssertTrue(cover.layers.filter { $0.kind != .alerts }.allSatisfy { $0.items.isEmpty })
    }

    func testCoverIgnoresLayersHiddenByTheStreamRouting() {
        // The livestream hides the layers it doesn't carry before the cover
        // is built; the cover is built from what's left, so it's still shown.
        var scene = busyScene()
        for index in scene.layers.indices { scene.layers[index].isHidden = true }
        let items = scene.blackedOut().layers.filter { !$0.isHidden }.flatMap(\.items)
        XCTAssertEqual(items.map(\.id), [RenderScene.blackCoverID])
    }
}
