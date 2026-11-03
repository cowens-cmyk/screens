import Foundation

/// A song typed slide by slide: what each slide says, and, for the stage
/// display only, the chords over each line. The chords sit on their own
/// line, written where they're played above a monospaced lyric line, so
/// nothing has to guess which text is a chord.
public enum SongSlides {

    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var words: String
        /// Chords spaced over the words ("G      C"); empty for none.
        public var chords: String

        public init(id: String = UUID().uuidString, words: String = "", chords: String = "") {
            self.id = id
            self.words = words
            self.chords = chords
        }
    }

    public struct Card: Equatable, Sendable, Identifiable {
        /// The slide's id, so editing keeps the slide (its background, its
        /// place in a live plan) instead of making a new one.
        public var id: String
        public var section: String
        public var lines: [Line]

        public init(id: String = UUID().uuidString, section: String, lines: [Line] = [Line()]) {
            self.id = id
            self.section = section
            self.lines = lines
        }
    }

    // MARK: Chord lines

    /// Every word on a chord line is a chord, at the column it starts in.
    public static func chords(inLine line: String) -> [(column: Int, symbol: String)] {
        var result: [(column: Int, symbol: String)] = []
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            if chars[index].isWhitespace { index += 1; continue }
            let start = index
            while index < chars.count, !chars[index].isWhitespace { index += 1 }
            result.append((start, String(chars[start..<index])))
        }
        return result
    }

    /// The chord line for a lyric line's chords, each at its column; one
    /// that would run into the last is moved along a space past it.
    public static func chordLine(_ chords: [ChordPlacement]) -> String {
        var line = ""
        for chord in chords.sorted(by: { $0.column < $1.column }) {
            let column = max(chord.column, line.isEmpty ? 0 : line.count + 1)
            line += String(repeating: " ", count: column - line.count) + chord.symbol
        }
        return line
    }

    // MARK: Song ↔ cards

    /// A song's slides as cards, in the order they're stored.
    public static func cards(from presentation: Presentation) -> [Card] {
        let names = Dictionary((presentation.sections ?? []).map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        return presentation.slides.map { slide in
            let lyric = slide.objects.first { $0.objectKind == .text }
            let words = (lyric?.text ?? "").components(separatedBy: "\n")
            let chords = Dictionary(grouping: lyric?.chords ?? [], by: \.line)
            let lines = words.enumerated().map { index, text in
                Line(words: text, chords: chordLine(chords[index] ?? []))
            }
            return Card(
                id: slide.id,
                section: slide.sectionId.flatMap { names[$0] } ?? "",
                lines: lyric == nil ? [Line()] : lines)
        }
    }

    /// A song's slides as cards in the order its default arrangement sings
    /// them, for pasted words: a section pasted again (the chorus after
    /// each verse) is its cards again, as new cards, so the repeat is kept
    /// when the cards are saved.
    public static func cardsAsSung(from presentation: Presentation) -> [Card] {
        let all = cards(from: presentation)
        let arrangement = presentation.arrangements?.first { $0.id == presentation.defaultArrangementId }
        guard let order = arrangement?.sectionIds,
              presentation.slides.allSatisfy({ $0.sectionId.map(order.contains) ?? false })
        else { return all }
        var bySection: [String: [Card]] = [:]
        for (slide, card) in zip(presentation.slides, all) {
            bySection[slide.sectionId ?? "", default: []].append(card)
        }
        var seen = Set<String>()
        var result: [Card] = []
        for id in order {
            let cards = bySection[id] ?? []
            if seen.insert(id).inserted {
                result += cards
            } else {
                result += cards.map { card in
                    Card(section: card.section, lines: card.lines.map { Line(words: $0.words, chords: $0.chords) })
                }
            }
        }
        return result
    }

    /// Writes the cards back as the song's slides, sections and order.
    /// Slides keep their ids and everything but their words and chords.
    /// Cards in a row with the same section are one section; a section
    /// typed again later with the same words is sung again, not copied.
    /// The operator's song order is kept, with new sections added on the
    /// end, unless the cards repeat a section more often than before: then
    /// the order is the one the cards were typed in.
    public static func apply(_ cards: [Card], to song: inout Presentation, themeSlideName: String = "Lyrics") {
        let existing = Dictionary(song.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldSections = song.sections ?? []
        // How often each section is sung in the slides as stored, so a
        // repeat the operator just typed can be told from one already there.
        var storedRuns: [String: Int] = [:]
        var lastStored: String?
        for slide in song.slides {
            guard let id = slide.sectionId, id != lastStored else { continue }
            storedRuns[id, default: 0] += 1
            lastStored = id
        }

        // Group cards into runs of one section.
        var runs: [(name: String, cards: [Card])] = []
        for card in cards {
            let name = card.section.trimmingCharacters(in: .whitespaces)
            if let last = runs.last, last.name == name {
                runs[runs.count - 1].cards.append(card)
            } else {
                runs.append((name, [card]))
            }
        }

        var sections: [PresentationSection] = []
        var slides: [Slide] = []
        var order: [String] = []
        var wordsBySection: [String: [[String]]] = [:]
        let runNames = Set(runs.map { ($0.name.isEmpty ? "Verse" : $0.name).lowercased() })
        for run in runs {
            let words = run.cards.map { $0.lines.map(\.words) }
            let named = run.name.isEmpty ? "Verse" : run.name
            if let same = sections.first(where: { $0.name == named }), wordsBySection[same.id] == words {
                order.append(same.id)
                continue
            }
            var name = named
            var suffix = 2
            while sections.contains(where: { $0.name == name }) {
                name = "\(named) (\(suffix))"
                suffix += 1
            }
            // A section keeps its id when it's renamed or recased, so the
            // song orders and plan items that name it still find it: first
            // the same name, then the same name in another case, then the
            // section its slides were in, if no card still uses that name.
            let free = oldSections.filter { old in !sections.contains { $0.id == old.id } }
            let wasIn = run.cards.first.flatMap { existing[$0.id]?.sectionId }
            var section = free.first { $0.name == name }
                ?? free.first { $0.name.lowercased() == name.lowercased() }
                ?? free.first { $0.id == wasIn && !runNames.contains($0.name.lowercased()) }
                ?? PresentationSection(id: UUID().uuidString, name: name)
            section.name = name
            sections.append(section)
            wordsBySection[section.id] = words
            order.append(section.id)
            for card in run.cards {
                slides.append(slide(for: card, section: section.id, keeping: existing[card.id],
                                    themeSlideName: themeSlideName))
            }
        }

        song.slides = slides
        song.sections = sections.isEmpty ? nil : sections
        song.reflowSource = reflowText(cards)
        let chorded = cards.contains { $0.lines.contains { !$0.chords.trimmingCharacters(in: .whitespaces).isEmpty } }
        song.chordProSource = chorded ? song.reflowSource : nil

        // The song order: kept as the operator set it, with a section new
        // to the song added on the end so it's sung. A repeat typed in the
        // cards is a song order too, and the newer one, so it replaces it.
        let arrangementID = song.defaultArrangementId ?? UUID().uuidString
        var arrangements = song.arrangements ?? []
        let index = arrangements.firstIndex { $0.id == arrangementID }
        let typedRuns = Dictionary(order.map { ($0, 1) }, uniquingKeysWith: +)
        let typedRepeat = typedRuns.contains { id, count in count > max(1, storedRuns[id] ?? 0) }
        if let index, !typedRepeat {
            let oldIDs = Set(oldSections.map(\.id))
            for id in order where !oldIDs.contains(id) && !arrangements[index].sectionIds.contains(id) {
                arrangements[index].sectionIds.append(id)
            }
        } else {
            let arrangement = Arrangement(id: arrangementID, name: "Default", sectionIds: order)
            if let index { arrangements[index] = arrangement } else { arrangements.append(arrangement) }
        }
        let ids = Set(sections.map(\.id))
        for i in arrangements.indices {
            arrangements[i].sectionIds = arrangements[i].sectionIds.filter(ids.contains)
        }
        song.arrangements = arrangements
        song.defaultArrangementId = arrangementID
    }

    private static func slide(for card: Card, section: String, keeping old: Slide?, themeSlideName: String) -> Slide {
        var slide = old ?? Slide(id: card.id, name: "", objects: [])
        slide.sectionId = section
        if slide.themeSlideName == nil { slide.themeSlideName = themeSlideName }
        // Trailing empty lines aren't part of the slide.
        var lines = card.lines
        while let last = lines.last, last.words.trimmingCharacters(in: .whitespaces).isEmpty,
              last.chords.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let text = lines.map(\.words).joined(separator: "\n")
        var placements: [ChordPlacement] = []
        for (index, line) in lines.enumerated() {
            for chord in chords(inLine: line.chords) {
                placements.append(ChordPlacement(
                    line: index, column: min(chord.column, line.words.count), symbol: chord.symbol))
            }
        }
        let lyricIndex = slide.objects.firstIndex { $0.objectKind == .text }
        if lines.isEmpty {
            if let lyricIndex { slide.objects.remove(at: lyricIndex) }
            return slide
        }
        var lyric = lyricIndex.map { slide.objects[$0] }
            ?? SlideObject(id: UUID().uuidString, objectKind: .text, name: "Lyrics", text: "")
        lyric.text = text
        lyric.chords = placements.isEmpty ? nil : placements
        if let lyricIndex { slide.objects[lyricIndex] = lyric } else { slide.objects.insert(lyric, at: 0) }
        return slide
    }

    /// The song as lyrics text (section names on their own lines, chords in
    /// brackets), for everything that reads a song's words as text.
    static func reflowText(_ cards: [Card]) -> String {
        var out: [String] = []
        var lastSection: String?
        for card in cards {
            let section = card.section.trimmingCharacters(in: .whitespaces)
            if !out.isEmpty { out.append("") }
            if section != lastSection, !section.isEmpty {
                out.append(section)
                lastSection = section
            }
            for line in card.lines where !line.words.isEmpty || !line.chords.isEmpty {
                let placements = chords(inLine: line.chords).map {
                    ChordPlacement(line: 0, column: min($0.column, line.words.count), symbol: $0.symbol)
                }
                out.append(ChordMath.bracketed(line.words, chords: placements))
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
