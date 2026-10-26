import CoreGraphics
import Foundation
import Metal
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

// A song going live with its lower third on the livestream, rendered the
// way the livestream screen draws it: the live slide through the lower
// third's design, clear wherever the design draws nothing. The report: a
// lower third's black bar showed solid in the theme editor and was gone on
// the stream, and colored bars were see-through at 100% opacity.

private let canvas = CGSize(width: 1920, height: 1080)

/// The Worship theme's Lyrics lower third with its bar recolored, scoped
/// as StreamRouter hands it to the stream.
private func lowerThird(barHex: String, backdrop: ObjectFill? = nil) throws -> (theme: Theme, scoped: Theme) {
    var theme = try #require(BasicTemplates.themes().first { $0.id == BasicTemplates.worshipThemeID })
    let index = try #require(theme.slides?.firstIndex { $0.id == "worship.lower" })
    theme.slides![index].objects[0].fill = ObjectFill(fillKind: .solid, colorHex: barHex)
    theme.slides![index].backgroundFill = backdrop
    var scoped = theme.scoped(toSlideID: "worship.lower")
    scoped.slides![0].name = "Lyrics"
    return (theme, scoped)
}

private func liveStream(_ design: (theme: Theme, scoped: Theme), presentation: Presentation? = nil) -> RenderScene {
    var song = Slide(id: "song1", name: "", objects: [
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
    ])
    song.themeSlideName = "Lyrics"
    var show = ShowState()
    show.slideThemeOverrides = [design.scoped]
    show.fire(slide: song, presentation: presentation, theme: design.theme, atHostTime: 0)
    return show.scene(canvasSize: canvas, slideThemeOverride: design.scoped)
}

/// Premultiplied linear RGBA at a point in slide coordinates.
private func pixel(_ frame: RenderedFrame, x: Double, y: Double) -> SIMD4<Float> {
    let px = Int(x / canvas.width * Double(frame.width))
    let py = Int(y / canvas.height * Double(frame.height))
    return frame.data.withUnsafeBytes { raw in
        let p = (raw.baseAddress! + py * frame.bytesPerRow + px * 8).assumingMemoryBound(to: Float16.self)
        return SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3]))
    }
}

@MainActor
struct LowerThirdStreamAlphaTests {
    private func render(_ scene: RenderScene) throws -> RenderedFrame? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let compositor = try Compositor(device: device)
        return try compositor.renderFrame(scene: scene, width: 960, height: 540, at: 5, transparentBackground: true)
    }

    @Test func aSolidBlackBarIsSolidOnTheStream() throws {
        guard let frame = try render(liveStream(try lowerThird(barHex: "#000000FF"))) else { return }
        let bar = pixel(frame, x: 30, y: 1040)
        #expect(bar.w == 1, "the bar's corner, clear of the lyric, is fully opaque")
        #expect(bar.x == 0 && bar.y == 0 && bar.z == 0, "and black")
        #expect(pixel(frame, x: 960, y: 300).w == 0, "above the bar the camera shows through")
    }

    @Test func aColoredBarAtFullOpacityIsSolidOnTheStream() throws {
        guard let frame = try render(liveStream(try lowerThird(barHex: "#1E3A8AFF"))) else { return }
        let bar = pixel(frame, x: 30, y: 1040)
        let expected = SceneColor(red: 0x1E / 255.0, green: 0x3A / 255.0, blue: 0x8A / 255.0).linearPremultiplied
        #expect(bar.w == 1, "no see-through at 100%")
        #expect(abs(bar.x - expected.x) < 0.01 && abs(bar.y - expected.y) < 0.01 && abs(bar.z - expected.z) < 0.01,
                "the color as picked: \(bar) vs \(expected)")
    }

    @Test func theStreamMatchesTheThemeEditor() throws {
        let design = try lowerThird(barHex: "#7A1F2BFF")
        let lower = try #require(design.theme.slides?.first { $0.id == "worship.lower" })
        // The theme editor's canvas: the design on its own, over the grid.
        let editor = SlideSceneBuilder.scene(for: lower, theme: design.theme, canvasSize: canvas)
        guard let stream = try render(liveStream(design)), let edited = try render(editor) else { return }
        for (x, y) in [(30.0, 1040.0), (1900.0, 850.0), (960.0, 300.0), (960.0, 20.0)] {
            #expect(pixel(stream, x: x, y: y) == pixel(edited, x: x, y: y), "same pixel at \(x),\(y)")
        }
    }

    @Test func aSongsBackgroundFillStaysOffTheCamera() throws {
        var presentation = Presentation(id: "p", name: "Song", presentationKind: .song, themeId: "", slides: [])
        presentation.backgroundFill = ObjectFill(fillKind: .solid, colorHex: "#000000FF")
        let scene = liveStream(try lowerThird(barHex: "#000000FF"), presentation: presentation)
        #expect(!scene.layers.flatMap(\.items).contains { $0.id.hasSuffix("-backdrop") },
                "the room's background isn't laid over the camera")
        #expect(StreamCoverage.classify(scene) == .lowerThird)
    }

    @Test func aDesignsOwnBackdropIsOnTheStream() throws {
        // A design that does fill the frame (one made from an imported
        // slide), as the theme editor shows it.
        let scene = liveStream(try lowerThird(
            barHex: "#000000FF", backdrop: ObjectFill(fillKind: .solid, colorHex: "#102030FF")))
        #expect(scene.layers.flatMap(\.items).contains { $0.id.hasSuffix("-backdrop") })
        #expect(StreamCoverage.classify(scene) == .fullScreen)
    }
}
