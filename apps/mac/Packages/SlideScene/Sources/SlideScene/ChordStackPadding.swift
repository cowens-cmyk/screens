import CoreText
import Foundation
import PresenterCore

/// Room for chords stacked before one word on the stage display.
///
/// A chart's lead-in chords ("[5] [3m] [4]All my life") all sit before the
/// first word, so they share its column. The renderer lays each chord after
/// the one before, so the last ("4") ended up over "my" instead of "All".
/// Here the stage's copy of the words gets spaces before that word, just
/// enough for the chords before the last, so each chord reads in turn and
/// the last sits on its word, as in the chart. The audience slide is not
/// touched.
enum ChordStackPadding {

    static func padded(
        _ text: String, chords: [ChordPlacement], fontName: String?, fontSize: Double
    ) -> (text: String, chords: [ChordPlacement]) {
        guard fontSize > 0, chords.count > 1 else { return (text, chords) }
        let name = (fontName ?? "HelveticaNeue-Bold") as CFString
        let font = CTFontCreateWithName(name, fontSize, nil)
        let chordSize = fontSize * 0.9
        let chordFont = CTFontCreateCopyWithSymbolicTraits(
            CTFontCreateWithName(name, chordSize, nil), chordSize, nil, .traitBold, .traitBold)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, chordSize, nil)
        let gap = chordSize * 0.35
        func width(_ string: String, _ font: CTFont) -> Double {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: [.init(kCTFontAttributeName as String): font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let space = max(width(" ", font), 1)

        var lines = text.components(separatedBy: "\n")
        var out = chords
        for l in lines.indices {
            // Stacks on this line, right to left so earlier columns hold.
            let here = out.indices.filter { out[$0].line == l }
            let columns = Set(here.map { out[$0].column }).sorted(by: >)
            for column in columns {
                let stack = here.filter { out[$0].column == column }
                let chars = Array(lines[l])
                // Only before a word: after the last one they already run on
                // to the right with nothing under them.
                // At a word's start only: inside a word ("Ho[6m7][5]ly")
                // the spaces would split it.
                guard stack.count > 1, column >= 0, column < chars.count, chars[column] != " ",
                      column == 0 || chars[column - 1] == " " else { continue }
                var offsets: [Int] = []
                var used = 0.0
                for index in stack.dropLast() {
                    offsets.append(Int((used / space).rounded(.down)))
                    used += width(out[index].symbol, chordFont) + gap
                }
                let pad = Int((used / space).rounded(.up))
                guard pad > 0 else { continue }
                lines[l] = String(chars[..<column]) + String(repeating: " ", count: pad) + String(chars[column...])
                for index in here where out[index].column > column {
                    out[index].column += pad
                }
                for (k, index) in stack.enumerated() {
                    out[index].column = column + (k < offsets.count ? offsets[k] : pad)
                }
            }
        }
        return (lines.joined(separator: "\n"), out)
    }
}
