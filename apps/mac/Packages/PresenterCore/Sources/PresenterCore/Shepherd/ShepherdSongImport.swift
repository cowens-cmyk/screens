import CryptoKit
import Foundation

/// A library song from a Shepherd song: lyrics slides from its chord chart
/// (or its lyrics when there is no chart), chords for the stage display,
/// the arrangement's section order and the key.
///
/// The presentation remembers the Shepherd song, the arrangement whose
/// chart it came from, a hash of that chart, and a fingerprint of what was
/// imported. Plan sync re-imports only when the chart hash changes, so any
/// number of Macs can sync without fighting, and only while the fingerprint
/// still matches — a song someone edited in Screens is never replaced
/// without asking.
public enum ShepherdSongImport {

    public struct Options: Sendable, Equatable {
        public var themeId: String
        public var linesPerSlide: Int
        public var removePunctuation: Bool
        /// The key the band plays in (the plan's), for the stage display.
        public var playingKey: String?

        public init(themeId: String = "", linesPerSlide: Int = 2, removePunctuation: Bool = true, playingKey: String? = nil) {
            self.themeId = themeId
            self.linesPerSlide = linesPerSlide
            self.removePunctuation = removePunctuation
            self.playingKey = playingKey
        }
    }

    /// What the song is built from: the arrangement's chart, the song's
    /// chart, else its lyrics.
    public static func source(
        song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?
    ) -> (text: String, isChart: Bool)? {
        if let chart = [arrangement?.chordChart, song.chordChart].compactMap({ $0 }).first(where: hasWords) {
            return (chart, true)
        }
        if let lyrics = song.lyrics, hasWords(lyrics) { return (lyrics, false) }
        return nil
    }

    public static func hasText(song: ShepherdClient.SongDetail?, arrangement: ShepherdClient.SongArrangement?) -> Bool {
        song.map { source(song: $0, arrangement: arrangement) != nil } ?? false
    }

    private static func hasWords(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The arrangement a linked song follows: the one it was imported from
    /// while Shepherd still has it, else Shepherd's default, else the first.
    public static func trackedArrangement(
        of song: ShepherdClient.SongDetail, id: String?
    ) -> ShepherdClient.SongArrangement? {
        if let id, let match = song.arrangements.first(where: { $0.id == id }) { return match }
        if let id = song.defaultArrangementId, let match = song.arrangements.first(where: { $0.id == id }) {
            return match
        }
        return song.arrangements.first
    }

    /// Changes whenever the words, chords or song order Shepherd gives for
    /// this arrangement change, and never otherwise.
    public static func chartHash(song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?) -> String {
        let text = source(song: song, arrangement: arrangement)?.text ?? ""
        let sequence = ShepherdSongMatch.sequence(of: song, arrangement: arrangement)
        return sha256(["shepherd-chart-1", normalizedLines(text), sequence.joined(separator: "|")]
            .joined(separator: "\u{1F}"))
    }

    /// Line endings and trailing spaces don't count as a change.
    private static func normalizedLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Screens arrangement for a Shepherd arrangement. A fixed id, so
    /// every Mac's import names the same one.
    public static func arrangementID(_ shepherdArrangementID: String?) -> String {
        "shepherd-" + (shepherdArrangementID ?? "song")
    }

    // MARK: Building

    public static func presentation(
        song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?, options: Options = Options()
    ) -> Presentation? {
        guard let source = source(song: song, arrangement: arrangement) else { return nil }
        let chart = ShepherdChart.parse(source.text)
        guard chart.sections.contains(where: \.hasLyrics) else {
            // A chart of chords alone: the words come from the lyrics.
            guard source.isChart, let lyrics = song.lyrics, hasWords(lyrics) else { return nil }
            var words = song
            words.chordChart = nil
            return presentation(song: words, arrangement: arrangement.map { var a = $0; a.chordChart = nil; return a },
                                options: options)
        }

        var parsed = Reflow.ParseResult(
            sections: chart.sections.map { section in
                let slides = chart.cleanedStanzas(section, removePunctuation: options.removePunctuation)
                    .flatMap { stanza in
                        stride(from: 0, to: stanza.count, by: max(1, options.linesPerSlide)).map {
                            stanza[$0..<min($0 + max(1, options.linesPerSlide), stanza.count)].joined(separator: "\n")
                        }
                    }
                return Reflow.ParsedSection(name: section.name, slides: slides)
            },
            order: chart.order)
        let sequence = ShepherdSongMatch.sequence(of: song, arrangement: arrangement)
        var order = chart.order(for: sequence) ?? chart.order
        let before = parsed.sections.count
        parsed.order = order
        parsed = parsed.openingOnBlank()
        if parsed.sections.count > before { order = [0] + order.map { $0 + 1 } } else if order.first != 0 { order = [0] + order }
        // A section with no words (an instrumental, a turnaround) is one
        // blank slide, so it has a place in the order.
        for index in parsed.sections.indices where parsed.sections[index].slides.isEmpty {
            parsed.sections[index].slides = [""]
        }

        let built = Reflow.build(parsed)
        let shepherdOrder = Arrangement(
            id: arrangementID(arrangement?.id), name: arrangement?.name.isEmpty == false ? arrangement!.name : "Shepherd",
            sectionIds: order.map { built.sections[$0].id },
            shepherdArrangementId: ShepherdArrangementSync.tag(arrangement))

        var presentation = Presentation(
            id: UUID().uuidString, name: song.title, presentationKind: .song, themeId: options.themeId,
            slides: built.slides.isEmpty ? [Slide(id: UUID().uuidString, name: "", objects: [])] : built.slides,
            sections: built.sections, arrangements: [shepherdOrder], defaultArrangementId: shepherdOrder.id,
            reflowSource: chart.chordPro(removePunctuation: options.removePunctuation),
            chordProSource: source.isChart ? source.text : nil)
        presentation.category = PresentationTypes.worship
        presentation.musicKey = [song.chart?.writtenKey, chart.key, song.originalKey, song.defaultKey]
            .compactMap { $0 }.first { ChordMath.parseKey($0) != nil }
        if let playing = options.playingKey, let musicKey = presentation.musicKey,
           let display = ChordMath.displayKey(playing: playing, musicKey: musicKey),
           display.caseInsensitiveCompare(musicKey) != .orderedSame {
            presentation.displayKey = display
        }
        presentation.ccli = CCLIInfo(
            songNumber: (song.ccliNumber ?? chart.ccli).flatMap { Int($0.filter(\.isNumber)) },
            songTitle: song.title, author: song.author ?? chart.artist, copyright: song.copyright ?? chart.copyright)
        presentation.shepherdSongId = song.id
        presentation.shepherdArrangementId = arrangement?.id
        presentation.shepherdChartHash = chartHash(song: song, arrangement: arrangement)
        presentation.shepherdImportHash = fingerprint(presentation)
        return presentation
    }

    // MARK: Edits and updates

    /// The words, chords and section names on the slides, the key they're
    /// written in, and the order of the song's Shepherd arrangement.
    /// Themes, backgrounds, the display key
    /// and other arrangements (Anthem's, the operator's) don't count.
    public static func fingerprint(_ presentation: Presentation) -> String {
        let names = Dictionary((presentation.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var parts = ["key:" + (presentation.musicKey ?? "")]
        for slide in presentation.slides {
            parts.append("§" + (slide.sectionId.flatMap { names[$0] } ?? ""))
            for object in slide.objects where object.objectKind == .text {
                parts.append(object.text)
                parts.append((object.chords ?? [])
                    .sorted { ($0.line, $0.column, $0.symbol) < ($1.line, $1.column, $1.symbol) }
                    .map { "\($0.line):\($0.column):\($0.symbol)" }.joined(separator: ","))
            }
        }
        let tracked = arrangementID(presentation.shepherdArrangementId)
        if let order = presentation.arrangements?.first(where: { $0.id == tracked }) {
            parts.append("order:" + order.sectionIds.map { names[$0] ?? "?" }.joined(separator: "|"))
        }
        return sha256(parts.joined(separator: "\u{1F}"))
    }

    public enum Decision: Equatable, Sendable {
        /// Shepherd's chart is the one imported.
        case upToDate
        /// Shepherd changed and the song is as imported: update it.
        case update
        /// Shepherd changed but the song was edited in Screens: ask first.
        case edited
    }

    public static func decision(for presentation: Presentation, chartHash: String) -> Decision {
        guard presentation.shepherdChartHash != chartHash else { return .upToDate }
        guard let imported = presentation.shepherdImportHash, imported == fingerprint(presentation) else { return .edited }
        return .update
    }

    /// `existing` with Shepherd's new words, chords and order. It keeps its
    /// id, name, theme, folder, display key, section colors and backgrounds,
    /// slide backgrounds and actions where the slide is still there, and
    /// every arrangement that isn't the Shepherd one (Anthem's and the
    /// operator's), so services and Anthem keep working.
    public static func replacing(_ existing: Presentation, with fresh: Presentation) -> Presentation {
        var result = existing
        let oldSections = existing.sections ?? []
        var usedOld = Set<String>()
        var idMap: [String: String] = [:]
        var sections: [PresentationSection] = []
        for section in fresh.sections ?? [] {
            if let old = oldSections.first(where: {
                !usedOld.contains($0.id) && $0.name.caseInsensitiveCompare(section.name) == .orderedSame
            }) {
                usedOld.insert(old.id)
                idMap[section.id] = old.id
                var kept = section
                kept.id = old.id
                kept.background = old.background
                kept.colorHex = old.colorHex
                sections.append(kept)
            } else {
                idMap[section.id] = section.id
                sections.append(section)
            }
        }

        // Slides keep what was set on them by place: the nth slide of a section.
        var oldByPlace: [String: Slide] = [:]
        var counts: [String: Int] = [:]
        for slide in existing.slides {
            let section = slide.sectionId ?? ""
            oldByPlace["\(section)#\(counts[section, default: 0])"] = slide
            counts[section, default: 0] += 1
        }
        counts = [:]
        result.slides = fresh.slides.map { slide in
            var slide = slide
            slide.sectionId = slide.sectionId.flatMap { idMap[$0] }
            let section = slide.sectionId ?? ""
            let place = "\(section)#\(counts[section, default: 0])"
            counts[section, default: 0] += 1
            if let old = oldByPlace[place] {
                slide.background = old.background
                slide.backgroundFill = old.backgroundFill
                slide.themeId = old.themeId
                slide.themeSlideName = old.themeSlideName ?? slide.themeSlideName
                slide.unthemed = old.unthemed
                slide.actions = old.actions
                slide.notes = old.notes
                slide.autoAdvance = old.autoAdvance
                slide.transition = old.transition
                slide.stageLayoutId = old.stageLayoutId
                slide.lookPresetId = old.lookPresetId
            }
            return slide
        }
        result.sections = sections

        let ids = Set(sections.map(\.id))
        let freshArrangements = (fresh.arrangements ?? []).map { arrangement in
            var arrangement = arrangement
            arrangement.sectionIds = arrangement.sectionIds.compactMap { idMap[$0] }
            return arrangement
        }
        var arrangements = (existing.arrangements ?? []).compactMap { arrangement -> Arrangement? in
            if freshArrangements.contains(where: { $0.id == arrangement.id }) { return nil }
            var kept = arrangement
            kept.sectionIds = arrangement.sectionIds.filter(ids.contains)
            return kept
        }
        arrangements += freshArrangements
        result.arrangements = arrangements.isEmpty ? nil : arrangements
        if !arrangements.contains(where: { $0.id == existing.defaultArrangementId }) {
            result.defaultArrangementId = fresh.defaultArrangementId
        }

        result.reflowSource = fresh.reflowSource
        result.chordProSource = fresh.chordProSource
        result.musicKey = fresh.musicKey ?? existing.musicKey
        result.displayKey = existing.displayKey ?? fresh.displayKey
        result.presentationKind = .song
        var ccli = existing.ccli ?? CCLIInfo()
        ccli.songNumber = ccli.songNumber ?? fresh.ccli?.songNumber
        ccli.songTitle = ccli.songTitle ?? fresh.ccli?.songTitle
        ccli.author = ccli.author ?? fresh.ccli?.author
        ccli.copyright = ccli.copyright ?? fresh.ccli?.copyright
        result.ccli = ccli
        result.shepherdSongId = fresh.shepherdSongId
        result.shepherdArrangementId = fresh.shepherdArrangementId
        result.shepherdChartHash = fresh.shepherdChartHash
        result.shepherdImportHash = fingerprint(result)
        return result
    }

    /// What an update would change, at a glance: "Chorus 1 and Bridge
    /// changed, Tag added". Nil when only the order would change.
    public static func changeSummary(from old: Presentation, to new: Presentation) -> String? {
        func words(_ presentation: Presentation) -> [(name: String, text: String)] {
            let sections = presentation.sections ?? []
            return sections.map { section in
                let text = presentation.slides.filter { $0.sectionId == section.id }
                    .flatMap { $0.objects.filter { $0.objectKind == .text } }
                    .map { $0.text + "|" + ($0.chords ?? []).map(\.symbol).joined(separator: ",") }
                    .joined(separator: "\n")
                return (section.name, text)
            }
        }
        let before = words(old), after = words(new)
        let oldByName = Dictionary(before.map { ($0.name.lowercased(), $0.text) }, uniquingKeysWith: { a, _ in a })
        let newNames = Set(after.map { $0.name.lowercased() })
        let changed = after.filter { section in
            oldByName[section.name.lowercased()].map { $0 != section.text } ?? false
        }.map(\.name)
        let added = after.filter { oldByName[$0.name.lowercased()] == nil }.map(\.name)
        let removed = before.filter { !newNames.contains($0.name.lowercased()) }.map(\.name)
        var parts: [String] = []
        if !changed.isEmpty { parts.append("\(list(changed)) changed") }
        if !added.isEmpty { parts.append("\(list(added)) added") }
        if !removed.isEmpty { parts.append("\(list(removed)) removed") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        case 3: "\(names[0]), \(names[1]) and \(names[2])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
