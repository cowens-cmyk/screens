import CoreGraphics
import Foundation
import RenderEngine
import Testing
@testable import SlideScene

private let canvas = CGSize(width: 1920, height: 1080)

@Test func aFullFramePictureFillsTheCanvas() {
    let full = CGRect(origin: .zero, size: canvas)
    #expect(StreamLowerThirdImage.frame(imageSize: CGSize(width: 1920, height: 1080), canvas: canvas) == full)
    #expect(StreamLowerThirdImage.frame(imageSize: CGSize(width: 3840, height: 2160), canvas: canvas) == full)
    #expect(StreamLowerThirdImage.frame(imageSize: CGSize(width: 1920, height: 1081), canvas: canvas) == full,
            "a pixel off is still full frame")
    #expect(StreamLowerThirdImage.frame(imageSize: nil, canvas: canvas) == full, "unknown size: as if full frame")
}

@Test func aWideStripSitsAtTheBottomFullWidth() {
    let frame = StreamLowerThirdImage.frame(imageSize: CGSize(width: 1920, height: 270), canvas: canvas)
    #expect(frame == CGRect(x: 0, y: 810, width: 1920, height: 270))
    let small = StreamLowerThirdImage.frame(imageSize: CGSize(width: 960, height: 135), canvas: canvas)
    #expect(small == CGRect(x: 0, y: 810, width: 1920, height: 270), "scaled to the canvas width")
}

@Test func aTallPictureKeepsItsShapeCentredAtTheBottom() {
    let frame = StreamLowerThirdImage.frame(imageSize: CGSize(width: 1000, height: 1000), canvas: canvas)
    #expect(frame == CGRect(x: 420, y: 0, width: 1080, height: 1080))
}

@Test func onlyTheSlideLayerIsSwapped() {
    var scene = RenderScene(canvasSize: canvas)
    scene.addItem(RenderItem(id: "lyric", frame: .zero, content: .solid(.black)), to: .slide)
    scene.addItem(RenderItem(id: "logo", frame: .zero, content: .solid(.black)), to: .overlays)
    scene.addItem(RenderItem(id: "announcement", frame: .zero, content: .media(id: "room", scaleMode: .fit)), to: .stillGraphics)
    let stream = StreamLowerThirdImage.scene(
        replacingSlideOf: scene, mediaID: "png", imageSize: CGSize(width: 1920, height: 270))
    let slide = stream.layers.first { $0.kind == .slide }
    #expect(slide?.items.count == 1)
    #expect(slide?.items.first?.content == .media(id: "png", scaleMode: .stretch))
    #expect(slide?.items.first?.frame == CGRect(x: 0, y: 810, width: 1920, height: 270))
    for kind in [LayerKind.overlays, .stillGraphics] {
        #expect(stream.layers.first { $0.kind == kind } == scene.layers.first { $0.kind == kind })
    }
}
