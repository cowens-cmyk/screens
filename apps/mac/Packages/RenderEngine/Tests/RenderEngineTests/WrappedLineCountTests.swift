import CoreGraphics
import Testing
@testable import RenderEngine

/// Song slides are split by how many lines their words take on screen, so
/// the count has to include wraps, at the size the text is drawn.
@Suite struct WrappedLineCountTests {
    let box = CGSize(width: 1200, height: 300)

    @Test func countsLineBreaksAndWraps() throws {
        let short = StyledText(string: "Lift up your heads", fontName: "Helvetica Neue", fontSize: 60)
        #expect(TextRasterizer.wrappedLineCount(for: short, sceneFrame: box) == 1)

        var two = short
        two.string = "Lift up your heads\nO you ancient gates"
        #expect(TextRasterizer.wrappedLineCount(for: two, sceneFrame: box) == 2)

        var wrapping = short
        wrapping.string = "Lift up your heads O you ancient gates and be lifted up you everlasting doors\nThat the King may come in"
        let count = try #require(TextRasterizer.wrappedLineCount(for: wrapping, sceneFrame: box))
        #expect(count >= 3, "the long first line wraps")
    }

    @Test func linesPastTheBottomStillCount() {
        let text = StyledText(string: "One\nTwo\nThree\nFour", fontName: "Helvetica Neue", fontSize: 60)
        #expect(TextRasterizer.wrappedLineCount(for: text, sceneFrame: CGSize(width: 1200, height: 80)) == 4)
    }

    @Test func insetsNarrowTheBox() throws {
        var text = StyledText(string: "Lift up your heads O you ancient gates", fontName: "Helvetica Neue", fontSize: 60)
        #expect(TextRasterizer.wrappedLineCount(for: text, sceneFrame: box) == 1)
        text.insetLeft = 400
        text.insetRight = 400
        let count = try #require(TextRasterizer.wrappedLineCount(for: text, sceneFrame: box))
        #expect(count > 1)
    }

    @Test func keepLinesWholeShrinksInsteadOfWrapping() {
        var text = StyledText(
            string: "Lift up your heads O you ancient gates and be lifted up", fontName: "Helvetica Neue", fontSize: 60,
            autoShrink: true, minFontSize: 10, keepLinesWhole: true)
        #expect(TextRasterizer.wrappedLineCount(for: text, sceneFrame: box) == 1)
        text.keepLinesWhole = false
        text.autoShrink = false
        #expect((TextRasterizer.wrappedLineCount(for: text, sceneFrame: box) ?? 0) > 1)
    }

    @Test func chordsDontChangeTheCount() {
        let plain = StyledText(string: "Lift up your heads", fontName: "Helvetica Neue", fontSize: 60)
        var chorded = plain
        chorded.chords = [ChordRun(line: 0, column: 0, symbol: "G")]
        #expect(TextRasterizer.wrappedLineCount(for: chorded, sceneFrame: box)
            == TextRasterizer.wrappedLineCount(for: plain, sceneFrame: box))
    }

    @Test func textNotInLinesHasNoCount() {
        var ticker = StyledText(string: "News", fontSize: 40)
        ticker.tickerSpeed = 100
        #expect(TextRasterizer.wrappedLineCount(for: ticker, sceneFrame: box) == nil)
        #expect(TextRasterizer.wrappedLineCount(for: StyledText(string: "", fontSize: 40), sceneFrame: box) == 0)
    }
}
