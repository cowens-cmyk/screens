import Foundation

/// A song's chords made to match its Shepherd chord chart, leaving its words,
/// slides and order as they are: Match Chords to Shepherd…, for songs whose
/// stage display chords had drifted from the band's charts (edited by hand,
/// imported from elsewhere, or older than the chart).
///
/// Each part of the song is matched to the chart's part of the same name
/// (else the one sharing most words), as Screens would build it from the
/// chart today (ShepherdSongImport), and their words are lined up in order,
/// however either breaks them into lines. Each chart chord goes onto its word
/// in the song, as far into it as in the chart, and chords set by hand on
/// those lines are dropped: the chart wins. A line none of whose words the
/// chart has keeps its chords.
public enum ShepherdChordMatch {

    public struct Result: Sendable {
        public var presentation: Presentation
        /// Lines whose chords were changed.
        public var changedLines: Int
        /// Lines matched to the chart (changed or already right).
        public var matchedLines: Int
        /// Lines with words the chart doesn't have, left as they were.
        public var unmatchedLines: Int
        /// Those lines' words, "Verse 1 “words”".
        public var unmatchedWords: [String] = []
        /// Chords set by hand on matched lines, now Shepherd's.
        public var droppedHandEdits: Int
        /// A few changed lines, "Verse 1 “words”: 1 4 → 1 4 5".
        public var examples: [String]

        public var changed: Bool { changedLines > 0 || droppedHandEdits > 0 }
    }

    /// Words as compared: lower case, apostrophes dropped ("I’ll" and "Ill"
    /// are the same word, as an import without punctuation writes it), any
    /// other punctuation a space.
    public static func normalized(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if apostrophes.contains(scalar) { continue }
            out.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static let apostrophes = CharacterSet(charactersIn: "'’‘`")

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c.unicodeScalars.allSatisfy { apostrophes.contains($0) }
    }

    /// Where each word starts, in characters along the line.
    static func wordStarts(_ text: String) -> [(start: Int, length: Int)] {
        var words: [(start: Int, length: Int)] = []
        var start: Int?
        let chars = Array(text)
        for (index, c) in chars.enumerated() {
            if isWordCharacter(c) {
                if start == nil { start = index }
            } else if let s = start {
                words.append((s, index - s))
                start = nil
            }
        }
        if let s = start { words.append((s, chars.count - s)) }
        return words
    }

    /// `chords` placed along `from` moved onto `to`: each over the same word
    /// (by count) and as far into it, or as far past the line's last word.
    public static func moving(_ chords: [ChordPlacement], from: String, to: String) -> [ChordPlacement] {
        let source = wordStarts(from)
        let target = wordStarts(to)
        let length = to.count
        return chords.map { chord in
            var out = chord
            guard !source.isEmpty, !target.isEmpty else {
                out.column = min(max(0, chord.column), length)
                return out
            }
            // The word the chord sits on, or the last one starting before it.
            let word = source.lastIndex { $0.start <= chord.column } ?? 0
            let offset = chord.column - source[word].start
            let into = target[min(word, target.count - 1)]
            out.column = min(max(0, into.start + offset), length)
            return out
        }
    }

    /// One word of a section, where it sits.
    struct Word {
        var ref: ChordEdits.LineRef
        var start: Int
        var length: Int
        var text: String
    }

    static func words(of refs: [ChordEdits.LineRef]) -> [Word] {
        refs.flatMap { ref in
            let chars = Array(ref.text)
            return wordStarts(ref.text).map { w in
                Word(ref: ref, start: w.start, length: w.length,
                     text: normalized(String(chars[w.start ..< w.start + w.length])))
            }.filter { !$0.text.isEmpty }
        }
    }

    /// Longest common run of words, as pairs of indices (a into `a`, b into `b`).
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    private static func sectionLines(_ presentation: Presentation) -> [(name: String, refs: [ChordEdits.LineRef])] {
        var order: [String] = []
        var groups: [String: [ChordEdits.LineRef]] = [:]
        // Each section once: its first slides' lines, as a part is written
        // once whatever the order repeats.
        var seen = Set<String>()
        for ref in ChordEdits.lines(of: presentation) {
            let id = "\(ref.section)|\(ref.text)|\(ref.occurrence)"
            guard seen.insert(id).inserted else { continue }
            if groups[ref.section] == nil { order.append(ref.section) }
            groups[ref.section, default: []].append(ref)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// `song` with the chords of `chart` (ShepherdSongImport.presentation of
    /// its Shepherd song): section by section, the song's words matched to
    /// the chart's in order, whatever lines they are broken into, and each
    /// chart chord moved onto its word.
    public static func matching(_ song: Presentation, to chart: Presentation) -> Result {
        let chartSections: [(name: String, words: [Word], refs: [ChordEdits.LineRef])] =
            sectionLines(chart).map { (name: $0.name, words: words(of: $0.refs), refs: $0.refs) }
        var result = song
        var changed = 0, matched = 0, unmatched = 0
        var examples: [String] = []
        var unmatchedWords: [String] = []
        var decided = Set<String>()

        typealias ChartPart = (name: String, words: [Word], refs: [ChordEdits.LineRef])
        func lineID(_ ref: ChordEdits.LineRef) -> String { "\(ref.slideID)|\(ref.objectID)|\(ref.line)" }

        /// The song's `mine` words lined up with `part`'s: the chart chords
        /// moved onto the song's lines, and which song lines had a word
        /// lined up. Nil when they share too few words to be the same words.
        func place(_ mine: [Word], on part: ChartPart) -> (wanted: [String: [ChordPlacement]], lines: Set<String>)? {
            let pairs = align(mine.map(\.text), part.words.map(\.text))
            guard !pairs.isEmpty, pairs.count * 2 >= mine.count || pairs.count * 2 >= part.words.count
            else { return nil }
            var chartToMine: [Int: Int] = [:]
            for (m, c) in pairs { chartToMine[c] = m }
            var wanted: [String: [ChordPlacement]] = [:]
            let byLine = Dictionary(grouping: part.words.indices, by: { lineID(part.words[$0].ref) })
            for ref in part.refs {
                let indices = byLine[lineID(ref)] ?? []
                guard !indices.isEmpty else { continue }
                for chord in ChordEdits.chords(at: ref, in: chart) {
                    // A chord in the gap before a word ("freedom [4/6] Your
                    // stripes") is that word's: the song may break the line
                    // there, and the chord belongs at the start of the next
                    // line, not the end of this one. Past the line's last
                    // word it stays at the end.
                    let inWord = indices.last { part.words[$0].start <= chord.column }
                        .map { chord.column < part.words[$0].start + part.words[$0].length } ?? false
                    let nextWord = indices.first { part.words[$0].start > chord.column }
                    let gap = !inWord && nextWord != nil
                    let onWord = gap ? nextWord! : (indices.last { part.words[$0].start <= chord.column } ?? indices[0])
                    let offset = gap ? 0 : chord.column - part.words[onWord].start
                    // A chord over a word the song lacks ("Ho-ly" where the
                    // song has "Holy") stays on its line: the next word both
                    // have on that line, else the last before it on that
                    // line; only a line with none goes to the nearest word.
                    let sameLine = Set(indices)
                    let after = (onWord ..< part.words.count).filter { chartToMine[$0] != nil }
                    let before = (0 ..< onWord).reversed().filter { chartToMine[$0] != nil }
                    guard let pick = after.first(where: sameLine.contains) ?? before.first(where: sameLine.contains)
                        ?? after.first ?? before.first, let target = chartToMine[pick]
                    else { continue }
                    // Moved back onto an earlier word: to its end, not its start.
                    let movedBack = pick < onWord
                    let word = mine[target]
                    let column = movedBack
                        ? min(word.start + word.length, word.ref.text.count)
                        : min(max(0, word.start + offset), word.ref.text.count)
                    wanted[lineID(word.ref), default: []]
                        .append(ChordPlacement(line: word.ref.line, column: column, symbol: chord.symbol))
                }
            }
            return (wanted, Set(pairs.map { lineID(mine[$0.0].ref) }))
        }

        func best(_ mine: [Word], in pool: [ChartPart]) -> (wanted: [String: [ChordPlacement]], lines: Set<String>)? {
            pool.compactMap { part -> (score: Int, placed: (wanted: [String: [ChordPlacement]], lines: Set<String>))? in
                guard let placed = place(mine, on: part) else { return nil }
                return (placed.lines.count, placed)
            }.max { $0.score < $1.score }?.placed
        }

        var wantedAll: [String: [ChordPlacement]] = [:]
        var matchedLines = Set<String>()
        let parts = chartSections.filter { !$0.words.isEmpty }
        for section in sectionLines(song) {
            let mine = words(of: section.refs)
            guard !mine.isEmpty else { continue }
            // First the chart's part of the same name, else any part.
            let named = parts.filter { normalized($0.name) == normalized(section.name) }
            var sectionMatched = Set<String>()
            if let placed = best(mine, in: named.isEmpty ? parts : named) ?? (named.isEmpty ? nil : best(mine, in: parts)) {
                wantedAll.merge(placed.wanted) { $0 + $1 }
                sectionMatched.formUnion(placed.lines)
            }
            // Then each run of lines still unmatched, against every part: a
            // verse Screens shows as one that the chart writes as two, words
            // the chart keeps in another part.
            var run: [ChordEdits.LineRef] = []
            func flush() {
                defer { run = [] }
                let runWords = words(of: run)
                guard !runWords.isEmpty, let placed = best(runWords, in: parts) else { return }
                wantedAll.merge(placed.wanted) { $0 + $1 }
                sectionMatched.formUnion(placed.lines)
            }
            for ref in section.refs {
                if sectionMatched.contains(lineID(ref)) { flush() } else { run.append(ref) }
            }
            flush()
            matchedLines.formUnion(sectionMatched)

            for ref in section.refs {
                let id = lineID(ref)
                guard sectionMatched.contains(id) else {
                    if !normalized(ref.text).isEmpty {
                        unmatched += 1
                        unmatchedWords.append("\(ref.section.isEmpty ? "" : ref.section + " ")“\(ref.text.trimmingCharacters(in: .whitespaces))”")
                    }
                    continue
                }
                matched += 1
                decided.insert("\(ref.section)|\(ref.text)|\(ref.occurrence)")
                let target = (wantedAll[id] ?? []).sorted { $0.column < $1.column }
                // Every slide showing these words gets the same chords.
                let copies = ChordEdits.lines(of: result).filter {
                    $0.section == ref.section && $0.text == ref.text && $0.occurrence == ref.occurrence
                }
                for copy in copies {
                    let current = ChordEdits.chords(at: copy, in: result)
                    let placed = target.map { ChordPlacement(line: copy.line, column: $0.column, symbol: $0.symbol) }
                    guard current.map({ "\($0.column):\($0.symbol)" }) != placed.map({ "\($0.column):\($0.symbol)" })
                    else { continue }
                    if copy.slideID == ref.slideID {
                        changed += 1
                        if examples.count < 6 {
                            let before = current.map(\.symbol).joined(separator: " ")
                            let after = placed.map(\.symbol).joined(separator: " ")
                            let label = ref.section.isEmpty ? "" : "\(ref.section) "
                            examples.append("\(label)“\(ref.text.trimmingCharacters(in: .whitespaces))”: \(before.isEmpty ? "none" : before) → \(after.isEmpty ? "none" : after)")
                        }
                    }
                    result = ChordEdits.settingChords(placed, at: copy, in: result)
                }
            }
        }
        // Hand-set chords on the lines the chart now decides go: kept, they
        // would come back over Shepherd's on the next rebuild.
        var dropped = 0
        if let edits = result.chordEdits {
            let kept = edits.filter { !decided.contains("\($0.section)|\($0.text)|\($0.occurrence)") }
            dropped = edits.count - kept.count
            result.chordEdits = kept.isEmpty ? nil : kept
        }
        return Result(
            presentation: result, changedLines: changed, matchedLines: matched, unmatchedLines: unmatched,
            unmatchedWords: unmatchedWords, droppedHandEdits: dropped, examples: examples)
    }
}
