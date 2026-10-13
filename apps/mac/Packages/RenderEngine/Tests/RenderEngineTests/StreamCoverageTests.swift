import CoreGraphics
import Testing
@testable import RenderEngine

private func scene(_ items: [(LayerKind, RenderItem)], hidden: Set<LayerKind> = []) -> RenderScene {
    var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    for (layer, item) in items { scene.addItem(item, to: layer) }
    for kind in hidden { scene.setLayerHidden(true, kind: kind) }
    return scene
}

@Test func emptyStreamIsTransparent() {
    #expect(StreamCoverage.classify(scene([])) == .transparent)
}

@Test func lowerThirdLeavesTheCameraVisible() {
    let bar = RenderItem(id: "bar", frame: CGRect(x: 0, y: 820, width: 1920, height: 180),
                         content: .solid(SceneColor(red: 0, green: 0, blue: 0, alpha: 0.7)))
    #expect(StreamCoverage.classify(scene([(.overlays, bar)])) == .lowerThird)
}

@Test func fullFrameMediaCoversTheStream() {
    let video = RenderItem(id: "v", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           content: .media(id: "countdown", scaleMode: .fit))
    #expect(StreamCoverage.classify(scene([(.videos, video)])) == .fullScreen)
    #expect(StreamCoverage.classify(scene([(.videos, video)], hidden: [.videos])) == .transparent,
            "a layer the Look turns off doesn't reach the stream")
}
