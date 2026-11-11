import CoreGraphics
import RenderEngine
import XCTest
@testable import OutputEngine

private func slideScene() -> RenderScene {
    var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    scene.addItem(
        RenderItem(
            id: "slide-text", frame: CGRect(x: 100, y: 100, width: 400, height: 100),
            content: .solid(SceneColor(red: 1, green: 1, blue: 1))),
        to: .slide)
    return scene
}

private func isOpaqueBlack(_ scene: RenderScene) -> Bool {
    let items = scene.layers.filter { !$0.isHidden }.flatMap(\.items)
    guard items.count == 1, case .solid(let color) = items[0].content else { return false }
    return color.alpha == 1 && color.red == 0 && color.green == 0 && color.blue == 0
        && items[0].frame.size == scene.canvasSize
}

@MainActor
final class BlackRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testBlackCoversTheAudienceAndLivestreamAndReleases() throws {
        let outputs = try makeManager()
        let audience = UUID()
        let stream = UUID()
        outputs.sceneProvider = { slideScene() }
        // The livestream carries no slide layer while its lower third is
        // off; black has to reach it anyway.
        outputs.setLayerRouting([stream.uuidString: []])
        let audienceProvider = outputs.previewProvider(for: audience.uuidString)
        let streamProvider = outputs.previewProvider(for: stream.uuidString)

        XCTAssertFalse(isOpaqueBlack(audienceProvider()))
        outputs.setBlack(true)
        XCTAssertTrue(isOpaqueBlack(audienceProvider()), "an existing provider follows the switch per frame")
        XCTAssertTrue(isOpaqueBlack(streamProvider()), "the livestream is opaque black, not transparent")
        XCTAssertEqual(StreamCoverage.classify(streamProvider()), .fullScreen)

        outputs.setBlack(false)
        XCTAssertFalse(isOpaqueBlack(audienceProvider()))
        XCTAssertEqual(audienceProvider(), slideScene())
    }

    func testStageScreensKeepTheirDisplay() throws {
        let outputs = try makeManager()
        let stage = UUID()
        outputs.setRole(.confidence, forScreen: stage)
        outputs.sceneProvider = { slideScene() }
        outputs.confidenceSceneProvider = { _ in RenderScene(canvasSize: CGSize(width: 640, height: 360)) }
        outputs.setBlack(true)

        let shown = outputs.previewProvider(for: stage.uuidString)()
        XCTAssertEqual(shown.canvasSize.width, 640)
        XCTAssertFalse(isOpaqueBlack(shown))
    }

    func testTheAudiencePictureOnTheStageIsNotBlackedOut() throws {
        let outputs = try makeManager()
        let audience = UUID()
        outputs.sceneProvider = { slideScene() }
        outputs.setBlack(true)
        // Audience Screen on the stage mirrors the room's scene; Black is for
        // the room, so the stage still gets the slide.
        let mirrored = outputs.previewProvider(for: audience.uuidString, ignoringBlack: true)
        XCTAssertEqual(mirrored(), slideScene())
        XCTAssertTrue(isOpaqueBlack(outputs.previewProvider(for: audience.uuidString)()))
    }

    func testBlackCoversSignageToo() throws {
        let outputs = try makeManager()
        let lobby = UUID()
        outputs.sceneProvider = { slideScene() }
        outputs.signageSceneProvider = { _ in RenderScene(canvasSize: CGSize(width: 200, height: 200)) }
        outputs.setBlack(true)
        XCTAssertTrue(isOpaqueBlack(outputs.previewProvider(for: lobby.uuidString)()))
    }

    func testAlignmentGridStillShowsWhileBlack() throws {
        let outputs = try makeManager()
        outputs.sceneProvider = { slideScene() }
        let screen = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Room", width: 1920, height: 1080))
        outputs.setBlack(true)
        let provider = outputs.previewProvider(for: screen.id.uuidString)
        XCTAssertTrue(isOpaqueBlack(provider()))
        outputs.setTestPattern(true, forScreen: screen.id)
        XCTAssertFalse(isOpaqueBlack(provider()), "a test pattern is set up on purpose and wins")
    }
}
