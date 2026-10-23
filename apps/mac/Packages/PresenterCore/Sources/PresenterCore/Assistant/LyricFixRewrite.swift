import Foundation

/// Writing a lyrics fix into a text box without losing what is pinned to
/// its words. Chords, style runs and animation text ranges are stored as line and
/// column positions in the text, so new words alone would leave a chord over
/// the wrong syllable on the stage display. Each changed line is matched up
/// word by word with its fixed version and every position moves with its
/// word, as the editor moves them while someone types.
extension LyricsCheck {

    /// The text with "\r\n" and "\r" as "\n": lines as chords and style runs
    /// count them.
    public static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public static func lines(of text: String) -> [String] {
        normalizedNewlines(text).components(separatedBy: "\n")
    }

    /// The box with `text` in place of its words. `addedLines` are the lines
    /// of `text` that are new (`Fix.addedLines`); the rest are the box's own
    /// lines, in order. Nil when a chord or an animation's text range can't stay on its
    /// word: the word it sat on is gone, or the line doesn't match up. A
    /// style run that covers part of a changed line and doesn't start and end
    /// on a word that stayed is dropped.
    public static func rewrite(_ object: SlideObject, to text: String, addedLines: [Int]) -> SlideObject? {
        let anchored = !(object.chords ?? []).isEmpty || !(object.styleRuns ?? []).isEmpty
            || (object.animationSteps ?? []).contains { !($0.ranges ?? []).isEmpty }
        let crlf = object.text.replacingOccurrences(of: "\r\n", with: "\n")
        // A lone "\r" isn't a line to the renderer's positions, but is to the check.
        if anchored, crlf.contains("\r") { return nil }

        let old = crlf.components(separatedBy: "\n")
        let new = text.components(separatedBy: "\n")
        let added = Set(addedLines)
        guard added.count == addedLines.count, added.allSatisfy({ new.indices.contains($0) }),
              new.count - added.count == old.count
        else { return nil }
        let target = new.indices.filter { !added.contains($0) }
        let maps = old.indices.map { LineMap(old[$0], new[target[$0]]) }

        var result = object
        result.text = text
        guard anchored else { return result }

        if let chords = object.chords, !chords.isEmpty {
            var moved: [ChordPlacement] = []
            for chord in chords {
                guard old.indices.contains(chord.line) else { return nil }
                guard let column = maps[chord.line].column(chord.column) else { return nil }
                moved.append(ChordPlacement(line: target[chord.line], column: column, symbol: chord.symbol))
            }
            result.chords = moved
        }

        if let runs = object.styleRuns, !runs.isEmpty {
            let moved = runs.compactMap { run -> TextStyleRun? in
                guard old.indices.contains(run.line),
                      let span = maps[run.line].span(run.column, run.length) else { return nil }
                var out = run
                out.line = target[run.line]
                out.column = span.column
                out.length = span.length
                return out
            }
            result.styleRuns = moved.isEmpty ? nil : moved
        }

        if let steps = object.animationSteps {
            var out: [AnimationStep] = []
            for var step in steps {
                if let stepRanges = step.ranges, !stepRanges.isEmpty {
                    var moved: [AnimationRange] = []
                    for range in stepRanges {
                        guard old.indices.contains(range.line),
                              let span = maps[range.line].span(range.column, range.length) else { return nil }
                        moved.append(AnimationRange(line: target[range.line], column: span.column, length: span.length))
                    }
                    step.ranges = moved
                }
                out.append(step)
            }
            result.animationSteps = out
        }
        return result
    }

    /// One line against its fixed version: each old word, and the new word
    /// in its place (nil for a word taken out).
    struct LineMap {
        struct Token {
            var start: Int
            var end: Int
            var text: String
        }

        let old: [Token]
        let new: [Token]
        let oldCount: Int
        let newCount: Int
        /// For each old token, the new token it became.
        let target: [Int?]
        let unchanged: Bool

        init(_ oldLine: String, _ newLine: String) {
            old = Self.tokens(oldLine)
            new = Self.tokens(newLine)
            oldCount = oldLine.count
            newCount = newLine.count
            unchanged = oldLine == newLine
            target = unchanged ? Array(old.indices.map { Optional($0) }) : Self.align(old, new)
        }

        static func tokens(_ line: String) -> [Token] {
            var out: [Token] = []
            var start: Int?
            var text = ""
            for (index, character) in line.enumerated() {
                if character.isWhitespace {
                    if let begun = start { out.append(Token(start: begun, end: index, text: text)) }
                    start = nil
                    text = ""
                } else {
                    if start == nil { start = index }
                    text.append(character)
                }
            }
            if let begun = start { out.append(Token(start: begun, end: line.count, text: text)) }
            return out
        }

        static func loose(_ token: String) -> String {
            String(token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber })
        }

        /// Words in order: the same word first, then the same letters, then
        /// a near miss. Between two matched words, the rest pair up in turn
        /// (a word replaced by another); what's left over was taken out or
        /// put in.
        static func align(_ a: [Token], _ b: [Token]) -> [Int?] {
            let la = a.map { loose($0.text) }, lb = b.map { loose($0.text) }
            func weight(_ i: Int, _ j: Int) -> Int {
                if a[i].text == b[j].text { return 3 }
                guard !la[i].isEmpty, !lb[j].isEmpty else { return 0 }
                if la[i] == lb[j] { return 2 }
                return LyricsCheck.isClose(la[i], lb[j]) ? 1 : 0
            }
            let n = a.count, m = b.count
            var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            if n > 0, m > 0 {
                for i in 1...n {
                    for j in 1...m {
                        let w = weight(i - 1, j - 1)
                        table[i][j] = max(table[i - 1][j], table[i][j - 1], w > 0 ? table[i - 1][j - 1] + w : 0)
                    }
                }
            }
            var pairs: [(Int, Int)] = []
            var i = n, j = m
            while i > 0, j > 0 {
                let w = weight(i - 1, j - 1)
                if w > 0, table[i][j] == table[i - 1][j - 1] + w {
                    pairs.append((i - 1, j - 1))
                    i -= 1
                    j -= 1
                } else if table[i - 1][j] >= table[i][j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            var target = [Int?](repeating: nil, count: n)
            var lastA = 0, lastB = 0
            for (pa, pb) in pairs.reversed() + [(n, m)] {
                for offset in 0..<min(pa - lastA, pb - lastB) { target[lastA + offset] = lastB + offset }
                if pa < n { target[pa] = pb }
                lastA = pa + 1
                lastB = pb + 1
            }
            return target
        }

        /// Where a position on the old line lands on the new one: on the same
        /// letter of its word (or the word's last, if the word got shorter).
        /// Between words it goes with the word after it.
        func column(_ column: Int) -> Int? {
            if unchanged { return column }
            if column >= oldCount { return newCount }
            if let index = old.firstIndex(where: { $0.start <= column && column < $0.end }) {
                guard let to = target[index] else { return nil }
                let word = new[to]
                return word.start + min(column - old[index].start, max(0, word.end - word.start - 1))
            }
            guard let next = old.firstIndex(where: { $0.start > column }) else { return newCount }
            guard let to = target[next] else { return nil }
            let floor = to > 0 ? new[to - 1].end : 0
            return max(floor, new[to].start - (old[next].start - column))
        }

        /// A run of the old line on the new one: the whole line stays the
        /// whole line; otherwise it must start and end on words that stayed.
        func span(_ column: Int, _ length: Int) -> (column: Int, length: Int)? {
            if unchanged { return (column, length) }
            let end = column + length
            if column <= 0, end >= oldCount { return (0, newCount) }
            let start: Int?
            if column <= 0 {
                start = 0
            } else {
                start = old.firstIndex { $0.start == column }.flatMap { target[$0] }.map { new[$0].start }
            }
            let finish: Int?
            if end >= oldCount {
                finish = newCount
            } else {
                finish = old.firstIndex { $0.end == end }.flatMap { target[$0] }.map { new[$0].end }
            }
            guard let start, let finish, finish > start else { return nil }
            return (start, finish - start)
        }
    }
}

extension LyricsCheck.Report {
    /// The fixes that go together with a slide's: its own and those of every
    /// slide with the same words, whichever of them is named.
    public func fixes(with slideID: String) -> [LyricsCheck.Fix] {
        guard let fix = fixes.first(where: { $0.slideID == slideID }) else { return [] }
        let first = fix.copyOf ?? fix.slideID
        return fixes.filter { $0.slideID == first || $0.copyOf == first }
    }
}
