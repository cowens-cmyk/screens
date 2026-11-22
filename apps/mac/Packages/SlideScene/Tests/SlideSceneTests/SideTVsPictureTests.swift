import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let canvas = CGSize(width: 1920, height: 1080)

@Test func aSideTVsPictureShapedLikeTheCanvasFillsIt() {
    let full = CGRect(origin: .zero, size: canvas)
    #expect(SideTVsPicture.frame(imageSize: CGSize(width: 3840, height: 2160), canvas: canvas) == full)
    #expect(SideTVsPicture.frame(imageSize: nil, canvas: canvas) == full)
}

@Test func anotherShapeIsCentredWithItsProportionsKept() {
    #expect(SideTVsPicture.frame(imageSize: CGSize(width: 1000, height: 1000), canvas: canvas)
            == CGRect(x: 420, y: 0, width: 1080, height: 1080))
    #expect(SideTVsPicture.frame(imageSize: CGSize(width: 3840, height: 1080), canvas: canvas)
            == CGRect(x: 0, y: 270, width: 1920, height: 540))
}

@Test func onlyASlideWithAPictureInTheLibraryHasOne() {
    var slide = Slide(id: "s", name: "Slide01_Wide", objects: [])
    #expect(SideTVsPicture.mediaID(of: slide) { _ in true } == nil)
    slide.sideTVsMediaId = "tv"
    #expect(SideTVsPicture.mediaID(of: slide) { _ in true } == "tv")
    #expect(SideTVsPicture.mediaID(of: slide) { _ in false } == nil, "a picture that's gone leaves the room's slide")
    #expect(SideTVsPicture.mediaID(of: nil) { _ in true } == nil)
}

@Test func thePictureReplacesTheSlideOverBlack() {
    var scene = RenderScene(canvasSize: canvas)
    let slideIndex = try! #require(scene.layers.firstIndex { $0.kind == .slide })
    let stillIndex = try! #require(scene.layers.firstIndex { $0.kind == .stillGraphics })
    scene.layers[slideIndex].items = [RenderItem(id: "words", frame: .zero, content: .solid(.black))]
    scene.layers[stillIndex].items = [RenderItem(
        id: "wide", frame: CGRect(origin: .zero, size: canvas), content: .media(id: "wide", scaleMode: .fill))]
    let out = SideTVsPicture.scene(replacingSlideOf: scene, mediaID: "tv", imageSize: CGSize(width: 1920, height: 1080))
    #expect(out.layers[slideIndex].items.map(\.id) == ["side-tvs-picture-backing", "side-tvs-picture-tv"])
    #expect(out.layers[slideIndex].items[0].frame == CGRect(origin: .zero, size: canvas))
    #expect(out.layers[stillIndex] == scene.layers[stillIndex], "other layers are left; the backing covers them")
}
