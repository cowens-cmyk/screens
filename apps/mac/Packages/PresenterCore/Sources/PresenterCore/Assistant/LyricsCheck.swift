import Foundation

/// Compares a song's slides with its lyrics from Shepherd, line by line and
/// word by word, so the Assistant can point out typos, missing lines, extra
/// verses and the like. The comparison happens here, deterministically: the
/// model only gets the differences, and the fixes stay with the app until
/// someone approves them, so whole songs never go into a tool result.
public enum LyricsCheck {

    // MARK: Input

    /// One slide's words, as the slide shows them.
    public struct SlideText: Equatable, Sendable {
        public var id: String
        /// The slide's section ("Verse 1"); nil when it has none.
        public var section: String?
        public var lines: [String]
        /// False when the words are spread over more than one text box: a
        /// fix writes one box, so none is offered for such a slide.
        public var editable: Bool

        public init(id: String, section: String?, lines: [String], editable: Bool = true) {
            self.id = id
            self.section = section
            self.lines = lines
            self.editable = editable
        }
    }

    /// A section of the reference lyrics.
    public struct Section: Equatable, Sendable {
        public var label: String?
        public var lines: [String]

        public init(label: String?, lines: [String]) {
            self.label = label
            self.lines = lines
        }
    }

    /// The song's lyrics as sections, cleaned the way an import cleans them
    /// (no chords or punctuation, split words joined), so slides made by
    /// Song Search compare equal to their source. The lyrics field comes
    /// first; a chord chart is read when there are no lyrics.
    public static func referenceSections(lyrics: String?, chordChart: String?) -> [Section] {
        let source: String
        if let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = LyricCleanup.clean(lyrics)
        } else if let chart = chordChart?.trimmingCharacters(in: .whitespacesAndNewlines), !chart.isEmpty {
            let pro = LyricTextImporter.detectFormat(chart) == .chordPro ? chart : ChordChartImport.chordPro(fromChart: chart)
            source = LyricCleanup.clean(pro)
        } else {
            return []
        }
        var sections: [Section] = []
        var current: Section?
        func close() {
            if let section = current, !section.lines.isEmpty { sections.append(section) }
            current = nil
        }
        for raw in LyricTextImporter.normalize(source).body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let label = Reflow.labelName(of: line) {
                close()
                current = Section(label: label, lines: [])
                continue
            }
            if line.isEmpty {
                // A blank line inside a labelled section only splits slides;
                // between unlabelled paragraphs it starts the next one.
                if current?.label == nil { close() }
                continue
            }
            let words = ChordMath.extractLine(line).text.trimmingCharacters(in: .whitespaces)
            guard words.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if current == nil { current = Section(label: nil, lines: []) }
            current?.lines.append(words)
        }
        close()
        return sections
    }

    // MARK: Output

    /// How serious a difference is, least first.
    public enum Kind: String, Sendable, Comparable, CaseIterable {
        case capitalization, spelling, wording

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    public enum WordChange: Equatable, Sendable {
        /// Nearly the same word: a letter or two, or an apostrophe, off.
        case spelling(had: String, expected: String)
        /// A different word in its place.
        case wording(had: String, expected: String)
        case missing(String)
        case extra(String)
        /// The same word with different capitals.
        case capitalization(had: String, expected: String)

        public var kind: Kind {
            switch self {
            case .capitalization: .capitalization
            case .spelling: .spelling
            case .wording, .missing, .extra: .wording
            }
        }
    }

    /// A slide line that matches a line of the lyrics, but not exactly.
    public struct LineIssue: Equatable, Sendable {
        public var slideID: String
        /// The line's place on its slide, from 0.
        public var line: Int
        public var section: String?
        public var had: String
        public var expected: String
        public var changes: [WordChange]

        public var kind: Kind { changes.map(\.kind).max() ?? .capitalization }
    }

    /// A line of the lyrics no slide has.
    public struct MissingLine: Equatable, Sendable {
        public var section: String?
        public var expected: String
        /// The slide it belongs on (beside its neighbours), and where.
        public var slideID: String?
        public var insertAt: Int
    }

    /// A slide line that isn't in the lyrics.
    public struct ExtraLine: Equatable, Sendable {
        public var slideID: String
        public var line: Int
        public var section: String?
        public var had: String
    }

    /// A whole section only one side has. `opening` is its first few words,
    /// enough to recognise it.
    public struct SectionNote: Equatable, Sendable {
        public var label: String?
        public var lines: Int
        public var opening: String
        public var slideIDs: [String]
    }

    /// A section whose words match but whose name doesn't.
    public struct Relabel: Equatable, Sendable {
        public var slides: String
        public var lyrics: String
    }

    /// The plan's song order against the order the slides play in.
    public struct Order: Equatable, Sendable {
        public var planned: [String]
        /// The arrangement the plan uses; nil when the song has none.
        public var slides: [String]?
        public var matches: Bool
        /// Planned sections the slides have no section for.
        public var notInSlides: [String]
    }

    public struct LineStart: Equatable, Sendable {
        public var slideID: String
        public var line: Int
        public var words: String
    }

    public struct CaseForm: Equatable, Sendable {
        public var text: String
        public var count: Int
    }

    /// One word written with different capitals on different slides.
    public struct CaseVariant: Equatable, Sendable {
        public var word: String
        public var forms: [CaseForm]
    }

    /// Capitalization across the slides themselves, whatever the lyrics say.
    public struct Capitalization: Equatable, Sendable {
        public var upperStarts = 0
        public var lowerStarts = 0
        /// Lines that start differently from most.
        public var oddStarts: [LineStart] = []
        public var words: [CaseVariant] = []

        public var isConsistent: Bool { oddStarts.isEmpty && words.isEmpty }
    }

    /// New words for one slide. `words` fixes wording, spelling and missing
    /// lines; `withCapitalization` also takes the lyrics' capitals.
    public struct Fix: Equatable, Sendable {
        public var slideID: String
        public var original: String
        public var words: String
        public var withCapitalization: String

        public var changesWords: Bool { words != original }
    }

    public struct Report: Equatable, Sendable {
        public var referenceLines = 0
        public var slideLines = 0
        public var matchedLines = 0
        /// Slides with the same words as an earlier slide (a chorus copied
        /// out again), compared once.
        public var repeatedSlides = 0
        public var issues: [LineIssue] = []
        public var missingLines: [MissingLine] = []
        public var extraLines: [ExtraLine] = []
        public var missingSections: [SectionNote] = []
        public var extraSections: [SectionNote] = []
        public var relabeled: [Relabel] = []
        public var order: Order?
        public var capitalization = Capitalization()
        public var fixes: [Fix] = []
        /// Slides that differ but can't be fixed by the tool.
        public var notEditable: [String] = []

        /// Same words, same lines, same sections and order. Capitals are
        /// reported but don't count against a match.
        public var wordsMatch: Bool {
            issues.allSatisfy { $0.kind == .capitalization } && missingLines.isEmpty && extraLines.isEmpty
                && missingSections.isEmpty && extraSections.isEmpty
        }
    }

    // MARK: Comparing

    /// Lines count as the same line from this similarity up (1 is equal).
    static let lineThreshold = 0.55
    /// Sections pair by name when at least this much of them matches, and
    /// by their words alone from `contentThreshold` up.
    static let labelThreshold = 0.3
    static let contentThreshold = 0.5

    public static func compare(
        slides: [SlideText], reference: [Section], planned: [String]? = nil, slideOrder: [String]? = nil
    ) -> Report {
        var report = Report()
        let position = Dictionary(slides.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Each distinct slide once, grouped by section in first-seen order.
        var seen = Set<String>()
        var groups: [SlideGroup] = []
        var unique: [SlideText] = []
        for slide in slides {
            let lines = slide.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) }) else { continue }
            let key = lines.map { words(in: $0).map(\.loose).joined(separator: " ") }.joined(separator: "/")
            guard seen.insert(key).inserted else {
                report.repeatedSlides += 1
                continue
            }
            unique.append(slide)
            let parsed = lines.enumerated().compactMap { index, text -> SlideLine? in
                let found = words(in: text)
                return found.isEmpty ? nil : SlideLine(slideID: slide.id, index: index, text: text, words: found, section: slide.section)
            }
            let label = slide.section.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            if let label, let at = groups.firstIndex(where: { $0.label.map(sectionKey) == sectionKey(label) }) {
                groups[at].lines += parsed
                if !groups[at].slideIDs.contains(slide.id) { groups[at].slideIDs.append(slide.id) }
            } else if label == nil, let last = groups.last, last.label == nil, last.slideIDs.last == unique.dropLast().last?.id {
                // Unnamed slides run together until a named one.
                groups[groups.count - 1].lines += parsed
                groups[groups.count - 1].slideIDs.append(slide.id)
            } else {
                groups.append(SlideGroup(label: label, lines: parsed, slideIDs: [slide.id]))
            }
        }

        // The lyrics' sections, a repeated one once.
        var refs: [RefGroup] = []
        for section in reference {
            let lines = section.lines.compactMap { text -> RefLine? in
                let found = words(in: text)
                return found.isEmpty ? nil : RefLine(text: text, words: found, section: section.label)
            }
            guard !lines.isEmpty else { continue }
            let content = lines.map { $0.words.map(\.loose).joined(separator: " ") }
            if refs.contains(where: { $0.lines.map { $0.words.map(\.loose).joined(separator: " ") } == content }) { continue }
            if let label = section.label, refs.contains(where: { $0.label.map(sectionKey) == sectionKey(label) }) {
                // A second chorus with other words: kept, named apart.
                refs.append(RefGroup(label: "\(label) (again)", lines: lines))
            } else {
                refs.append(RefGroup(label: section.label, lines: lines))
            }
        }

        report.referenceLines = refs.reduce(0) { $0 + $1.lines.count }
        report.slideLines = groups.reduce(0) { $0 + $1.lines.count }

        // Pair the sections: by name where both sides name them, else by words.
        var pairs: [(ref: Int, slide: Int)] = []
        let named = refs.contains { $0.label != nil } && groups.contains { $0.label != nil }
        if named {
            var takenSlides = Set<Int>()
            var takenRefs = Set<Int>()
            for (r, ref) in refs.enumerated() {
                guard let label = ref.label else { continue }
                guard let g = groups.indices.first(where: {
                    !takenSlides.contains($0) && groups[$0].label.map(sectionKey) == sectionKey(label)
                }) else { continue }
                if align(ref.lines, groups[g].lines).coverage >= labelThreshold {
                    pairs.append((r, g))
                    takenRefs.insert(r)
                    takenSlides.insert(g)
                }
            }
            var candidates: [(r: Int, g: Int, coverage: Double)] = []
            for r in refs.indices where !takenRefs.contains(r) {
                for g in groups.indices where !takenSlides.contains(g) {
                    let coverage = align(refs[r].lines, groups[g].lines).coverage
                    if coverage >= contentThreshold { candidates.append((r, g, coverage)) }
                }
            }
            for candidate in candidates.sorted(by: { ($0.coverage, -$0.r, -$0.g) > ($1.coverage, -$1.r, -$1.g) })
            where !takenRefs.contains(candidate.r) && !takenSlides.contains(candidate.g) {
                pairs.append((candidate.r, candidate.g))
                takenRefs.insert(candidate.r)
                takenSlides.insert(candidate.g)
                if let slideLabel = groups[candidate.g].label, let refLabel = refs[candidate.r].label,
                   sectionKey(slideLabel) != sectionKey(refLabel) {
                    report.relabeled.append(Relabel(slides: slideLabel, lyrics: refLabel))
                }
            }
            for (r, ref) in refs.enumerated() where !takenRefs.contains(r) {
                report.missingSections.append(SectionNote(
                    label: ref.label, lines: ref.lines.count, opening: opening(ref.lines[0].text), slideIDs: []))
            }
            for (g, group) in groups.enumerated() where !takenSlides.contains(g) {
                report.extraSections.append(SectionNote(
                    label: group.label, lines: group.lines.count, opening: group.lines.first.map { opening($0.text) } ?? "",
                    slideIDs: group.slideIDs))
            }
        } else if !refs.isEmpty || !groups.isEmpty {
            // Without names on one side, the whole song is one section.
            refs = [RefGroup(label: nil, lines: refs.flatMap(\.lines))]
            groups = [SlideGroup(label: nil, lines: groups.flatMap(\.lines), slideIDs: groups.flatMap(\.slideIDs))]
            pairs = [(0, 0)]
        }

        // Line by line within each pair.
        var lineFixes: [LineKey: (words: String, caps: String)] = [:]
        var insertions: [String: [(at: Int, text: String)]] = [:]
        for pair in pairs {
            let ref = refs[pair.ref].lines
            let lines = groups[pair.slide].lines
            var lastSlideLine: SlideLine?
            let steps = align(ref, lines).steps
            for (offset, step) in steps.enumerated() {
                switch step {
                case .pair(let r, let s):
                    let line = lines[s]
                    lastSlideLine = line
                    let compared = compareWords(ref[r], line)
                    if compared.changes.isEmpty {
                        report.matchedLines += 1
                    } else {
                        report.issues.append(LineIssue(
                            slideID: line.slideID, line: line.index, section: line.section ?? ref[r].section,
                            had: line.text, expected: ref[r].text, changes: compared.changes))
                        if compared.changes.allSatisfy({ $0.kind == .capitalization }) { report.matchedLines += 1 }
                        lineFixes[LineKey(slideID: line.slideID, line: line.index)] = (compared.words, compared.caps)
                    }
                case .missing(let r):
                    // Beside the slide line before it, else the one after.
                    var anchor: (slideID: String, at: Int)?
                    if let last = lastSlideLine {
                        anchor = (last.slideID, last.index + 1)
                    } else if let next = steps[(offset + 1)...].lazy.compactMap({ step -> SlideLine? in
                        switch step {
                        case .pair(_, let s), .extra(let s): lines[s]
                        case .missing: nil
                        }
                    }).first {
                        anchor = (next.slideID, next.index)
                    }
                    report.missingLines.append(MissingLine(
                        section: ref[r].section, expected: ref[r].text, slideID: anchor?.slideID, insertAt: anchor?.at ?? 0))
                    if let anchor { insertions[anchor.slideID, default: []].append((anchor.at, ref[r].text)) }
                case .extra(let s):
                    let line = lines[s]
                    lastSlideLine = line
                    report.extraLines.append(ExtraLine(slideID: line.slideID, line: line.index, section: line.section, had: line.text))
                }
            }
        }

        let rank = { (id: String?) in id.flatMap { position[$0] } ?? Int.max }
        report.issues.sort { (rank($0.slideID), $0.line) < (rank($1.slideID), $1.line) }
        report.extraLines.sort { (rank($0.slideID), $0.line) < (rank($1.slideID), $1.line) }

        report.order = order(planned: planned, slideOrder: slideOrder, sections: slides.compactMap(\.section))
        report.capitalization = capitalization(of: unique)

        // The fixed words, slide by slide.
        for slide in unique {
            let pending = insertions[slide.id] ?? []
            let changed = pending.isEmpty ? slide.lines.indices.contains { lineFixes[LineKey(slideID: slide.id, line: $0)] != nil } : true
            guard changed else { continue }
            guard slide.editable else {
                report.notEditable.append(slide.id)
                continue
            }
            var words: [String] = []
            var caps: [String] = []
            for index in 0...slide.lines.count {
                for insertion in pending where insertion.at == index {
                    words.append(insertion.text)
                    caps.append(insertion.text)
                }
                guard index < slide.lines.count else { break }
                let fix = lineFixes[LineKey(slideID: slide.id, line: index)]
                words.append(fix?.words ?? slide.lines[index])
                caps.append(fix?.caps ?? slide.lines[index])
            }
            let original = slide.lines.joined(separator: "\n")
            let fix = Fix(
                slideID: slide.id, original: original,
                words: words.joined(separator: "\n"), withCapitalization: caps.joined(separator: "\n"))
            if fix.words != original || fix.withCapitalization != original { report.fixes.append(fix) }
        }
        return report
    }

    // MARK: Words

    struct Word: Equatable {
        /// The word as written, without the punctuation around it.
        var core: String
        /// Lowercased letters and digits, accents folded: the word itself.
        var loose: String
        /// As loose, keeping apostrophes: "its" and "it's" differ.
        var strict: String
        /// Which whitespace-separated piece of the line it is.
        var token: Int
    }

    static func words(in line: String) -> [Word] {
        tokens(line).enumerated().compactMap { index, token in
            guard let parts = split(token) else { return nil }
            let core = String(parts.core)
            let folded = core.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let apostrophes = folded.replacingOccurrences(of: "[’‘`´]", with: "'", options: .regularExpression)
            let loose = String(folded.filter { $0.isLetter || $0.isNumber })
            let strict = String(apostrophes.filter { $0.isLetter || $0.isNumber || $0 == "'" })
            return loose.isEmpty ? nil : Word(core: core, loose: loose, strict: strict, token: index)
        }
    }

    static func tokens(_ line: String) -> [String] {
        line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A token as the punctuation before it, the word, and the punctuation
    /// after; nil when it has no letters or digits.
    static func split(_ token: String) -> (prefix: Substring, core: Substring, suffix: Substring)? {
        let isWord = { (c: Character) in c.isLetter || c.isNumber }
        guard let first = token.firstIndex(where: isWord), let last = token.lastIndex(where: isWord) else { return nil }
        return (token[..<first], token[first...last], token[token.index(after: last)...])
    }

    /// The same word give or take a typo: one letter off in a word of four
    /// or more, two in a word of eight or more.
    static func isClose(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let longest = max(a.count, b.count)
        guard longest >= 4, abs(a.count - b.count) <= 2 else { return false }
        return distance(a, b) <= (longest >= 8 ? 2 : 1)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Word pairs in order, exact matches worth more than near ones.
    static func alignWords(_ a: [Word], _ b: [Word]) -> (pairs: [(Int, Int)], score: Int) {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return ([], 0) }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        func weight(_ i: Int, _ j: Int) -> Int {
            a[i].loose == b[j].loose ? 2 : (isClose(a[i].loose, b[j].loose) ? 1 : 0)
        }
        for i in 1...n {
            for j in 1...m {
                let w = weight(i - 1, j - 1)
                table[i][j] = max(table[i - 1][j], table[i][j - 1], w > 0 ? table[i - 1][j - 1] + w : 0)
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
        return (pairs.reversed(), table[n][m])
    }

    /// 1 for the same words, about 0.5 when every word is a near miss.
    static func similarity(_ a: [Word], _ b: [Word]) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        return Double(alignWords(a, b).score) / Double(a.count + b.count)
    }

    // MARK: Lines

    struct SlideLine {
        var slideID: String
        var index: Int
        var text: String
        var words: [Word]
        var section: String?
    }

    struct RefLine {
        var text: String
        var words: [Word]
        var section: String?
    }

    struct SlideGroup {
        var label: String?
        var lines: [SlideLine]
        var slideIDs: [String]
    }

    struct RefGroup {
        var label: String?
        var lines: [RefLine]
    }

    struct LineKey: Hashable {
        var slideID: String
        var line: Int
    }

    enum Step: Equatable {
        case pair(Int, Int)
        case missing(Int)
        case extra(Int)
    }

    /// Lines in order, each lyric line paired with at most one slide line.
    static func align(_ ref: [RefLine], _ lines: [SlideLine]) -> (steps: [Step], coverage: Double) {
        let n = ref.count, m = lines.count
        var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        var similar = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        for i in 0..<n {
            for j in 0..<m {
                let value = similarity(ref[i].words, lines[j].words)
                similar[i][j] = value >= lineThreshold ? value : 0
            }
        }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let s = similar[i - 1][j - 1]
                    score[i][j] = max(score[i - 1][j], score[i][j - 1], s > 0 ? score[i - 1][j - 1] + s : 0)
                }
            }
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, similar[i - 1][j - 1] > 0, score[i][j] == score[i - 1][j - 1] + similar[i - 1][j - 1] {
                steps.append(.pair(i - 1, j - 1))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || score[i][j - 1] >= score[i - 1][j] {
                steps.append(.extra(j - 1))
                j -= 1
            } else {
                steps.append(.missing(i - 1))
                i -= 1
            }
        }
        steps.reverse()
        let paired = steps.filter { if case .pair = $0 { true } else { false } }.count
        return (steps, max(n, m) == 0 ? 0 : Double(paired) / Double(max(n, m)))
    }

    /// The word changes on a paired line, and the line with them fixed:
    /// once keeping the slide's capitals, once taking the lyrics'.
    static func compareWords(_ ref: RefLine, _ line: SlideLine) -> (changes: [WordChange], words: String, caps: String) {
        enum Edit {
            case keep(Int, caps: String?)
            case replace(Int, with: String)
            case delete(Int)
            case insert(String)
        }
        let a = ref.words, b = line.words
        var changes: [WordChange] = []
        var edits: [Edit] = []
        var i = 0, j = 0
        func gap(upTo endA: Int, _ endB: Int) {
            while i < endA, j < endB {
                changes.append(.wording(had: b[j].core, expected: a[i].core))
                edits.append(.replace(j, with: a[i].core))
                i += 1
                j += 1
            }
            while i < endA {
                changes.append(.missing(a[i].core))
                edits.append(.insert(a[i].core))
                i += 1
            }
            while j < endB {
                changes.append(.extra(b[j].core))
                edits.append(.delete(j))
                j += 1
            }
        }
        for (pa, pb) in alignWords(a, b).pairs {
            gap(upTo: pa, pb)
            if a[pa].loose != b[pb].loose || a[pa].strict != b[pb].strict {
                changes.append(.spelling(had: b[pb].core, expected: a[pa].core))
                edits.append(.replace(pb, with: a[pa].core))
            } else if a[pa].core != b[pb].core {
                changes.append(.capitalization(had: b[pb].core, expected: a[pa].core))
                edits.append(.keep(pb, caps: a[pa].core))
            } else {
                edits.append(.keep(pb, caps: nil))
            }
            i = pa + 1
            j = pb + 1
        }
        gap(upTo: a.count, b.count)

        let pieces = tokens(line.text)
        func rebuild(caps: Bool) -> String {
            var out: [String] = []
            var next = 0
            func flush(to token: Int) {
                // Tokens with no word in them ("-", "…") stay where they are.
                while next < token { out.append(pieces[next]); next += 1 }
            }
            func place(_ token: Int, _ word: String) {
                flush(to: token)
                if let parts = split(pieces[token]) { out.append(parts.prefix + word + parts.suffix) }
                next = token + 1
            }
            for edit in edits {
                switch edit {
                case .keep(let w, let fixed):
                    place(b[w].token, caps ? (fixed ?? b[w].core) : b[w].core)
                case .replace(let w, let word):
                    // Without capitals, a replaced first word keeps the slide's.
                    place(b[w].token, caps || w != 0 ? word : matchingFirstLetter(word, like: b[w].core))
                case .delete(let w):
                    flush(to: b[w].token)
                    next = b[w].token + 1
                case .insert(let word):
                    out.append(word)
                }
            }
            flush(to: pieces.count)
            return out.joined(separator: " ")
        }
        return changes.isEmpty ? ([], line.text, line.text) : (changes, rebuild(caps: false), rebuild(caps: true))
    }

    static func matchingFirstLetter(_ word: String, like model: String) -> String {
        guard let first = word.first, let modelFirst = model.first, first.isLetter, modelFirst.isLetter else { return word }
        let head = modelFirst.isUppercase ? String(first).uppercased() : String(first).lowercased()
        return head + word.dropFirst()
    }

    static func opening(_ line: String) -> String {
        let pieces = tokens(line)
        return pieces.count > 4 ? pieces.prefix(4).joined(separator: " ") + "…" : pieces.joined(separator: " ")
    }

    // MARK: Order and capitals

    /// "V1", "Verse", "Verse 1" are one section; so are "Chorus" and "Chorus 1".
    static func sectionKey(_ label: String) -> String {
        let key = PlanItemSync.normalizeSection(label)
        return key.hasSuffix(" 1") ? String(key.dropLast(2)) : key
    }

    static func order(planned: [String]?, slideOrder: [String]?, sections: [String]) -> Order? {
        guard let planned = planned?.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }), !planned.isEmpty else {
            return nil
        }
        let keys = Set(sections.map(sectionKey))
        var missing: [String] = []
        for label in planned where !keys.contains(sectionKey(label)) && !missing.contains(where: { sectionKey($0) == sectionKey(label) }) {
            missing.append(label)
        }
        let matches = slideOrder.map { $0.map(sectionKey) == planned.map(sectionKey) } ?? false
        return Order(planned: planned, slides: slideOrder, matches: matches, notInSlides: missing)
    }

    static func capitalization(of slides: [SlideText]) -> Capitalization {
        var result = Capitalization()
        var upper: [LineStart] = []
        var lower: [LineStart] = []
        var forms: [String: [String: Int]] = [:]
        var firstSeen: [String] = []
        for slide in slides {
            for (index, text) in slide.lines.enumerated() {
                let found = words(in: text)
                guard let first = found.first else { continue }
                if let letter = first.core.first, letter.isLetter {
                    let start = LineStart(slideID: slide.id, line: index, words: opening(text))
                    if letter.isUppercase { upper.append(start) } else { lower.append(start) }
                }
                for word in found.dropFirst() where word.core.contains(where: \.isLetter) {
                    if forms[word.strict] == nil { firstSeen.append(word.strict) }
                    forms[word.strict, default: [:]][word.core, default: 0] += 1
                }
            }
        }
        result.upperStarts = upper.count
        result.lowerStarts = lower.count
        if !upper.isEmpty, !lower.isEmpty {
            result.oddStarts = Array((lower.count <= upper.count ? lower : upper).prefix(6))
        }
        result.words = firstSeen.compactMap { key -> CaseVariant? in
            guard let counts = forms[key], counts.count > 1 else { return nil }
            let sorted = counts.map { CaseForm(text: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.text) > ($1.count, $0.text) }
            return CaseVariant(word: key, forms: sorted)
        }
        .sorted { $0.forms.reduce(0) { $0 + $1.count } > $1.forms.reduce(0) { $0 + $1.count } }
        .prefix(10).map { $0 }
        return result
    }
}

// MARK: - For the model

extension LyricsCheck.Report {
    /// The differences as the Assistant reads them: slide numbers (from 1)
    /// rather than ids where it can, the differing words, and whole lines
    /// only where a line is missing, extra or reworded. Capped so a badly
    /// mismatched song can't flood the conversation.
    public func json(slideNumbers: [String: Int], limit: Int = 30) -> AssistantJSON {
        func number(_ id: String?) -> AssistantJSON { AssistantJSON(id.flatMap { slideNumbers[$0] }) }
        var fields: [String: AssistantJSON] = [
            "lines_in_lyrics": .number(Double(referenceLines)),
            "lines_on_slides": .number(Double(slideLines)),
            "lines_matching": .number(Double(matchedLines)),
            "words_match": .bool(wordsMatch),
        ]
        if repeatedSlides > 0 { fields["repeated_slides_compared_once"] = .number(Double(repeatedSlides)) }
        var truncated = false

        let wordIssues = issues.filter { $0.kind != .capitalization }
        if !wordIssues.isEmpty {
            truncated = truncated || wordIssues.count > limit
            fields["line_differences"] = .array(wordIssues.prefix(limit).map { issue in
                var row: [String: AssistantJSON] = [
                    "slide": number(issue.slideID), "line": .number(Double(issue.line + 1)),
                    "kind": .string(issue.kind.rawValue),
                    "changes": .array(issue.changes.map(Self.json)),
                ]
                if let section = issue.section { row["section"] = .string(section) }
                if issue.kind == .wording, issue.changes.count > 2 {
                    row["slide_line"] = .string(issue.had)
                    row["lyrics_line"] = .string(issue.expected)
                }
                return .object(row)
            })
        }
        let capitals = issues.filter { $0.kind == .capitalization }
        if !capitals.isEmpty {
            fields["capitalization_differences"] = [
                "count": .number(Double(capitals.count)),
                "examples": .array(capitals.prefix(6).map { issue in
                    ["slide": number(issue.slideID), "changes": .array(issue.changes.map(Self.json))]
                }),
            ]
        }
        if !missingLines.isEmpty {
            truncated = truncated || missingLines.count > limit
            fields["missing_lines"] = .array(missingLines.prefix(limit).map { line in
                var row: [String: AssistantJSON] = ["line": .string(line.expected), "goes_on_slide": number(line.slideID)]
                if let section = line.section { row["section"] = .string(section) }
                return .object(row)
            })
        }
        if !extraLines.isEmpty {
            truncated = truncated || extraLines.count > limit
            fields["extra_lines"] = .array(extraLines.prefix(limit).map { line in
                var row: [String: AssistantJSON] = ["slide": number(line.slideID), "line": .string(line.had)]
                if let section = line.section { row["section"] = .string(section) }
                return .object(row)
            })
        }
        if !missingSections.isEmpty {
            fields["missing_sections"] = .array(missingSections.map { note in
                ["label": AssistantJSON(note.label), "lines": .number(Double(note.lines)), "opens_with": .string(note.opening)]
            })
        }
        if !extraSections.isEmpty {
            fields["extra_sections"] = .array(extraSections.map { note in
                ["label": AssistantJSON(note.label), "lines": .number(Double(note.lines)), "opens_with": .string(note.opening),
                 "slides": .array(note.slideIDs.map(number))]
            })
        }
        if !relabeled.isEmpty {
            fields["section_names_differ"] = .array(relabeled.map { ["slides": .string($0.slides), "lyrics": .string($0.lyrics)] })
        }
        if let order {
            var row: [String: AssistantJSON] = [
                "plan": AssistantJSON(order.planned), "matches": .bool(order.matches),
                "slides": order.slides.map { AssistantJSON($0) } ?? "no arrangement",
            ]
            if !order.notInSlides.isEmpty { row["planned_sections_without_slides"] = AssistantJSON(order.notInSlides) }
            fields["section_order"] = .object(row)
        }
        if !capitalization.isConsistent {
            var row: [String: AssistantJSON] = [:]
            if !capitalization.oddStarts.isEmpty {
                row["line_starts"] = [
                    "capital": .number(Double(capitalization.upperStarts)),
                    "lowercase": .number(Double(capitalization.lowerStarts)),
                    "odd_ones": .array(capitalization.oddStarts.map { ["slide": number($0.slideID), "starts": .string($0.words)] }),
                ]
            }
            if !capitalization.words.isEmpty {
                row["words"] = .array(capitalization.words.map { variant in
                    .object(Dictionary(variant.forms.map { ($0.text, .number(Double($0.count))) }, uniquingKeysWith: { a, _ in a }))
                })
            }
            fields["capitalization_on_slides"] = .object(row)
        }
        if !fixes.isEmpty {
            fields["fixes"] = .array(fixes.map { fix in
                [
                    "slide": number(fix.slideID), "slide_id": .string(fix.slideID),
                    "changes_words": .bool(fix.changesWords),
                    "changes_capitals": .bool(fix.withCapitalization != fix.words),
                ]
            })
        }
        if !notEditable.isEmpty {
            fields["no_fix_offered_for_slides"] = .array(notEditable.map(number))
        }
        if truncated { fields["truncated"] = true }
        return .object(fields)
    }

    static func json(_ change: LyricsCheck.WordChange) -> AssistantJSON {
        switch change {
        case .spelling(let had, let expected), .wording(let had, let expected), .capitalization(let had, let expected):
            ["had": .string(had), "expected": .string(expected)]
        case .missing(let word): ["missing": .string(word)]
        case .extra(let word): ["extra": .string(word)]
        }
    }
}
