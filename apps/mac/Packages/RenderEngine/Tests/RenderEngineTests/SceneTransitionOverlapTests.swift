import CoreGraphics
import XCTest
@testable import RenderEngine

/// A slide fire often changes two layers a few milliseconds apart (the
/// words, then the slide's background picture as it lands). The second
/// change must not cut short the dissolve already under way.
final class SceneTransitionOverlapTests: XCTestCase {
    private func scene(slide: String, media: String?) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(RenderItem(
            id: slide, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            content: .text(StyledText(string: slide, fontSize: 24))), to: .slide)
        if let media {
            scene.addItem(RenderItem(
                id: media, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                content: .media(id: "media-\(media)")), to: .stillGraphics)
        }
        return scene
    }

    private func opacity(_ id: String, in scene: RenderScene, _ layer: LayerKind = .slide) -> Double? {
        scene.layers.first { $0.kind == layer }?.items.first { $0.id == id }?.opacity
    }

    private let dissolve = SceneTransition(kind: .dissolve, duration: 0.4)
    private let cut = SceneTransition(kind: .cut, duration: 0)

    private func settledEngine() -> SceneTransitionEngine {
        let engine = SceneTransitionEngine(initial: scene(slide: "one", media: "a"))
        return engine
    }

    func testACutOnAnotherLayerLeavesTheSlideDissolving() {
        let engine = settledEngine()
        engine.push(scene(slide: "two", media: "a")) { $0 == .slide ? self.dissolve : nil }
        engine.push(scene(slide: "two", media: "b")) { _ in self.cut }
        let mid = engine.scene(at: Date().addingTimeInterval(0.1))
        XCTAssertNotNil(opacity("one::leaving", in: mid), "the old words are still fading out")
        XCTAssertLessThan(opacity("two", in: mid) ?? 1, 0.9, "the new words are still fading in")
        XCTAssertEqual(opacity("b", in: mid, .stillGraphics), 1, "the cut layer changed at once")
    }

    func testADissolveOnAnotherLayerLeavesTheSlideDissolving() {
        let engine = settledEngine()
        engine.push(scene(slide: "two", media: "a")) { $0 == .slide ? self.dissolve : nil }
        engine.push(scene(slide: "two", media: "b")) { $0 == .stillGraphics ? self.dissolve : nil }
        let mid = engine.scene(at: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(opacity("two", in: mid) ?? 1, 0.9, "the words keep fading in")
        XCTAssertLessThan(opacity("b", in: mid, .stillGraphics) ?? 1, 0.9, "the picture fades in too")
    }

    func testACutOnTheSameLayerStillCuts() {
        let engine = settledEngine()
        engine.push(scene(slide: "two", media: "a")) { $0 == .slide ? self.dissolve : nil }
        engine.push(scene(slide: "three", media: "a")) { _ in self.cut }
        let now = engine.scene(at: Date().addingTimeInterval(0.05))
        XCTAssertEqual(opacity("three", in: now), 1)
        XCTAssertNil(opacity("two::leaving", in: now))
        XCTAssertNil(opacity("one::leaving", in: now))
    }
}
