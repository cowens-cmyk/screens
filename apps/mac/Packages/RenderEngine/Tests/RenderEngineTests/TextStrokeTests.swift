import Metal
import XCTest
@testable import RenderEngine

/// A stroke on text, as every screen draws it (the editor canvas,
/// thumbnails and outputs all go through the compositor's text pass).
/// White letters with a red stroke on black, counted pixel by pixel.
@MainActor
final class TextStrokeTests: XCTestCase {
    private static let red = SceneColor(red: 1, green: 0, blue: 0)

    private func render(_ text: StyledText) throws -> RenderedFrame {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let compositor = try Compositor()
        var scene = RenderScene()
        scene.background = .black
        scene.addItem(
            RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: .text(text)),
            to: .slide)
        return try compositor.renderFrame(scene: scene, width: 960, height: 540)
    }

    private struct Counts {
        /// Pure fill: white.
        var white = 0
        /// Pure stroke: red.
        var red = 0
        var redLeft = 0
        var redRight = 0
    }

    private func count(_ frame: RenderedFrame) -> Counts {
        var counts = Counts()
        frame.data.withUnsafeBytes { raw in
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let p = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
                    let (r, g, b) = (Float(p[0]), Float(p[1]), Float(p[2]))
                    if r > 0.95, g > 0.95, b > 0.95 { counts.white += 1 }
                    if r > 0.9, g < 0.05, b < 0.05 {
                        counts.red += 1
                        if x < frame.width / 2 { counts.redLeft += 1 } else { counts.redRight += 1 }
                    }
                }
            }
        }
        return counts
    }

    private func letters(_ string: String = "Hill", outline: TextOutline? = nil) -> StyledText {
        var text = StyledText(string: string, fontName: "HelveticaNeue", fontSize: 360, color: .white)
        text.outline = outline
        return text
    }

    func testOutsideStrokeSurroundsTheLettersAndLeavesTheirFillWhole() throws {
        let plain = count(try render(letters()))
        let outside = count(try render(letters(outline: TextOutline(color: Self.red, width: 12, position: .outside))))
        XCTAssertGreaterThan(plain.white, 5000, "the letters are drawn")
        XCTAssertGreaterThan(outside.red, 3000, "the stroke shows around the letters")
        XCTAssertGreaterThan(Double(outside.white), Double(plain.white) * 0.97,
                             "the letters keep their whole fill: \(outside.white) of \(plain.white)")
    }

    func testCenteredStrokeStillDrawsOverTheEdgeAsBefore() throws {
        let plain = count(try render(letters()))
        let centered = count(try render(letters(outline: TextOutline(color: Self.red, width: 12, position: .center))))
        XCTAssertGreaterThan(centered.red, 2000, "the stroke shows")
        XCTAssertLessThan(Double(centered.white), Double(plain.white) * 0.9,
                          "half of a centred stroke lies on the letters")
    }

    func testOutsideStrokeIsAsWideAsAsked() throws {
        func extent(_ frame: RenderedFrame) -> Int {
            var minX = Int.max, maxX = -1
            frame.data.withUnsafeBytes { raw in
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        let p = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
                        if max(Float(p[0]), Float(p[1]), Float(p[2])) > 0.5 {
                            minX = min(minX, x)
                            maxX = max(maxX, x)
                        }
                    }
                }
            }
            return maxX - minX
        }
        let plain = extent(try render(letters("I")))
        let stroked = extent(try render(letters("I", outline: TextOutline(color: Self.red, width: 20, position: .outside))))
        // 20 points each side at half scale: about 20 pixels wider.
        XCTAssertEqual(Double(stroked - plain), 20, accuracy: 3)
    }

    func testAStretchCanHaveItsOwnStroke() throws {
        var text = letters("HH")
        text.styleRuns = [StyleRun(
            line: 0, column: 1, length: 1,
            outline: TextOutline(color: Self.red, width: 10, position: .outside))]
        let counts = count(try render(text))
        XCTAssertGreaterThan(counts.redRight, 1000, "the second letter is stroked")
        XCTAssertEqual(counts.redLeft, 0, "the first isn't")
    }

    func testAStretchCanTakeTheTextsStrokeOff() throws {
        var text = letters("HH", outline: TextOutline(color: Self.red, width: 10, position: .outside))
        text.styleRuns = [StyleRun(
            line: 0, column: 0, length: 1, outline: TextOutline(color: Self.red, width: 0))]
        let counts = count(try render(text))
        XCTAssertGreaterThan(counts.redRight, 1000, "the second letter keeps the stroke")
        XCTAssertEqual(counts.redLeft, 0, "the first has it taken off")
    }

    func testStrokeWithShadowAndGradientFill() throws {
        var text = letters(outline: TextOutline(color: Self.red, width: 12, position: .outside))
        text.shadow = TextShadow(color: SceneColor(red: 0, green: 0, blue: 1), blurRadius: 0, offsetX: 30, offsetY: 30)
        let shadowed = count(try render(text))
        XCTAssertGreaterThan(shadowed.red, 3000, "the stroke is drawn over its shadow")
        XCTAssertGreaterThan(shadowed.white, 5000)

        var inked = letters()
        inked.fill = .solid(.white)
        var inkedStroked = inked
        inkedStroked.outline = TextOutline(color: Self.red, width: 12, position: .outside)
        let filled = count(try render(inkedStroked))
        XCTAssertGreaterThan(filled.red, 3000, "a fill-painted text is stroked too")
        XCTAssertGreaterThan(Double(filled.white), Double(count(try render(inked)).white) * 0.97,
                             "and keeps its whole fill")
    }

    func testTextOnAPathIsStroked() throws {
        var text = letters("Hill", outline: TextOutline(color: Self.red, width: 8, position: .outside))
        text.fontSize = 160
        text.pathData = PathPresets.line
        let counts = count(try render(text))
        XCTAssertGreaterThan(counts.red, 500, "the stroke follows the letters along the path")
        XCTAssertGreaterThan(counts.white, 1000)
    }
}
