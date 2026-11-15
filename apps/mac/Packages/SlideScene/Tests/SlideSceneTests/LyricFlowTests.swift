import Foundation
import PresenterCore
import Testing
@testable import SlideScene

private let flowDate = Date(timeIntervalSince1970: 1_800_000_000)

private func stageBox(_ source: TextSourceKind, maxLines: Int? = nil, flows: Bool = true) -> SlideObject {
    var box = SlideObject(id: "box", objectKind: .text, name: "Lyrics", text: "", x: 170, y: 70, width: 1720, height: 430)
    box.textLink = TextLink(source: source, maxLines: maxLines, flowsLines: flows ? true : nil)
    var style = TextStyle()
    style.fontName = "HelveticaNeue-Bold"
    style.fontSize = 112
    style.minFontSize = 60
    style.keepLinesWhole = true
    style.showChords = true
    box.textStyle = style
    return box
}

@Suite struct LyricFlowTests {

    @Test func linesAlreadyAtFullSizeKeepTheSongsPhrasing() {
        let flowed = LyricFlow.flowed(
            "Amazing grace how sweet the sound\nThat saved a wretch like me", chords: [],
            width: 1720, height: 350, fontName: "HelveticaNeue-Bold", fontSize: 80, minFontSize: 64)
        #expect(flowed.text == "Amazing grace how sweet the sound\nThat saved a wretch like me")
    }

    @Test func fiveShortLinesRunOnToBeLarger() {
        // Too many lines for the box's height at full size: run on, larger.
        let flowed = LyricFlow.flowed(
            "Holy\nHoly\nHoly\nLord God\nAlmighty", chords: [],
            width: 1720, height: 430, fontName: "HelveticaNeue-Bold", fontSize: 112, minFontSize: 60)
        #expect(flowed.text.components(separatedBy: "\n").count < 5)
    }

    @Test func longWordsBreakIntoBalancedLines() {
        let text = "And my whole life for Your glory my whole world for You only\nEverything for the honor of Your Name"
        let flowed = LyricFlow.flowed(
            text, chords: [], width: 1720, height: 430, fontName: "HelveticaNeue-Bold", fontSize: 112, minFontSize: 60)
        let lines = flowed.text.components(separatedBy: "\n")
        #expect(lines.count >= 2 && lines.count <= 4)
        #expect(lines.joined(separator: " ") == text.replacingOccurrences(of: "\n", with: " "))
        let lengths = lines.map(\.count)
        #expect(lengths.max()! - lengths.min()! < 20, "balanced: \(lines)")
    }

    @Test func chordsStayOnTheirLetters() {
        // "You be the [6m7]center" / "[1]of it [5]all"
        let chords = [
            ChordPlacement(line: 0, column: 11, symbol: "6m7"),
            ChordPlacement(line: 1, column: 0, symbol: "1"),
            ChordPlacement(line: 1, column: 6, symbol: "5"),
        ]
        let flowed = LyricFlow.flowed(
            "You be the center\nof it all", chords: chords,
            width: 1720, height: 430, fontName: "HelveticaNeue-Bold", fontSize: 112, minFontSize: 60)
        let lines = flowed.text.components(separatedBy: "\n").map { Array($0) }
        for chord in flowed.chords {
            let line = lines[chord.line]
            let rest = String(line[chord.column...])
            switch chord.symbol {
            case "6m7": #expect(rest.hasPrefix("center"))
            case "1": #expect(rest.hasPrefix("of it"))
            default: #expect(rest.hasPrefix("all"))
            }
        }
    }

    @Test func theStageBoxFlowsAndTheNextSongCarriesItsName() {
        var next = ConfidenceInfo.SlideText(body: "Maybe we've made this complicated\nMore than it was ever meant to be",
                                            chords: [ChordPlacement(line: 1, column: 0, symbol: "4")])
        next.heading = "Center"
        let info = ConfidenceInfo(next: next)
        let resolved = LinkedText.resolvedObjects([stageBox(.nextSlide, maxLines: 3)], info: info, at: flowDate)[0]
        let lines = resolved.text.components(separatedBy: "\n")
        #expect(lines == ["Center", "Maybe we've made this complicated"], "the name, then the first line")
        #expect(resolved.styleRuns?.first?.line == 0 && resolved.styleRuns?.first?.length == 6)
        #expect(resolved.chords == nil, "the second line's chord goes with it")

        // The same song's next slide has no name over it.
        let plain = ConfidenceInfo(next: ConfidenceInfo.SlideText(body: "Oh how I love You"))
        let same = LinkedText.resolvedObjects([stageBox(.nextSlide, maxLines: 3)], info: plain, at: flowDate)[0]
        #expect(same.text == "Oh how I love You" && same.styleRuns == nil)
    }

    @Test func aBoxThatKeepsLinesIsLeftAsItWas() {
        let info = ConfidenceInfo(current: ConfidenceInfo.SlideText(body: "Oh how I love You\nJesus"))
        let resolved = LinkedText.resolvedObjects([stageBox(.currentSlide, flows: false)], info: info, at: flowDate)[0]
        #expect(resolved.text == "Oh how I love You\nJesus")
    }
}
