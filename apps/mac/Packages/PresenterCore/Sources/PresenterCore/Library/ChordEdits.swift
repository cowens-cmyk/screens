import Foundation

/// Chords the operator set by hand, kept on the song so they come back
/// whatever rebuilds its slides: Update from Shepherd, a plan whose
/// arrangement brings in parts the song lacked, a refit to another theme.
/// Each edit is keyed by the line it sits on, not the slide: its section's
/// name, its words, and which time those words come in that section (a
/// chorus that sings "Holy forever" four times has four lines to tell
/// apart). A line edited down to no chords is kept too, so a chord taken
/// out stays out.
public enum ChordEdits {

    /// One lyric line of a song, where its chords are stored.
    public struct LineRef: Equatable, Sendable {
        public var slideID: String
        public var objectID: String
        public var line: Int
        /// The section's name, "" for a slide in none.
        public var section: String
        public var text: String
        /// 0 for the first time these words come in this section.
        public var occurrence: Int
    }

    /// The text box chords go on: the first with words, else the first text box.
    public static func lyricObject(of slide: Slide) -> SlideObject? {
        slide.objects.first { $0.objectKind == .text && !$0.text.isEmpty }
            ?? slide.objects.first { $0.objectKind == .text }
    }

    /// Every lyric line of the song, in slide order.
    public static func lines(of presentation: Presentation) -> [LineRef] {
        let names = Dictionary(
            (presentation.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen: [String: Int] = [:]
        var refs: [LineRef] = []
        for slide in presentation.slides {
            guard let object = lyricObject(of: slide) else { continue }
            let section = slide.sectionId.flatMap { names[$0] } ?? ""
            for (index, text) in object.text.components(separatedBy: "\n").enumerated() {
                let key = matchKey(section: section, text: text)
                let occurrence = seen[key, default: 0]
                seen[key] = occurrence + 1
                refs.append(LineRef(
                    slideID: slide.id, objectID: object.id, line: index,
                    section: section, text: text, occurrence: occurrence))
            }
        }
        return refs
    }

    public static func ref(in presentation: Presentation, slideID: String, line: Int) -> LineRef? {
        lines(of: presentation).first { $0.slideID == slideID && $0.line == line }
    }

    /// `edits` with this line's chords (columns along the line; `line` is
    /// ignored) as the operator left them, written in `key`.
    public static func recording(
        _ chords: [ChordPlacement], for ref: LineRef, key: String?, in edits: [ChordLineEdit]?
    ) -> [ChordLineEdit] {
        let target = matchKey(section: ref.section, text: ref.text)
        var kept = (edits ?? []).filter {
            !(matchKey(section: $0.section, text: $0.text) == target && $0.occurrence == ref.occurrence)
        }
        kept.append(ChordLineEdit(
            section: ref.section, text: ref.text, occurrence: ref.occurrence,
            chords: chords
                .map { ChordPlacement(line: 0, column: $0.column, symbol: $0.symbol) }
                .sorted { $0.column < $1.column },
            key: key))
        return kept
    }

    /// The song with every recorded line's chords put back on the line it
    /// was made for, moved into the song's key when it was made in another.
    /// A line whose words changed has no edit to match and keeps its own.
    /// `onlyBare`: lines that came out with chords of their own keep them
    /// (Reflow, where chords typed in the text are the newer word).
    public static func applying(_ presentation: Presentation, onlyBare: Bool = false) -> Presentation {
        guard let edits = presentation.chordEdits, !edits.isEmpty else { return presentation }
        var byKey: [String: ChordLineEdit] = [:]
        for edit in edits {
            byKey["\(matchKey(section: edit.section, text: edit.text))#\(edit.occurrence)"] = edit
        }
        var result = presentation
        for ref in lines(of: presentation) {
            guard let edit = byKey["\(matchKey(section: ref.section, text: ref.text))#\(ref.occurrence)"],
                  let slideIndex = result.slides.firstIndex(where: { $0.id == ref.slideID }),
                  let objectIndex = result.slides[slideIndex].objects.firstIndex(where: { $0.id == ref.objectID })
            else { continue }
            let interval = ChordMath.transposeInterval(musicKey: edit.key, displayKey: presentation.musicKey) ?? 0
            let width = ref.text.count
            let placed = edit.chords.map { chord -> ChordPlacement in
                var symbol = chord.symbol
                if interval != 0, let key = presentation.musicKey, let parsed = ChordMath.parseSymbol(symbol) {
                    symbol = ChordMath.transpose(parsed, by: interval, spelledFor: key).formatted
                }
                return ChordPlacement(line: ref.line, column: min(max(0, chord.column), width), symbol: symbol)
            }
            var object = result.slides[slideIndex].objects[objectIndex]
            if onlyBare, (object.chords ?? []).contains(where: { $0.line == ref.line }) { continue }
            var chords = (object.chords ?? []).filter { $0.line != ref.line }
            chords.append(contentsOf: placed)
            chords.sort { ($0.line, $0.column) < ($1.line, $1.column) }
            object.chords = chords.isEmpty ? nil : chords
            result.slides[slideIndex].objects[objectIndex] = object
        }
        return result
    }

    /// The chords that go well in a key, for one-click placing: the six
    /// chords built on its scale (I ii iii IV V vi), then the song's own
    /// chords by how often it uses them. Empty with no key and no chords.
    public static func palette(musicKey: String?, in presentation: Presentation?) -> [String] {
        var out: [String] = []
        if let key = musicKey, let parsed = ChordMath.parseKey(key) {
            // Degrees from the tonic and their quality: major I ii iii IV V vi;
            // minor i III iv v VI VII.
            let steps: [(Int, String)] = parsed.isMinor
                ? [(0, "m"), (3, ""), (5, "m"), (7, "m"), (8, ""), (10, "")]
                : [(0, ""), (2, "m"), (4, "m"), (5, ""), (7, ""), (9, "m")]
            let tonic = ChordMath.Symbol(root: key.hasSuffix("m") ? String(key.dropLast()) : key)
            for (step, quality) in steps {
                var chord = ChordMath.transpose(tonic, by: step, spelledFor: key)
                chord.suffix = quality
                out.append(chord.formatted)
            }
        }
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for slide in presentation?.slides ?? [] {
            for object in slide.objects where object.objectKind == .text {
                for chord in object.chords ?? [] where !chord.symbol.isEmpty {
                    counts[chord.symbol, default: 0] += 1
                    if firstSeen[chord.symbol] == nil {
                        firstSeen[chord.symbol] = order
                        order += 1
                    }
                }
            }
        }
        let used = counts.keys.sorted {
            (counts[$0]!, -firstSeen[$0]!) > (counts[$1]!, -firstSeen[$1]!)
        }
        for chord in used where !out.contains(chord) { out.append(chord) }
        return out
    }

    /// Where Tab goes from `column`: the start of the next word on the line,
    /// nil past the last one.
    public static func nextWordStart(in text: String, after column: Int) -> Int? {
        let chars = Array(text)
        var index = min(max(column, 0), chars.count)
        while index < chars.count, !chars[index].isWhitespace { index += 1 }
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        return index < chars.count ? index : nil
    }

    /// Where Shift-Tab goes from `column`: the start of the word before it.
    public static func previousWordStart(in text: String, before column: Int) -> Int? {
        let chars = Array(text)
        var index = min(max(column, 0), chars.count) - 1
        while index >= 0, chars[index].isWhitespace { index -= 1 }
        guard index >= 0 else { return nil }
        while index > 0, !chars[index - 1].isWhitespace { index -= 1 }
        return index
    }

    /// The song's edits with every line `touched` picks recorded as it now stands.
    public static func recordingAll(
        in presentation: Presentation, where touched: (LineRef) -> Bool
    ) -> [ChordLineEdit]? {
        var edits = presentation.chordEdits
        for ref in lines(of: presentation) where touched(ref) {
            edits = recording(chords(at: ref, in: presentation), for: ref, key: presentation.musicKey, in: edits)
        }
        return edits
    }

    /// The chords on one line, columns along it.
    public static func chords(at ref: LineRef, in presentation: Presentation) -> [ChordPlacement] {
        guard let slide = presentation.slides.first(where: { $0.id == ref.slideID }),
              let object = slide.objects.first(where: { $0.id == ref.objectID })
        else { return [] }
        return (object.chords ?? []).filter { $0.line == ref.line }.sorted { $0.column < $1.column }
    }

    /// The lines of one section (`sectionID` nil: slides in none), in order.
    public static func lines(of presentation: Presentation, section sectionID: String?) -> [LineRef] {
        let slides = Set(presentation.slides.filter { $0.sectionId == sectionID }.map(\.id))
        return lines(of: presentation).filter { slides.contains($0.slideID) }
    }

    /// Verse 1's chords onto Verse 2: line by line, first to first, each
    /// kept within its new line's words. Lines past the shorter section's
    /// end are left as they are.
    public static func copyingChords(
        in presentation: Presentation, from source: String?, to target: String?
    ) -> Presentation {
        let from = lines(of: presentation, section: source)
        let to = lines(of: presentation, section: target)
        var result = presentation
        for (line, ref) in zip(from, to) {
            let copied = chords(at: line, in: presentation)
            result = settingChords(copied, at: ref, in: result)
        }
        return result
    }

    /// The section with no chords left.
    public static func clearingChords(in presentation: Presentation, section sectionID: String?) -> Presentation {
        var result = presentation
        for ref in lines(of: presentation, section: sectionID) {
            result = settingChords([], at: ref, in: result)
        }
        return result
    }

    /// One line's chords replaced, columns kept within its words.
    public static func settingChords(
        _ chords: [ChordPlacement], at ref: LineRef, in presentation: Presentation
    ) -> Presentation {
        guard let slideIndex = presentation.slides.firstIndex(where: { $0.id == ref.slideID }),
              let objectIndex = presentation.slides[slideIndex].objects.firstIndex(where: { $0.id == ref.objectID })
        else { return presentation }
        var result = presentation
        var object = result.slides[slideIndex].objects[objectIndex]
        var all = (object.chords ?? []).filter { $0.line != ref.line }
        all += chords.map {
            ChordPlacement(line: ref.line, column: min(max(0, $0.column), ref.text.count), symbol: $0.symbol)
        }
        all.sort { ($0.line, $0.column) < ($1.line, $1.column) }
        object.chords = all.isEmpty ? nil : all
        result.slides[slideIndex].objects[objectIndex] = object
        return result
    }

    /// The first word's start, nil on a line with no words.
    public static func firstWordStart(in text: String) -> Int? {
        Array(text).firstIndex { !$0.isWhitespace }
    }

    /// The last word's start, nil on a line with no words.
    public static func lastWordStart(in text: String) -> Int? {
        previousWordStart(in: text, before: text.count + 1)
    }

    static func matchKey(section: String, text: String) -> String {
        section.trimmingCharacters(in: .whitespaces).lowercased() + "\u{1F}"
            + text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
