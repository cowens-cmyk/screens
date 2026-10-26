import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

// A text box's stroke and its letters' own strokes, as the slide gives
// them to the renderer every screen draws with.

private func styledText(_ object: SlideObject) throws -> StyledText {
    let item = try #require(SlideSceneBuilder.renderItems(
        for: object, theme: nil, in: CGSize(width: 1920, height: 1080)).first)
    guard case .text(let text) = item.content else {
        Issue.record("not text")
        throw CancellationError()
    }
    return text
}

@Test func aBoxStrokeKeepsItsPosition() throws {
    var object = SlideObject(id: "t", objectKind: .text, name: "Lyrics", text: "Grace")
    object.textStyle = TextStyle(outline: ObjectStroke(colorHex: "#FF0000FF", width: 6, position: .outside))
    let outline = try #require(try styledText(object).outline)
    #expect(outline.position == .outside)
    #expect(outline.width == 6)
    #expect(outline.color == SceneColor(red: 1, green: 0, blue: 0))
}

@Test func aStrokeFromBeforePositionsIsCentred() throws {
    var object = SlideObject(id: "t", objectKind: .text, name: "Lyrics", text: "Grace")
    object.textStyle = TextStyle(outline: ObjectStroke(colorHex: "#000000FF", width: 2))
    #expect(try styledText(object).outline?.position == .center)
}

@Test func lettersCarryTheirOwnStroke() throws {
    var object = SlideObject(id: "t", objectKind: .text, name: "Lyrics", text: "Amazing grace")
    object.styleRuns = [
        TextStyleRun(line: 0, column: 8, length: 5,
                     outline: ObjectStroke(colorHex: "#00FF00FF", width: 3, position: .outside)),
        TextStyleRun(line: 0, column: 0, length: 7, outline: ObjectStroke(colorHex: "#00000000", width: 0)),
    ]
    let runs = try styledText(object).styleRuns
    #expect(runs.first { $0.column == 8 }?.outline == TextOutline(
        color: SceneColor(red: 0, green: 1, blue: 0), width: 3, position: .outside))
    #expect(runs.first { $0.column == 0 }?.outline?.width == 0, "a stroke taken off stays off")
}

@Test func aLowerThirdKeepsAStrokeWithTheLettersColor() {
    let stroke = ObjectStroke(colorHex: "#000000FF", width: 4, position: .outside)
    let run = TextStyleRun(line: 0, column: 0, length: 4, outline: stroke)
    let base = ThemeOverride.BaseStyle(
        object: SlideObject(id: "t", objectKind: .text, name: "", text: "Hope"), placeholder: nil, theme: nil)
    let keepColor = ThemeOverride.Keep(KeepFromSlideOptions(textColor: true))
    #expect(ThemeOverride.carriedRun(run, from: base, to: base, keep: keepColor)?.outline == stroke)
    #expect(ThemeOverride.carriedRun(run, from: base, to: base, keep: ThemeOverride.Keep(nil)) == nil,
            "the design's look wins unless it keeps the slide's colors")
}
