import Foundation

/// Tidies imported song text for slides: no punctuation, words a chart split
/// for chord placement joined back ("vic - tory" → "victory"), and lines
/// that are only chords, bar marks or repeat signs dropped — chords stay on
/// the words they belong to.
public enum LyricCleanup {

    /// Characters removed from lyrics. Apostrophes inside words stay
    /// ("God's", "'Cause").
    static let punctuation = CharacterSet(charactersIn: ".,;:!?\"“”()[]{}…–—")

    /// One ChordPro line, cleaned; nil when nothing singable is left.
    public static func cleanLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        // Directives and section labels pass through untouched.
        if trimmed.hasPrefix("{") || Reflow.labelName(of: trimmed) != nil { return trimmed }
        if trimmed == "COLUMN_BREAK" || trimmed == "PAGE_BREAK" { return nil }

        // Swap each chord for a marker the text clean-up won't touch.
        var chords: [String] = []
        var marked = ""
        var rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "[") {
            marked += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "]") else {
                marked += rest[open...]
                rest = ""
                break
            }
            let token = cleanChordToken(String(rest[after..<close]))
            if let token {
                marked += String(marker(chords.count))
                chords.append(token)
            }
            rest = rest[rest.index(after: close)...]
        }
        marked += rest

        var text = String(String.UnicodeScalarView(marked.unicodeScalars.filter { !punctuation.contains($0) }))
        // Drop bar lines, slashes and repeat signs left between chords.
        text = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}])[/|\\]+(?![\p{L}\p{N}])"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)\bx\s?\d+\b"#, with: " ", options: .regularExpression)
        // "vic - tory", "ever- more" → "victory", "evermore".
        text = text.replacingOccurrences(
            of: #"([\p{L}\#(markerClass)])\s*-\s+([\p{L}\#(markerClass)])|([\p{L}\#(markerClass)])\s+-\s*([\p{L}\#(markerClass)])"#,
            with: "$1$2$3$4", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let words = text.unicodeScalars.filter { !isMarker($0) }
        guard String(String.UnicodeScalarView(words)).contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        var output = ""
        for scalar in text.unicodeScalars {
            if isMarker(scalar) {
                output += "[\(chords[Int(scalar.value - markerBase)])]"
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// A whole song: every line cleaned, chord-only lines removed, and runs
    /// of blank lines collapsed.
    public static func clean(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            guard let line = cleanLine(raw) else { continue }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Lines without chords, for matching lyrics to a chart.
    public static func matchKey(_ line: String) -> String {
        let plain = ChordMath.extractLine(line).text.lowercased()
        return plain.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func cleanChordToken(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        return ChordMath.isChordToken(trimmed) ? trimmed : nil
    }

    private static let markerBase: UInt32 = 0xE000
    private static let markerClass = "\\x{E000}-\\x{E0FF}"
    private static func marker(_ index: Int) -> Character {
        Character(Unicode.Scalar(markerBase + UInt32(min(index, 255)))!)
    }
    private static func isMarker(_ scalar: Unicode.Scalar) -> Bool {
        (markerBase...markerBase + 255).contains(scalar.value)
    }
}
