import Foundation

/// A Shepherd chord chart read into sections and a song order.
///
/// Shepherd writes charts as ChordPro-style text: section headings on their
/// own line ("Verse 1", "Pre-Chorus 2", "Bridge 1 (2x) (Girl lead)"), chords
/// inline before the syllable ("This weary [F]soul"), instrumental lines
/// that are only chords ("[C] [/] [/] [|]"), and a heading with nothing
/// under it to say an earlier section comes back ("Chorus", "Intro (1x)").
/// Lines are kept as written here; `LyricCleanup` tidies them for slides.
public struct ShepherdChart: Equatable, Sendable {

    public struct Heading: Equatable, Sendable {
        /// "Bridge 1", without performance notes.
        public var name: String
        /// "(2x)", "x2", "2x" on the heading.
        public var repeatCount: Int?
        /// The other parenthetical notes ("Girl lead"), which aren't part of
        /// the name.
        public var notes: [String]
    }

    public struct Section: Equatable, Sendable {
        public var name: String
        public var repeatCount: Int?
        public var notes: [String]
        /// Blank-line separated groups of lines, each line as written
        /// (inline chords and all).
        public var stanzas: [[String]]

        /// True when the section has words to sing, not only chords.
        public var hasLyrics: Bool {
            stanzas.joined().contains { !Self.isChordOnly($0) }
        }

        static func isChordOnly(_ line: String) -> Bool {
            LyricCleanup.cleanLine(line, removePunctuation: true, chart: true) == nil
        }
    }

    public var title: String?
    public var artist: String?
    public var key: String?
    public var tempo: String?
    public var timeSignature: String?
    public var ccli: String?
    public var copyright: String?
    /// Each section once, in the order the chart first writes it.
    public var sections: [Section] = []
    /// The chart's own order: an index into `sections` per heading,
    /// repeats included.
    public var order: [Int] = []

    public init() {}

    // MARK: Parsing

    public static func parse(_ text: String) -> ShepherdChart {
        var chart = ShepherdChart()
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        // A chords-over-lyrics chart is put into inline form first.
        let hasInline = lines.contains { !ChordMath.extractLine($0).chords.isEmpty }
        if !hasInline, lines.indices.contains(where: {
            ChordChartImport.isChordLine(lines[$0], nextLine: $0 + 1 < lines.count ? lines[$0 + 1] : nil)
        }) {
            lines = ChordChartImport.mergeChordsOverLyrics(lines.joined(separator: "\n")).components(separatedBy: "\n")
        }

        let hasHeadings = lines.contains { heading(of: $0) != nil || directiveHeading($0) != nil }
        var current: (heading: Heading, stanzas: [[String]], pending: [String])?
        var verseCount = 0
        var preamble: [String] = []

        func close() {
            guard var section = current else { return }
            current = nil
            if !section.pending.isEmpty { section.stanzas.append(section.pending) }
            let heading = section.heading
            if section.stanzas.isEmpty {
                // A bare heading brings back an earlier section.
                if let index = chart.sectionIndex(named: heading.name) {
                    chart.order.append(index)
                    return
                }
            } else if let index = chart.sectionIndex(named: heading.name),
                      chart.sections[index].stanzas == section.stanzas {
                chart.order.append(index)
                return
            }
            chart.sections.append(Section(
                name: chart.uniqueName(heading.name), repeatCount: heading.repeatCount,
                notes: heading.notes, stanzas: section.stanzas))
            chart.order.append(chart.sections.count - 1)
        }

        func open(_ heading: Heading) {
            close()
            current = (heading, [], [])
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let directive = directive(line) {
                if let heading = directiveHeading(line) {
                    open(heading)
                } else {
                    chart.apply(directive)
                }
                continue
            }
            if line.isEmpty {
                if hasHeadings {
                    if let pending = current?.pending, !pending.isEmpty {
                        current?.stanzas.append(pending)
                        current?.pending = []
                    }
                } else {
                    close()
                }
                continue
            }
            if let heading = heading(of: line) {
                open(heading)
                continue
            }
            if ChordChartImport.isFooterLine(line) { continue }
            // Title and artist lines above the first heading aren't lyrics.
            if current == nil, hasHeadings, chart.sections.isEmpty, ChordMath.extractLine(line).chords.isEmpty {
                preamble.append(line)
                continue
            }
            if current == nil {
                verseCount += 1
                current = (Heading(name: "Verse \(verseCount)", repeatCount: nil, notes: []), [], [])
            }
            current?.pending.append(line)
        }
        close()
        if !preamble.isEmpty {
            let header = ChordChartImport.header(from: preamble).0
            chart.title = chart.title ?? header.title
            chart.artist = chart.artist ?? header.artist
            chart.key = chart.key ?? header.key
        }
        return chart
    }

    /// The section a name points to: the same name, else the same kind of
    /// section ("Chorus" for "Chorus 1", "Verse 1" for "Verse"), the first
    /// one written. Shepherd's short names ("V1", "C") count.
    public func sectionIndex(named name: String) -> Int? {
        let wanted = PlanItemSync.normalizeSection(name)
        if let exact = sections.firstIndex(where: { PlanItemSync.normalizeSection($0.name) == wanted }) {
            return exact
        }
        let base = Self.baseName(wanted)
        return sections.firstIndex { Self.baseName(PlanItemSync.normalizeSection($0.name)) == base }
    }

    /// Section indexes for an arrangement's sequence ("Verse 1", "Chorus",
    /// …); names that match no section are skipped. Nil when none match.
    public func order(for sequence: [String]) -> [Int]? {
        let order = sequence.compactMap { sectionIndex(named: $0) }
        return order.isEmpty ? nil : order
    }

    /// "chorus 2" → "chorus", "verse 1b" → "verse".
    static func baseName(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: #"\s*\d+[a-z]?$"#, with: "", options: .regularExpression)
    }

    private func uniqueName(_ name: String) -> String {
        let taken = Set(sections.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return "\(name) \(number)"
    }

    // MARK: Text out

    /// Each section once with its heading, chords inline; what the song
    /// editor shows.
    public func chordPro(removePunctuation: Bool = true) -> String {
        text(removePunctuation: removePunctuation, keepChords: true)
    }

    /// Each section once with its heading, words only.
    public func lyrics(removePunctuation: Bool = true) -> String {
        text(removePunctuation: removePunctuation, keepChords: false)
    }

    /// A section's stanzas as slide lines: tidied, chord-only lines gone.
    public func cleanedStanzas(_ section: Section, removePunctuation: Bool = true) -> [[String]] {
        section.stanzas.map { stanza in
            stanza.compactMap { LyricCleanup.cleanLine($0, removePunctuation: removePunctuation, chart: true) }
                .filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
    }

    private func text(removePunctuation: Bool, keepChords: Bool) -> String {
        var blocks: [String] = []
        for section in sections {
            let stanzas = cleanedStanzas(section, removePunctuation: removePunctuation).map { stanza in
                stanza.map { keepChords ? $0 : ChordMath.extractLine($0).text }.joined(separator: "\n")
            }
            blocks.append(([section.name] + [stanzas.joined(separator: "\n\n")]).filter { !$0.isEmpty }
                .joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Headings

    private static let knownSections = [
        "verse", "chorus", "pre[- ]?chorus", "post[- ]?chorus", "half[- ]?chorus", "bridge", "tag", "intro",
        "outro", "ending", "refrain", "interlude", "vamp", "breakdown", "instrumental", "turnaround",
        "hook", "channel", "coda", "solo", "spontaneous", "build", "reprise", "exhortation", "misc",
        "rap", "descant", "outro tag", "ending tag",
    ].joined(separator: "|")

    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(?:repeat\s+)?(?:(?:final|last|big|double|soft|quiet|closing|opening|alt|alternate|new)\s+)?(?:\#(knownSections))\s*(?:\d+[a-z]?)?$"#,
        options: [.caseInsensitive])

    private static let repeatPattern = try! NSRegularExpression(
        pattern: #"^(?:x\s*(\d+)|(\d+)\s*x)$"#, options: [.caseInsensitive])

    /// A heading line, or nil for a lyric or chord line. Performance notes in
    /// parentheses come off the name; "(2x)" is kept as a repeat count.
    public static func heading(of line: String) -> Heading? {
        var core = line.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty, core.count <= 60, ChordMath.extractLine(core).chords.isEmpty else { return nil }
        if core.hasPrefix("["), core.hasSuffix("]") { core = String(core.dropFirst().dropLast()) }
        if core.hasSuffix(":") { core.removeLast() }

        var notes: [String] = []
        var repeatCount: Int?
        while let open = core.firstIndex(of: "("),
              let close = core[open...].firstIndex(of: ")") {
            let note = core[core.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            core.removeSubrange(open...close)
            if let count = repeatNumber(note) { repeatCount = count } else if !note.isEmpty { notes.append(note) }
        }
        var words = core.split(separator: " ").map(String.init)
        if let last = words.last, words.count > 1, let count = repeatNumber(last) {
            repeatCount = count
            words.removeLast()
        }
        core = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :-–—"))
        guard !core.isEmpty, core.rangeOfCharacter(from: CharacterSet(charactersIn: ",.!?;\"“”")) == nil else { return nil }

        let name: String
        if let label = Reflow.labelName(of: core) {
            name = label
        } else if headingPattern.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil {
            name = titleCased(core)
        } else {
            // Unknown names stay lyrics: "Holy (Holy)" and "Hallelujah (2x)"
            // are sung lines, not headings.
            return nil
        }
        if name.lowercased().hasPrefix("repeat ") {
            return Heading(name: String(name.dropFirst(7)), repeatCount: repeatCount, notes: notes)
        }
        return Heading(name: name, repeatCount: repeatCount, notes: notes)
    }

    private static func repeatNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = repeatPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: trimmed) { return Int(trimmed[range]) }
        }
        return nil
    }

    /// "VERSE 1" → "Verse 1", "pre chorus" → "Pre-Chorus", "1b" stays.
    static func titleCased(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\b(pre|post|half)[ ]?chorus"#, with: "$1-chorus", options: .regularExpression)
            .split(separator: " ")
            .map { word in
                word.split(separator: "-", omittingEmptySubsequences: false)
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: "-")
            }
            .joined(separator: " ")
    }

    // MARK: ChordPro directives

    private static func directive(_ line: String) -> (key: String, value: String?)? {
        guard line.hasPrefix("{"), line.hasSuffix("}"), line.count >= 3 else { return nil }
        let body = line.dropFirst().dropLast()
        let parts = body.split(separator: ":", maxSplits: 1)
        guard let key = parts.first?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return (key, value?.isEmpty == true ? nil : value)
    }

    /// `{start_of_chorus}`, `{soc: Chorus 2}`, `{c: Bridge}`, `{chorus}`.
    private static func directiveHeading(_ line: String) -> Heading? {
        guard let (key, value) = directive(line) else { return nil }
        switch key {
        case "start_of_chorus", "soc", "chorus":
            return value.flatMap(heading(of:)) ?? Heading(name: "Chorus", repeatCount: nil, notes: [])
        case "start_of_verse", "sov":
            return value.flatMap(heading(of:)) ?? Heading(name: "Verse", repeatCount: nil, notes: [])
        case "start_of_bridge", "sob":
            return value.flatMap(heading(of:)) ?? Heading(name: "Bridge", repeatCount: nil, notes: [])
        case "comment", "c", "ci", "comment_italic", "start_of_part", "sop":
            return value.flatMap(heading(of:))
        default:
            return nil
        }
    }

    private mutating func apply(_ directive: (key: String, value: String?)) {
        guard let value = directive.value else { return }
        switch directive.key {
        case "title", "t": title = value
        case "artist", "subtitle", "st", "author", "composer": if artist == nil { artist = value }
        case "key": if ChordMath.parseKey(value) != nil { key = value }
        case "tempo", "bpm": tempo = value
        case "time": timeSignature = value
        case "ccli": ccli = value.filter(\.isNumber)
        case "copyright": copyright = value
        default: break
        }
    }
}
