import Foundation
import CoreGraphics
import PDFKit

/// Converts worship chord charts (chords-over-lyrics plain text, Planning Center `chord_chart`
/// text, or PDFs) into ChordPro-style inline text that `LyricTextImporter` understands.
public enum ChordChartImport {

    public struct Header: Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public var key: String?
        public var tempo: Double?
        public var timeSignature: String?
        public var ccli: Int?

        public init(title: String? = nil, artist: String? = nil, key: String? = nil,
                    tempo: Double? = nil, timeSignature: String? = nil, ccli: Int? = nil) {
            self.title = title
            self.artist = artist
            self.key = key
            self.tempo = tempo
            self.timeSignature = timeSignature
            self.ccli = ccli
        }
    }

    // MARK: - Chord line detection

    /// True when every whitespace-separated token is a chord symbol or chord-line mark
    /// (`|`, `-`, `N.C.`, `x2`). A lone `A` is ambiguous (the word "A"), so it only counts as a
    /// chord line when `nextLine` is given and is a lyric line.
    public static func isChordLine(_ line: String, nextLine: String? = nil) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isLabelLine(trimmed) else { return false }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.allSatisfy(isChordLineToken), tokens.contains(where: isRealChord) else { return false }
        if tokens.count == 1, tokens[0] == "A" {
            guard let nextLine else { return false }
            return isLyricLine(nextLine)
        }
        return true
    }

    static func isLyricLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !isLabelLine(t) && !isChordLine(t)
    }

    private static func stripParens(_ token: String) -> String {
        if token.count > 2, token.hasPrefix("("), token.hasSuffix(")") {
            return String(token.dropFirst().dropLast())
        }
        return token
    }

    private static func isRealChord(_ token: String) -> Bool {
        ChordMath.isChordToken(stripParens(token))
    }

    private static let repeatMarkRegex = rx(#"^\(?\s*(?:x\s*\d+|\d+\s*x)\s*\)?$"#, ci: true)

    private static func isChordLineToken(_ token: String) -> Bool {
        if isRealChord(token) { return true }
        let lowered = stripParens(token).lowercased()
        if lowered == "n.c." || lowered == "n.c" || lowered == "nc" { return true }
        if token.allSatisfy({ "|-/:.%>(),".contains($0) }) { return true }
        return matches(repeatMarkRegex, token) != nil
    }

    // MARK: - Labels

    private static let labelRepeatRegex = rx(#"^(.*?)\s*[\(\[]?\s*((?:x\s*\d+|\d+\s*x))\s*[\)\]]?\s*$"#, ci: true)

    /// Splits a trailing repeat marker ("(x2)", "2x") off a label line.
    private static func labelParts(_ line: String) -> (name: String, repeatMark: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let name = Reflow.labelName(of: trimmed) { return (name, nil) }
        if let groups = matches(labelRepeatRegex, trimmed), groups.count >= 3,
           let name = Reflow.labelName(of: groups[1]) {
            let digits = groups[2].filter(\.isNumber)
            return (name, "(x\(digits))")
        }
        return nil
    }

    private static func isLabelLine(_ line: String) -> Bool { labelParts(line) != nil }

    // MARK: - Chords over lyrics

    /// "Chords-over-lyrics" text to inline ChordPro. Repeat markers stay on label lines.
    public static func mergeChordsOverLyrics(_ text: String) -> String {
        merge(text, keepLabelRepeats: true)
    }

    static func merge(_ text: String, keepLabelRepeats: Bool) -> String {
        let lines = prepare(text)
        var out: [String] = []
        func appendBlank() { if let last = out.last, !last.isEmpty { out.append("") } }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { appendBlank(); i += 1; continue }
            if let label = labelParts(trimmed) {
                appendBlank()
                out.append(keepLabelRepeats ? label.name + (label.repeatMark.map { " " + $0 } ?? "") : label.name)
                i += 1
                continue
            }
            let next: String? = i + 1 < lines.count ? lines[i + 1] : nil
            if isChordLine(raw, nextLine: next ?? "") {
                let placed = chordPlacements(in: raw)
                if let next, isLyricLine(next) {
                    out.append(insert(placed, into: next))
                    i += 2
                    continue
                }
                if !placed.isEmpty { out.append(placed.map { "[\($0.symbol)]" }.joined(separator: " ")) }
                i += 1
                continue
            }
            out.append(trimmed)
            i += 1
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    private static func prepare(_ text: String) -> [String] {
        var t = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        for token in ["COLUMN_BREAK", "PAGE_BREAK"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return t.components(separatedBy: "\n").map { line in
            var l = line
            while l.last == " " { l.removeLast() }
            return l
        }
    }

    private static func chordPlacements(in line: String) -> [(column: Int, symbol: String)] {
        var result: [(Int, String)] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == " " { i += 1; continue }
            let start = i
            while i < chars.count, chars[i] != " " { i += 1 }
            let token = stripParens(String(chars[start..<i]))
            if ChordMath.isChordToken(token) { result.append((start, token)) }
        }
        return result
    }

    private static func insert(_ placements: [(column: Int, symbol: String)], into lyric: String) -> String {
        var chars = Array(lyric)
        var cols = placements.map(\.column)
        let leading = chars.prefix(while: { $0 == " " }).count
        let shift = min(leading, cols.min() ?? 0)
        if shift > 0 {
            chars.removeFirst(shift)
            cols = cols.map { $0 - shift }
        }
        let indexed = zip(cols, placements.map(\.symbol)).enumerated().map { ($0.offset, $0.element.0, $0.element.1) }
        for (_, col, symbol) in indexed.sorted(by: { ($0.1, $0.0) > ($1.1, $1.0) }) {
            while chars.count < col { chars.append(" ") }
            chars.insert(contentsOf: Array("[\(symbol)]"), at: col)
        }
        var s = String(chars)
        while s.last == " " { s.removeLast() }
        return s
    }

    // MARK: - Header

    private static let keyRegex = rx(#"\b(?:original\s+)?key(?:\s+of)?\s*[-:=–]?\s*([A-Ga-g][#b♯♭]?(?:\s?(?:m|min|minor))?)(?![A-Za-z])"#, ci: true)
    private static let tempoRegex = rx(#"(?:\btempo\s*[-:=–]?\s*(\d{2,3}(?:\.\d+)?)|(\d{2,3}(?:\.\d+)?)\s*bpm\b|\bbpm\s*[-:=–]?\s*(\d{2,3}(?:\.\d+)?))"#, ci: true)
    private static let timeRegex = rx(#"(?:\btime(?:\s*sig(?:nature)?)?\s*[-:=–]?\s*(\d{1,2}/\d{1,2})|^\s*(\d{1,2}/\d{1,2})\s*$)"#, ci: true)
    private static let ccliRegex = rx(#"\bccli\s*(?:song)?\s*(?:#|no\.?|number)?\s*:?\s*(\d{4,})"#, ci: true)
    private static let artistRegex = rx(#"^(?:by|artist|artists|author|authors|writer|writers|words\s+and\s+music\s+by|words\s*&\s*music\s+by|written\s+by|music\s+by)\s*[-:]?\s+(.+)$"#, ci: true)
    private static let titleRegex = rx(#"^title\s*[-:]\s*(.+)$"#, ci: true)

    private static func normalizeKey(_ raw: String) -> String? {
        var k = raw.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard let first = k.first else { return nil }
        k = first.uppercased() + k.dropFirst()
        let lowered = k.lowercased()
        if lowered.hasSuffix("minor") { k = String(k.dropLast(5)) + "m" }
        else if lowered.hasSuffix("min") { k = String(k.dropLast(3)) + "m" }
        return ChordMath.parseKey(k) != nil ? k : nil
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        matches(keyRegex, line) != nil || matches(tempoRegex, line) != nil
            || matches(timeRegex, line) != nil || matches(ccliRegex, line) != nil
            || line.localizedCaseInsensitiveContains("ccli licen")
    }

    public static func header(from lines: [String]) -> (Header, bodyStartIndex: Int) {
        var header = Header()
        var i = 0
        func isStop(_ index: Int) -> Bool {
            let l = lines[index].trimmingCharacters(in: .whitespaces)
            return isLabelLine(l) || isChordLine(l, nextLine: index + 1 < lines.count ? lines[index + 1] : "")
        }
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        guard i < lines.count else { return (header, lines.count) }

        let first = lines[i].trimmingCharacters(in: .whitespaces)
        if !isStop(i), !isMetadataLine(first), matches(artistRegex, first) == nil {
            header.title = matches(titleRegex, first)?[1] ?? first
            i += 1
        }
        var sawArtistCandidate = header.title == nil
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if isStop(i) { break }
            var consumed = false
            if let k = matches(keyRegex, line)?[1], let key = normalizeKey(k) { header.key = key; consumed = true }
            if let m = matches(tempoRegex, line) {
                if let v = m.dropFirst().first(where: { !$0.isEmpty }), let d = Double(v) { header.tempo = d }
                consumed = true
            }
            if let m = matches(timeRegex, line), let v = m.dropFirst().first(where: { !$0.isEmpty }) {
                header.timeSignature = v
                consumed = true
            }
            if let m = matches(ccliRegex, line) {
                if header.ccli == nil { header.ccli = Int(m[1]) }
                consumed = true
            } else if line.localizedCaseInsensitiveContains("ccli licen") {
                consumed = true
            }
            if !consumed {
                if let m = matches(artistRegex, line), header.artist == nil {
                    header.artist = m[1]
                    consumed = true
                } else if header.artist == nil, !sawArtistCandidate, !line.hasPrefix("©") {
                    let nextIndex = (i + 1..<lines.count).first { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                    let nextIsHeaderish = nextIndex.map { isStop($0) || isMetadataLine(lines[$0]) } ?? true
                    let blankFollows = i + 1 >= lines.count || lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty
                    if line.count <= 80, nextIsHeaderish || blankFollows {
                        header.artist = line
                        consumed = true
                    }
                }
                sawArtistCandidate = true
            }
            if !consumed { break }
            i += 1
        }
        return (header, i)
    }

    // MARK: - Full pipeline

    public static func chordPro(fromChart text: String) -> String {
        let lines = prepare(text)
        var (header, start) = Self.header(from: lines)
        if header.ccli == nil {
            header.ccli = matches(ccliRegex, text).flatMap { Int($0[1]) }
        }
        let body = lines[start...].filter { !isFooterLine($0) }.joined(separator: "\n")
        let merged = merge(body, keepLabelRepeats: false)

        func clean(_ s: String) -> String { s.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")") }
        var out: [String] = []
        if let t = header.title { out.append("{title: \(clean(t))}") }
        if let a = header.artist { out.append("{artist: \(clean(a))}") }
        if let k = header.key { out.append("{key: \(k)}") }
        if let t = header.tempo {
            out.append("{tempo: \(t == t.rounded() ? String(Int(t)) : String(t))}")
        }
        if let t = header.timeSignature { out.append("{time: \(t)}") }
        if let c = header.ccli { out.append("{ccli: \(c)}") }
        if !out.isEmpty, !merged.isEmpty { out.append("") }
        out.append(merged)
        return out.joined(separator: "\n")
    }

    private static let pageFooterRegex = rx(#"^page\s+\d+(\s+of\s+\d+)?$"#, ci: true)

    static func isFooterLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        let lowered = t.lowercased()
        return lowered.contains("ccli") || t.contains("©") || lowered.contains("all rights reserved")
            || lowered.contains("used by permission") || lowered.contains("songselect")
            || matches(pageFooterRegex, t) != nil
    }

    // MARK: - PDF

    public static func chordPro(fromPDF url: URL) -> String? {
        text(fromPDF: url).map(chordPro(fromChart:))
    }

    private struct Glyph {
        var char: Character
        var rect: CGRect
        var midX: Double { Double(rect.midX) }
        var midY: Double { Double(rect.midY) }
        var minX: Double { Double(rect.minX) }
        var maxX: Double { Double(rect.maxX) }
    }

    private struct VisualLine {
        var glyphs: [Glyph]
        var y: Double
        var text = ""
        var indices: [Int] = []
    }

    public static func text(fromPDF url: URL) -> String? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        var pages: [[String]] = []
        var ccli: Int?
        for p in 0..<doc.pageCount {
            guard let page = doc.page(at: p) else { continue }
            let (lines, found) = layout(page: page)
            if ccli == nil { ccli = found }
            if !lines.isEmpty { pages.append(lines) }
        }
        guard !pages.isEmpty else { return nil }
        var out = pages.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
        if let ccli { out += "\n\nCCLI Song # \(ccli)" }
        return out
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[s.count / 2]
    }

    private static func cluster(_ glyphs: [Glyph], tolerance: Double) -> [VisualLine] {
        let sorted = glyphs.sorted { $0.midY > $1.midY }
        var lines: [VisualLine] = []
        for g in sorted {
            if let last = lines.last, abs(last.y - g.midY) <= tolerance {
                lines[lines.count - 1].glyphs.append(g)
                let n = Double(lines[lines.count - 1].glyphs.count)
                lines[lines.count - 1].y = (last.y * (n - 1) + g.midY) / n
            } else {
                lines.append(VisualLine(glyphs: [g], y: g.midY))
            }
        }
        for i in lines.indices { lines[i].glyphs.sort { $0.minX < $1.minX } }
        return lines
    }

    private static func render(_ line: inout VisualLine, colWidth: Double) {
        var text = ""
        var indices: [Int] = []
        var prev: Glyph?
        for g in line.glyphs {
            if let prev {
                let gap = g.minX - prev.maxX
                if gap > 0.3 * colWidth { text += String(repeating: " ", count: max(1, Int((gap / colWidth).rounded()))) }
            }
            indices.append(text.count)
            text.append(g.char)
            prev = g
        }
        line.text = text
        line.indices = indices
    }

    /// Rebuilds a chord line so each chord sits over the lyric glyph nearest its x position.
    private static func realign(chord: VisualLine, over lyric: VisualLine, colWidth: Double) -> String {
        var out: [Character] = []
        let chars = Array(chord.text)
        var gi = 0
        var i = 0
        while i < chars.count {
            if chars[i] == " " { i += 1; continue }
            let start = i
            while i < chars.count, chars[i] != " " { i += 1 }
            while gi < chord.indices.count - 1, chord.indices[gi] < start { gi += 1 }
            let x = chord.glyphs[min(gi, chord.glyphs.count - 1)].minX
            var col: Int
            if let lastLyric = lyric.glyphs.last, x > lastLyric.maxX + colWidth * 0.5 {
                col = lyric.text.count + Int(((x - lastLyric.maxX) / colWidth).rounded())
            } else if lyric.glyphs.isEmpty {
                col = start
            } else {
                let k = lyric.glyphs.lastIndex(where: { $0.minX <= x + 0.25 * colWidth }) ?? 0
                let g = lyric.glyphs[k]
                if abs(x - g.minX) <= 0.5 * colWidth {
                    col = lyric.indices[k]
                } else if x >= g.maxX - 0.25 * colWidth {
                    // In the gap after `g`: keep the chord over the space when there is one.
                    if k + 1 < lyric.glyphs.count, lyric.indices[k + 1] <= lyric.indices[k] + 1 {
                        col = lyric.indices[k + 1]
                    } else {
                        col = lyric.indices[k] + 1
                    }
                } else if k + 1 < lyric.glyphs.count, abs(lyric.glyphs[k + 1].minX - x) < abs(x - g.minX) {
                    col = lyric.indices[k + 1]
                } else {
                    col = lyric.indices[k]
                }
            }
            col = max(col, out.isEmpty ? 0 : out.count + 1)
            while out.count < col { out.append(" ") }
            out.append(contentsOf: chars[start..<i])
        }
        return String(out)
    }

    private static func layout(page: PDFPage) -> (lines: [String], ccli: Int?) {
        guard let ns = page.string as NSString?, ns.length > 0 else { return ([], nil) }
        var glyphs: [Glyph] = []
        for idx in 0..<ns.length {
            let unit = ns.character(at: idx)
            guard let scalar = Unicode.Scalar(unit), !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar) else { continue }
            // Selection bounds are advance-width line boxes with a uniform height; `characterBounds(at:)`
            // drifts out of sync with `page.string` after synthesized line breaks.
            guard let selection = page.selection(for: NSRange(location: idx, length: 1)),
                  selection.string?.first == Character(scalar) else { continue }
            let r = selection.bounds(for: page)
            guard !r.isNull, !r.isInfinite, r.width > 0, r.height > 0 else { continue }
            glyphs.append(Glyph(char: Character(scalar), rect: r))
        }
        guard !glyphs.isEmpty else { return ([], nil) }
        let colWidth = max(median(glyphs.map { Double($0.rect.width) }), 1)
        let tolerance = 0.45 * median(glyphs.map { Double($0.rect.height) })

        let prelim = cluster(glyphs, tolerance: tolerance)
        var header: [VisualLine] = []
        var columns: [[VisualLine]] = []
        var footer: [VisualLine] = []

        if let split = findGutter(lines: prelim, colWidth: colWidth) {
            let band = 1.5 * colWidth
            var columnGlyphs: [[Glyph]] = [[], []]
            var crossing: [VisualLine] = []
            for line in prelim {
                if line.glyphs.contains(where: { $0.minX < split + band && $0.maxX > split - band }) {
                    crossing.append(line)
                } else {
                    for g in line.glyphs { columnGlyphs[g.midX < split ? 0 : 1].append(g) }
                }
            }
            columns = columnGlyphs.map { cluster($0, tolerance: tolerance) }
            let topY = columns.flatMap { $0 }.map(\.y).max() ?? 0
            for c in crossing { if c.y >= topY - tolerance { header.append(c) } else { footer.append(c) } }
        } else {
            columns = [prelim]
        }

        // Typical line pitch, for blank-line detection.
        var diffs: [Double] = []
        for col in columns where col.count > 1 {
            for i in 1..<col.count { diffs.append(col[i - 1].y - col[i].y) }
        }
        let pitch = median(diffs)

        var result: [String] = []
        var ccli: Int?
        func emit(_ lines: [VisualLine]) {
            var lines = lines
            for i in lines.indices { render(&lines[i], colWidth: colWidth) }
            var texts = lines.map(\.text)
            for i in lines.indices.dropLast() {
                let next = lines[i + 1].text
                if isChordLine(texts[i], nextLine: next), isLyricLine(next) {
                    texts[i] = realign(chord: lines[i], over: lines[i + 1], colWidth: colWidth)
                }
            }
            for i in lines.indices {
                if isFooterLine(texts[i]) {
                    if ccli == nil, let n = matches(ccliRegex, texts[i])?[1] { ccli = Int(n) }
                    continue
                }
                if i > 0, pitch > 0, lines[i - 1].y - lines[i].y > 1.6 * pitch, result.last?.isEmpty == false {
                    result.append("")
                }
                result.append(texts[i])
            }
        }
        emit(header)
        for (n, col) in columns.enumerated() where !col.isEmpty {
            if n > 0, result.last?.isEmpty == false { result.append("") }
            emit(col)
        }
        emit(footer)
        return (result, ccli)
    }

    /// X position of a vertical gutter splitting the page into two text columns, if any.
    private static func findGutter(lines: [VisualLine], colWidth: Double) -> Double? {
        let all = lines.flatMap(\.glyphs)
        guard lines.count >= 6, let lo = all.map(\.minX).min(), let hi = all.map(\.maxX).max(), hi > lo else { return nil }
        let width = hi - lo
        let band = 1.5 * colWidth
        var best: (crossing: Int, distance: Double, x: Double)?
        var x = lo + 0.3 * width
        while x <= lo + 0.7 * width {
            let crossing = lines.filter { l in l.glyphs.contains { $0.minX < x + band && $0.maxX > x - band } }.count
            let leftCount = all.filter { $0.midX < x }.count
            let rightCount = all.count - leftCount
            let rightLines = lines.filter { l in l.glyphs.contains { $0.minX >= x + band } }.count
            let allowed = max(1, lines.count / 10)
            if crossing <= allowed, rightLines >= 3,
               Double(leftCount) >= 0.2 * Double(all.count), Double(rightCount) >= 0.2 * Double(all.count) {
                let dist = abs(x - (lo + hi) / 2)
                if best == nil || crossing < best!.crossing || (crossing == best!.crossing && dist < best!.distance) {
                    best = (crossing, dist, x)
                }
            }
            x += 1
        }
        return best?.x
    }

    // MARK: - Regex helpers

    private static func rx(_ pattern: String, ci: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    /// Capture groups of the first match (index 0 is the whole match; unmatched groups are "").
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
