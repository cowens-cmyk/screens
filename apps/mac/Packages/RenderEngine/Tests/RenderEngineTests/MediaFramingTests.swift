import CoreGraphics
import Testing
@testable import RenderEngine

private let canvas = CGSize(width: 1920, height: 1080)

private func scene(_ frame: CGRect = CGRect(origin: .zero, size: canvas), mode: SceneMediaScaleMode = .fit) -> RenderScene {
    var scene = RenderScene(canvasSize: canvas)
    scene.addItem(RenderItem(id: "bg", frame: frame, content: .media(id: "pic", scaleMode: mode)), to: .stillGraphics)
    return scene
}

private func items(_ scene: RenderScene) -> [RenderItem] {
    scene.layers.first { $0.kind == .stillGraphics }?.items ?? []
}

@Suite struct MediaFramingTests {
    @Test func aPictureNearlyTheScreensShapeFillsIt() {
        let framed = scene().framingMedia { _ in CGSize(width: 1918, height: 1080) }
        #expect(items(framed).count == 1)
        #expect(items(framed).first?.content == .media(id: "pic", scaleMode: .fill))
    }

    @Test func anOddShapedPictureSitsOverABlurredCopyOfItself() {
        let framed = scene().framingMedia { _ in CGSize(width: 1080, height: 1350) }
        let list = items(framed)
        #expect(list.map(\.id) == ["bg-blurfill", "bg"])
        #expect(list[0].content == .media(id: "pic", scaleMode: .fill))
        #expect(list[0].effects.contains { if case .blur = $0.kind { true } else { false } })
        #expect(list[0].opacity < 1)
        #expect(list[1].content == .media(id: "pic", scaleMode: .fit), "the whole picture, uncropped")
    }

    @Test func aBoxALineShortOfTheScreenIsSnappedToIt() {
        let framed = scene(CGRect(x: 0, y: 0, width: 1918, height: 1080)).framingMedia { _ in CGSize(width: 1920, height: 1080) }
        #expect(items(framed).first?.frame == CGRect(origin: .zero, size: canvas))
    }

    @Test func otherMediaIsLeftAlone() {
        let small = scene(CGRect(x: 100, y: 100, width: 600, height: 400))
        #expect(small.framingMedia { _ in CGSize(width: 1080, height: 1350) } == small, "not full screen")
        let filled = scene(mode: .fill)
        #expect(filled.framingMedia { _ in CGSize(width: 1080, height: 1350) } == filled, "set to Fill")
        let unknown = scene()
        #expect(unknown.framingMedia { _ in nil } == unknown, "size not known yet")
    }

    @Test func aCanvasNearlyTheOutputsShapeFillsIt() {
        let near = SceneTransform(canvasSize: CGSize(width: 1920, height: 1088), targetSize: canvas)
        #expect(near.pixelRect(CGRect(x: 0, y: 0, width: 1920, height: 1088)).width >= 1920)
        let square = SceneTransform(canvasSize: CGSize(width: 1024, height: 768), targetSize: canvas)
        let rect = square.pixelRect(CGRect(x: 0, y: 0, width: 1024, height: 768))
        #expect(rect.height == 1080 && rect.width < 1920, "4:3 still fits, uncut")
    }
}
