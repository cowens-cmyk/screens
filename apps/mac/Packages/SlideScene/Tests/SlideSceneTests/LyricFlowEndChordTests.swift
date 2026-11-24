import Foundation
import Testing
@testable import PresenterCore
@testable import SlideScene

@Suite struct LyricFlowEndChordTests {
    /// "You've already won [6m7]" on the stage: the chord after the last word
    /// stays at the end of its words, not on the next line's first.
    @Test func aChordAfterTheLastWordStaysOnItsLine() {
        let text = "I’m fighting a battle  You’ve already won \nNo matter what comes my way I will overcome"
        let chords = [
            ChordPlacement(line: 0, column: 38, symbol: "5"), ChordPlacement(line: 0, column: 42, symbol: "6m7"),
            ChordPlacement(line: 1, column: 3, symbol: "5"),
        ]
        let flowed = LyricFlow.flowed(
            text, chords: chords, width: 1720, height: 520, fontName: nil, fontSize: 120, minFontSize: 40)
        let lines = flowed.text.components(separatedBy: "\n")
        let end = flowed.chords.first { $0.symbol == "6m7" }!
        let wonLine = lines.firstIndex { $0.contains("already won") }!
        let wonEnd = lines[wonLine].range(of: "already won")!.upperBound
        #expect(end.line == wonLine)
        #expect(end.column >= lines[wonLine].distance(from: lines[wonLine].startIndex, to: wonEnd))
    }
}
