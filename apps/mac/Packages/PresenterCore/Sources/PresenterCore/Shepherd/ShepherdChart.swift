import Foundation

/// A Shepherd chord chart read into sections and a song order.
///
/// Shepherd writes charts as ChordPro-style text: section headings on their
/// own line ("Verse 1", "Pre-Chorus 2", "Bridge 1 (2x) (Girl lead)"), chords
/// inline before the syllable ("This weary [F]soul"), instrumental lines
/// that are only chords ("[C] [/] [/] [|]"), and a heading with nothing
/// under it to say an earlier section comes back ("Chorus", "Intro (1x)").
/// Lines are kept as written here; `LyricCleanup` tidies them for slides.
///
/// A chart is usually written out in the order it is sung, and a part sung
/// again with other words or chords is written again under the same
/// heading: a last chorus that ends on another chord, a second Bridge 2
/// with a line added, a "Chorus - Breakdown". Each of those is a version of
/// its own ("Chorus (2)", "Chorus (Breakdown)"), and a song order is matched
/// to the chart in the order it is written (`order(for:)`), so each time a
/// part comes round it shows the words and chords written for that time.
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
        /// The heading it was written under ("Chorus" for "Chorus (2)").
        public var heading: String
        /// 1 for the first time a heading is written; 2, 3… for the times
        /// it is written again with other words or chords.
        public var version: Int = 1
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
    /// 2 when the chart reads differently since parts written again became
    /// versions of their own (or a "Chorus - Breakdown" heading, or a first
    /// and second ending, is read); 1 otherwise. The chart hash carries it,
    /// so only the songs whose slides change are imported again.
    public internal(set) var revision = 1

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
        var lastEnding: String?

        func close() {
            guard var section = current else { return }
            current = nil
            if !section.pending.isEmpty { section.stanzas.append(section.pending) }
            let heading = section.heading
            let versions = chart.sections.indices.filter {
                PlanItemSync.normalizeSection(chart.sections[$0].heading) == PlanItemSync.normalizeSection(heading.name)
            }
            if section.stanzas.isEmpty {
                // A bare heading brings back the part last sung under it.
                if let latest = chart.order.last(where: versions.contains) {
                    if latest != versions.first { chart.revision = 2 }
                    chart.order.append(latest)
                    return
                }
                if let index = chart.sectionIndex(named: heading.name) {
                    chart.order.append(index)
                    return
                }
            } else if let same = versions.first(where: { chart.sections[$0].stanzas == section.stanzas }) {
                chart.order.append(same)
                return
            } else if versions.isEmpty, let index = chart.sectionIndex(named: heading.name),
                      chart.sections[index].stanzas == section.stanzas {
                chart.order.append(index)
                return
            }
            if !versions.isEmpty {
                // Written again with other words or chords: a version of its own.
                chart.revision = 2
                chart.sections.append(Section(
                    name: chart.versionName(heading, number: versions.count + 1), repeatCount: heading.repeatCount,
                    notes: heading.notes, heading: heading.name, version: versions.count + 1,
                    stanzas: section.stanzas))
            } else {
                chart.sections.append(Section(
                    name: chart.uniqueName(heading.name), repeatCount: heading.repeatCount,
                    notes: heading.notes, heading: heading.name, stanzas: section.stanzas))
            }
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
            if let ending = Self.ending(line) {
                // "(1.) Of Your Name (To Br. 1b)" then "(2.) Of Your Name
                // (To Tag)": the words are sung once, so a second ending
                // with the same words as the first is left off the slide.
                chart.revision = 2
                if let last = current?.pending.last, let previous = lastEnding,
                   previous == last, Self.sameWords(previous, ending) {
                    continue
                }
                current?.pending.append(ending)
                lastEnding = ending
                continue
            }
            lastEnding = nil
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
    ///
    /// Names are read the way plan sync reads them
    /// (`ShepherdArrangementSync.label`), so an import and a later sync agree
    /// on the order: short names ("Ch", "Br", "TA") and repeats ("C (2x)",
    /// "Chorus x2") count, and a verse the chart doesn't have ("Verse 3") is
    /// skipped rather than shown as Verse 1's words. A wordless part played
    /// twice is still one blank.
    ///
    /// The sequence is walked along the chart as it is written, so a part
    /// written more than once plays the version written for that place:
    /// - the next part written, when it is the one named;
    /// - else the part just played, again ("Refrain, Refrain" where the
    ///   chart writes the refrain once);
    /// - else the next part written further on under that name (the
    ///   sequence leaves out what comes between);
    /// - else, past the end of the chart, the version last played, or the
    ///   first one.
    public func order(for sequence: [String]) -> [Int]? {
        let labels = sections.map { ShepherdArrangementSync.label($0.heading)?.label }
        var result: [Int] = []
        var next = 0
        var lastPlayed: [ShepherdArrangementSync.SectionLabel: Int] = [:]
        for name in sequence {
            guard let (wanted, repeats) = ShepherdArrangementSync.label(name) else { continue }
            func fits(_ index: Int) -> Bool { labels[index].map { Self.fits(wanted, heading: $0) } ?? false }
            let index: Int
            if next < order.count, fits(order[next]) {
                index = order[next]
                next += 1
            } else if let previous = result.last, fits(previous) {
                index = previous
            } else if let ahead = (next..<max(next, order.count)).first(where: { fits(order[$0]) }) {
                index = order[ahead]
                next = ahead + 1
            } else if let played = lastPlayed[wanted] {
                index = played
            } else if let first = ShepherdArrangementSync.sectionIndex(for: wanted, in: labels) {
                index = first
            } else {
                continue
            }
            lastPlayed[wanted] = index
            result += Array(repeating: index, count: wanted.isWordless ? 1 : repeats)
        }
        return result.isEmpty ? nil : result
    }

    /// A name in a sequence is sung under a heading of the same kind when
    /// the numbers agree, the name has none ("Chorus" for "Chorus 1"), "1"
    /// stands for a heading with none, or (except for verses) a numbered
    /// name stands for an unnumbered heading ("Chorus 2" for "Chorus").
    static func fits(_ wanted: ShepherdArrangementSync.SectionLabel, heading: ShepherdArrangementSync.SectionLabel) -> Bool {
        guard wanted.kind == heading.kind else { return false }
        if wanted.number == heading.number || wanted.number == nil { return true }
        guard heading.number == nil else { return false }
        return wanted.number == "1" || wanted.kind != "verse"
    }

    /// "chorus 2" → "chorus", "verse 1b" → "verse".
    static func baseName(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: #"\s*\d+[a-z]?$"#, with: "", options: .regularExpression)
    }

    /// "Chorus (Breakdown)" when the heading has a note that tells the
    /// version apart, else "Chorus (2)".
    private func versionName(_ heading: Heading, number: Int) -> String {
        let taken = Set(sections.map { $0.name.lowercased() })
        let note = heading.notes.joined(separator: ", ")
        if !note.isEmpty, !taken.contains("\(heading.name) (\(note))".lowercased()) {
            return "\(heading.name) (\(note))"
        }
        var number = number
        while taken.contains("\(heading.name) (\(number))".lowercased()) { number += 1 }
        return "\(heading.name) (\(number))"
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

        // "Chorus - Breakdown": the part after the dash is a note.
        if Reflow.labelName(of: core) == nil,
           headingPattern.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) == nil,
           let dash = core.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let note = core[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            let left = String(core[..<dash.lowerBound])
            if !note.isEmpty, var noted = Self.heading(of: left) {
                noted.repeatCount = noted.repeatCount ?? repeatCount
                noted.notes = notes + noted.notes + [note]
                return noted
            }
        }

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

    // MARK: Endings

    private static let endingPattern = try! NSRegularExpression(
        pattern: #"^\(\s*\d\s*\.?\s*\)\s*(.+)$"#)

    private static let directionPattern = try! NSRegularExpression(
        pattern: #"\s*\(\s*(?:to|go to|back to)\b[^)]*\)\s*$"#, options: [.caseInsensitive])

    /// A first or second ending's line without its marker and the direction
    /// after it: "(1.) Of Your [5/7] Name (To Br. 1b)" → "Of Your [5/7] Name".
    /// Nil for any other line.
    static func ending(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = endingPattern.firstMatch(in: line, range: range),
              let body = Range(match.range(at: 1), in: line) else { return nil }
        let text = String(line[body])
        let stripped = directionPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let result = stripped.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    private static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ line: String) -> String {
            ChordMath.extractLine(line).text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return words(a) == words(b)
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
