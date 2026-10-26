import Foundation

/// Tidies imported song text for slides: words a chart split for chord
/// placement joined back ("vic - [G]tory" → "victory"), lines that are only
/// chords, bar marks or repeat signs dropped, and (unless the church turns it
/// off) no punctuation — chords stay on the letters they belong to.
///
/// Every lyrics import goes through here: Shepherd, SongSelect files, pasted
/// lyrics, chord charts and PDFs. Songs already in the library are never
/// cleaned again.
public enum LyricCleanup {

    /// Characters removed from lyrics. Apostrophes stay ("God's", "'Cause",
    /// "singin'"), and so do hyphens inside a word ("twenty-two"); dashes
    /// used as punctuation are handled on their own.
    static let punctuation = CharacterSet(charactersIn: ".,;:!?¿¡\"“”„«»()[]{}…")

    /// One ChordPro line, cleaned; nil when nothing singable is left.
    ///
    /// - Parameters:
    ///   - removePunctuation: false keeps commas, periods, quotes and dashes.
    ///   - chart: whether the line comes from a chord chart, where " - "
    ///     between letters is a word split for a chord. Nil decides from the
    ///     line itself (a line with a chord is a chart line). In plain lyrics
    ///     " - " is a dash.
    public static func cleanLine(_ line: String, removePunctuation: Bool = true, chart: Bool? = nil) -> String? {
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
        let isChart = chart ?? !chords.isEmpty

        var text = marked
        // Drop bar lines, slashes and repeat signs left between chords.
        text = text.replacingOccurrences(of: #"(?<![\p{L}\p{N}])[/|\\%]+(?![\p{L}\p{N}])"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)\(?\s*\b(?:x\s?\d+|\d+\s?x)\b\s*\)?"#, with: " ", options: .regularExpression)

        // Word splits first, so they aren't taken for dashes: "ever- more"
        // and "ever -more" anywhere; "vic - tory" only in a chart.
        let letter = #"[\p{L}\#(markerClass)]"#
        text = text.replacingOccurrences(of: #"(?<=\#(letter))-[ ]+(?=\#(letter))"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\#(letter))[ ]+-(?=\#(letter))"#, with: "", options: .regularExpression)
        if isChart {
            text = text.replacingOccurrences(
                of: #"(?<=\#(letter))[ ]+[-–—][ ]+(?=\#(letter))"#, with: "", options: .regularExpression)
        }

        if removePunctuation {
            text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !punctuation.contains($0) }))
            // En and em dashes are always punctuation; a hyphen is unless
            // it joins two parts of one word.
            text = text.replacingOccurrences(of: "[–—]", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "-{2,}", with: " ", options: .regularExpression)
            let wordPart = #"[\p{L}\p{N}\#(markerClass)]"#
            text = text.replacingOccurrences(
                of: #"(?<!\#(wordPart))-|-(?!\#(wordPart))"#, with: " ", options: .regularExpression)
        }
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
    /// of blank lines collapsed. Text with any chord in it is read as a chart.
    public static func clean(_ text: String, removePunctuation: Bool = true) -> String {
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let isChart = rawLines.contains { !ChordMath.extractLine($0).chords.isEmpty }
        var lines: [String] = []
        for raw in rawLines {
            guard let line = cleanLine(raw, removePunctuation: removePunctuation, chart: isChart) else { continue }
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
