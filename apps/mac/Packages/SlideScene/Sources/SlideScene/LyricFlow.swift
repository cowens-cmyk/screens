import CoreText
import Foundation
import PresenterCore
import RenderEngine

/// The stage's lyrics as one run of words, broken again where they fill the
/// box rather than where the audience slide breaks them.
///
/// An audience slide is cut for the room ("Oh how I love You / Jesus I love
/// You"), and on the stage each of its lines used to be a line of its own:
/// a short one left most of the width empty and a long one shrank the whole
/// slide. Chords keep a line from wrapping in the renderer, so the breaking
/// happens here: the words are joined, then cut into whichever number of
/// lines lets them be drawn largest in the box, balanced so the lines are
/// about as long as each other. Each chord moves with the letter it sits on.
/// When the slide's own lines are already drawn as large, they stay.
public enum LyricFlow {

    public struct Flowed: Equatable, Sendable {
        public var text: String
        public var chords: [ChordPlacement]
    }

    /// - Parameters:
    ///   - width, height: the box, in the stage's own units.
    ///   - fontSize, minFontSize: the box's largest and smallest sizes.
    ///   - maxLines: at most this many lines.
    public static func flowed(
        _ text: String, chords: [ChordPlacement],
        width: Double, height: Double, fontName: String?, fontSize: Double, minFontSize: Double?,
        maxLines: Int = 4
    ) -> Flowed {
        let original = Flowed(text: text, chords: chords)
        guard width > 0, height > 0, fontSize > 0 else { return original }
        let key = Key(text: text, chords: chords.map { "\($0.line):\($0.column):\($0.symbol)" },
                      width: width, height: height, fontName: fontName,
                      fontSize: fontSize, minFontSize: minFontSize, maxLines: maxLines)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let result = compute(original, key: key)
        cache.withLock { cache in
            if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
            cache[key] = result
        }
        return result
    }

    private struct Key: Hashable {
        var text: String
        var chords: [String]
        var width: Double
        var height: Double
        var fontName: String?
        var fontSize: Double
        var minFontSize: Double?
        var maxLines: Int
    }

    private static let cache = Locked<[Key: Flowed]>([:])

    private static func compute(_ original: Flowed, key: Key) -> Flowed {
        let lines = original.text.components(separatedBy: "\n").map { Array($0) }
        // The joined words, and where each original line starts in them.
        var joined: [Character] = []
        var starts: [Int] = []
        for (index, line) in lines.enumerated() {
            if index > 0, !joined.isEmpty, !line.isEmpty, joined.last != " " { joined.append(" ") }
            starts.append(joined.count)
            joined.append(contentsOf: line)
        }
        let trimmed = String(joined).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return original }
        let positions = original.chords.compactMap { chord -> (Int, String)? in
            guard starts.indices.contains(chord.line) else { return nil }
            return (starts[chord.line] + max(0, chord.column), chord.symbol)
        }

        let font = CTFontCreateWithName((key.fontName ?? "HelveticaNeue-Bold") as CFString, key.fontSize, nil)
        let offsets = prefixWidths(String(joined), font: font)
        let spaces = joined.indices.filter { joined[$0] == " " }
        // A line with chords over it is about this much taller than one without.
        let lineHeight = key.fontSize * (original.chords.isEmpty ? 1.2 : 1.75)

        var best: (scale: Double, breaks: [Int])?
        for count in 1 ... max(1, min(key.maxLines, spaces.count + 1)) {
            let breaks = balancedBreaks(count: count, spaces: spaces, offsets: offsets, length: joined.count)
            var widest = 0.0
            var from = 0
            for end in breaks + [joined.count] {
                widest = max(widest, offsets[end] - offsets[from])
                from = min(end + 1, joined.count)
            }
            let scale = min(1, key.width / max(widest, 1), key.height / (Double(count) * lineHeight))
            // A line more only when it lets the words be drawn clearly larger.
            if best == nil || scale > best!.scale * 1.04 { best = (scale, breaks) }
            if scale >= 1 { break }
        }
        guard let breaks = best?.breaks, let bestScale = best?.scale else { return original }
        // The song's own lines, when they are already drawn as large: a
        // singer reads its phrasing more easily than a re-cut one.
        var widestOriginal = 0.0
        for (index, line) in lines.enumerated() {
            let start = starts[index]
            widestOriginal = max(widestOriginal, offsets[start + line.count] - offsets[start])
        }
        let originalScale = min(1, key.width / max(widestOriginal, 1),
                                key.height / (Double(lines.count) * lineHeight))
        // Re-cut only for words clearly larger: the phrasing is worth 10%.
        if lines.count <= key.maxLines, originalScale >= bestScale * 0.9 { return original }

        // Cut the joined words at the breaks; a chord lands on its letter.
        var outLines: [String] = []
        var lineStarts: [Int] = []
        var from = 0
        for end in breaks + [joined.count] {
            lineStarts.append(from)
            outLines.append(String(joined[from ..< end]).trimmingCharacters(in: .whitespaces))
            from = min(end + 1, joined.count)
        }
        let placed = positions.map { position, symbol -> ChordPlacement in
            let line = max(0, (lineStarts.lastIndex { $0 <= position }) ?? 0)
            let leading = String(joined[lineStarts[line]...]).prefix { $0 == " " }.count
            return ChordPlacement(line: line, column: max(0, position - lineStarts[line] - leading), symbol: symbol)
        }
        return Flowed(text: outLines.joined(separator: "\n"), chords: placed)
    }

    /// The width of the text up to each character, and the whole at the end.
    private static func prefixWidths(_ text: String, font: CTFont) -> [Double] {
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var widths: [Double] = []
        var utf16 = 0
        for character in text {
            widths.append(Double(CTLineGetOffsetForStringIndex(line, utf16, nil)))
            utf16 += character.utf16.count
        }
        widths.append(CTLineGetTypographicBounds(line, nil, nil, nil))
        return widths
    }

    /// Spaces to break at for `count` lines of about equal width.
    private static func balancedBreaks(count: Int, spaces: [Int], offsets: [Double], length: Int) -> [Int] {
        guard count > 1 else { return [] }
        let total = offsets[length]
        var breaks: [Int] = []
        var after = -1
        for part in 1 ..< count {
            let target = total * Double(part) / Double(count)
            let choices = spaces.filter { $0 > after }
            guard let nearest = choices.min(by: { abs(offsets[$0] - target) < abs(offsets[$1] - target) }) else { break }
            breaks.append(nearest)
            after = nearest
        }
        return breaks
    }
}
