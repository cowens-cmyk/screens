import Foundation

/// A Screens song as the comparison sees it: its sections (with whether any
/// slide in them carries words) and the order the plan item will show them.
public struct ScreensSongShape: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var id: String
        public var name: String
        public var hasLyrics: Bool

        public init(id: String, name: String, hasLyrics: Bool) {
            self.id = id
            self.name = name
            self.hasLyrics = hasLyrics
        }
    }

    public var sections: [Section]
    /// Section ids in the order the item shows them.
    public var order: [String]
    /// The arrangement `order` came from, when it came from one.
    public var arrangementId: String?

    public init(sections: [Section], order: [String], arrangementId: String? = nil) {
        self.sections = sections
        self.order = order
        self.arrangementId = arrangementId
    }

    /// The item's arrangement, else the song's default arrangement, else its
    /// sections in slide order.
    public init(presentation: Presentation, arrangementId: String?) {
        let known = presentation.sections ?? []
        var lyrics: Set<String> = []
        for slide in presentation.slides {
            guard let id = slide.sectionId else { continue }
            let words = slide.objects.contains {
                $0.objectKind == .text && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if words { lyrics.insert(id) }
        }
        sections = known.map { Section(id: $0.id, name: $0.name, hasLyrics: lyrics.contains($0.id)) }
        let ids = Set(known.map(\.id))
        let arrangements = presentation.arrangements ?? []
        let chosen = [arrangementId, presentation.defaultArrangementId].lazy
            .compactMap { id in id.flatMap { id in arrangements.first { $0.id == id && !$0.sectionIds.isEmpty } } }
            .first
        if let chosen {
            order = chosen.sectionIds.filter(ids.contains)
            self.arrangementId = chosen.id
        } else {
            var runs: [String] = []
            for slide in presentation.slides {
                guard let id = slide.sectionId, ids.contains(id), runs.last != id else { continue }
                runs.append(id)
            }
            order = runs
            self.arrangementId = nil
        }
    }

    func section(_ id: String) -> Section? { sections.first { $0.id == id } }

    /// Blank or instrumental by name: nothing to sing on screen.
    func isInstrumental(_ id: String) -> Bool {
        guard let section = section(id) else { return false }
        return !section.hasLyrics || SectionLabel(section.name).isInstrumental
    }
}

/// How Anthem's performed sections line up with a Screens song.
public enum AnthemArrangementMatch {
    public struct Options: Equatable, Sendable {
        /// Anthem sections with no lyrics that Screens has no slides for are
        /// left out of the comparison instead of reported missing.
        public var ignoreInstrumental: Bool

        public init(ignoreInstrumental: Bool = true) {
            self.ignoreInstrumental = ignoreInstrumental
        }
    }

    public enum Step: Equatable, Sendable {
        /// Anthem's section shows this Screens section.
        case section(String, instrumental: Bool)
        /// Screens has nothing for it.
        case missing(SectionLabel, instrumental: Bool)
    }

    /// Each Anthem section mapped onto the song's sections, by normalized
    /// name and occurrence. A repeated section reuses the same Screens
    /// section, so "Chorus" three times is the one chorus shown three times.
    public static func steps(
        _ anthem: [AnthemShow.Section], song: ScreensSongShape
    ) -> [Step] {
        let labels = song.sections.map { (section: $0, label: SectionLabel($0.name)) }
        return anthem.map { performed in
            let label = SectionLabel(performed.name)
            let occurrence = max(1, performed.occurrence ?? 1)
            let saysInstrumental = performed.kind.map { SectionLabel($0).isInstrumental } ?? false
            // A chorus Anthem marks instrumental is the band alone: not the
            // chorus words.
            let bandOnly = saysInstrumental && !label.mayBeInstrumental
            if !bandOnly, let id = sectionID(for: label, occurrence: occurrence, in: labels) {
                return .section(id, instrumental: song.isInstrumental(id))
            }
            let instrumental = saysInstrumental || label.mayBeInstrumental
            let wanted = bandOnly ? SectionLabel("Instrumental") : label
            if instrumental, let blank = blankSection(for: wanted, in: labels) {
                return .section(blank, instrumental: true)
            }
            return .missing(wanted, instrumental: instrumental)
        }
    }

    static func sectionID(
        for label: SectionLabel, occurrence: Int,
        in sections: [(section: ScreensSongShape.Section, label: SectionLabel)]
    ) -> String? {
        if let exact = sections.first(where: { $0.label.cleaned == label.cleaned }) {
            return exact.section.id
        }
        let sameKind = sections.filter { $0.label.kind == label.kind }
        guard !sameKind.isEmpty else { return nil }
        let unnumbered = sameKind.filter { $0.label.number == nil }
        let numbered = sameKind.filter { $0.label.number != nil }
            .sorted { ($0.label.number ?? 0) < ($1.label.number ?? 0) }
        if let number = label.number {
            if let hit = numbered.first(where: { $0.label.number == number }) { return hit.section.id }
            // One chorus in Screens serves "Chorus 2"; a verse has its own
            // words, so "Verse 3" with no third verse is missing.
            if unnumbered.count == 1, label.kind != "verse" || number == 1 {
                return unnumbered[0].section.id
            }
            if unnumbered.isEmpty, numbered.count == 1, label.kind != "verse" {
                return numbered[0].section.id
            }
            return nil
        }
        // An unnumbered "Verse" the second time is the second verse.
        if let hit = numbered.first(where: { $0.label.number == occurrence }) { return hit.section.id }
        if let plain = unnumbered.first { return plain.section.id }
        return numbered.first?.section.id
    }

    /// A Screens section with nothing to sing, for an instrumental part:
    /// same kind first ("Intro" for an intro), then one named Instrumental
    /// or Blank, then any section without words.
    static func blankSection(
        for label: SectionLabel,
        in sections: [(section: ScreensSongShape.Section, label: SectionLabel)]
    ) -> String? {
        let silent = sections.filter { !$0.section.hasLyrics || $0.label.isInstrumental }
        return (silent.first { $0.label.kind == label.kind }
            ?? silent.first { $0.label.kind == "instrumental" }
            ?? silent.first { $0.label.kind == "blank" }
            ?? silent.first { !$0.section.hasLyrics })?.section.id
    }

    public struct Comparison: Equatable, Sendable {
        public var matches: Bool
        /// Anthem's order in Screens' terms ("V1 C V2 C B C C").
        public var anthemTokens: [String]
        public var screensTokens: [String]
        /// Sections Anthem plays that Screens has no slides for.
        public var missing: [SectionLabel]
        /// The Screens order that follows Anthem: every mapped section, in
        /// Anthem's order. Empty when nothing maps.
        public var proposed: [String]

        /// "Anthem: V1 C V2 C B C C — Screens: V1 C V2 C B C"
        public var diff: String {
            "Anthem: \(anthemTokens.joined(separator: " ")) — Screens: \(screensTokens.joined(separator: " "))"
        }
    }

    public static func compare(
        _ anthem: [AnthemShow.Section], song: ScreensSongShape, options: Options = .init()
    ) -> Comparison {
        let steps = steps(anthem, song: song)
        let ignore = options.ignoreInstrumental
        var anthemIDs: [String?] = []
        var anthemTokens: [String] = []
        var missing: [SectionLabel] = []
        var proposed: [String] = []
        for step in steps {
            switch step {
            case .section(let id, let instrumental):
                proposed.append(id)
                if ignore && instrumental { continue }
                anthemIDs.append(id)
                anthemTokens.append(token(id, song))
            case .missing(let label, let instrumental):
                if ignore && instrumental { continue }
                anthemIDs.append(nil)
                anthemTokens.append(label.short)
                if !missing.contains(where: { $0.kind == label.kind && $0.number == label.number }) {
                    missing.append(label)
                }
            }
        }
        let screensIDs = song.order.filter { !(ignore && song.isInstrumental($0)) }
        return Comparison(
            matches: missing.isEmpty && anthemIDs == screensIDs.map(Optional.some),
            anthemTokens: anthemTokens,
            screensTokens: screensIDs.map { token($0, song) },
            missing: missing,
            proposed: proposed
        )
    }

    static func token(_ id: String, _ song: ScreensSongShape) -> String {
        song.section(id).map { SectionLabel($0.name).short } ?? "?"
    }

    /// "Screens has no Tag — add it in the editor."
    public static func missingNote(_ missing: [SectionLabel]) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.display)
        let list = names.count <= 2 ? names.joined(separator: " or ")
            : names.dropLast().joined(separator: ", ") + " or " + names.last!
        return "Screens has no \(list) — add \(missing.count == 1 ? "it" : "them") in the editor."
    }
}

/// Which Anthem setlist entry is which song in a Screens plan.
public enum AnthemSongMatch {
    /// A plan item that is a song.
    public struct PlanSong: Equatable, Sendable {
        public var itemID: String
        public var ccli: Int?
        /// Every title it might go by: the plan's, the slides', CCLI's.
        public var titles: [String]
        /// Nil when the song has no slides yet.
        public var shape: ScreensSongShape?

        public init(itemID: String, ccli: Int?, titles: [String], shape: ScreensSongShape?) {
            self.itemID = itemID
            self.ccli = ccli
            self.titles = titles
            self.shape = shape
        }

        public init(item: ServiceItem, presentation: Presentation?) {
            let titles = [item.mxuSongTitle, item.name, presentation?.name, presentation?.ccli?.songTitle]
                .compactMap { $0 }.filter { !$0.isEmpty }
            self.init(
                itemID: item.id,
                ccli: item.mxuCcliNumber ?? presentation?.ccli?.songNumber,
                titles: titles,
                shape: presentation.map { ScreensSongShape(presentation: $0, arrangementId: item.arrangementId) }
            )
        }

        /// A plan item worth comparing: a song presentation, or a planned
        /// song still waiting for slides.
        public static func isSong(_ item: ServiceItem, presentation: Presentation?) -> Bool {
            if item.itemKind == .presentation {
                return presentation?.presentationKind == .song || item.mxuCcliNumber != nil
                    || item.mxuSongTitle != nil || presentation?.ccli?.songNumber != nil
            }
            return item.itemKind == .info && item.mxuSongTitle != nil
        }
    }

    public enum Status: String, Equatable, Sendable {
        case match
        case mismatch
        /// In the plan, not in Anthem's setlist.
        case notInAnthem
        /// In Anthem's setlist, not in the plan.
        case notInScreens
        /// In both, but the plan song has no slides yet.
        case noSlides
        /// The slides are not grouped into sections, so there is no order to
        /// compare.
        case unsectioned
    }

    public struct Result: Equatable, Sendable {
        public var itemID: String?
        public var entryID: String?
        public var title: String
        public var status: Status
        public var comparison: AnthemArrangementMatch.Comparison?
    }

    public struct Report: Equatable, Sendable {
        public var results: [Result]
        public var planSongCount: Int
        public var entryCount: Int

        public func result(forItem id: String) -> Result? { results.first { $0.itemID == id } }
        public var matched: Int { results.count { $0.itemID != nil && $0.entryID != nil } }
        public var mismatches: [Result] { results.filter { $0.status == .mismatch } }
        public var notInScreens: [Result] { results.filter { $0.status == .notInScreens } }

        /// Whether this plan is the one Anthem's setlist is for: most of the
        /// songs either side has are in both. Keeps last month's plan from
        /// lighting up because it shares a song.
        public var followsSetlist: Bool {
            matched > 0 && matched * 2 >= min(planSongCount, entryCount)
        }
    }

    public static func report(
        setlist: AnthemShow.Setlist, songs: [PlanSong],
        options: AnthemArrangementMatch.Options = .init()
    ) -> Report {
        var pairs: [Int: Int] = [:]  // entry index → song index
        var taken = Set<Int>()
        // CCLI first, then title, each in plan order so a song sung twice
        // pairs first with first.
        for (e, entry) in setlist.entries.enumerated() {
            guard let number = entry.ccliNumber else { continue }
            if let s = songs.indices.first(where: { !taken.contains($0) && songs[$0].ccli == number }) {
                pairs[e] = s
                taken.insert(s)
            }
        }
        for (e, entry) in setlist.entries.enumerated() where pairs[e] == nil {
            let wanted = normalizedTitle(entry.title)
            guard !wanted.isEmpty else { continue }
            if let s = songs.indices.first(where: {
                !taken.contains($0) && songs[$0].titles.contains { normalizedTitle($0) == wanted }
            }) {
                pairs[e] = s
                taken.insert(s)
            }
        }
        var results: [Result] = []
        for (e, entry) in setlist.entries.enumerated() {
            guard let s = pairs[e] else {
                results.append(Result(itemID: nil, entryID: entry.entryId, title: entry.title, status: .notInScreens))
                continue
            }
            let song = songs[s]
            guard let shape = song.shape else {
                results.append(Result(itemID: song.itemID, entryID: entry.entryId, title: entry.title, status: .noSlides))
                continue
            }
            guard !shape.sections.isEmpty, let sections = entry.arrangement?.sections, !sections.isEmpty else {
                results.append(Result(itemID: song.itemID, entryID: entry.entryId, title: entry.title, status: .unsectioned))
                continue
            }
            let comparison = AnthemArrangementMatch.compare(sections, song: shape, options: options)
            results.append(Result(
                itemID: song.itemID, entryID: entry.entryId, title: entry.title,
                status: comparison.matches ? .match : .mismatch, comparison: comparison))
        }
        for (s, song) in songs.enumerated() where !taken.contains(s) {
            results.append(Result(itemID: song.itemID, entryID: nil, title: song.titles.first ?? "", status: .notInAnthem))
        }
        return Report(results: results, planSongCount: songs.count, entryCount: setlist.entries.count)
    }

    /// Titles compared without case, accents, punctuation or a "(Live)".
    public static func normalizedTitle(_ title: String) -> String {
        var text = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        text = text.replacing(#/\([^)]*\)|\[[^\]]*\]/#, with: " ")
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        text = String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return text.split(separator: " ").joined(separator: " ")
    }

    /// The arrangement "Match Anthem" leaves on the song: the one named
    /// Anthem rewritten to `order`, or a new one. An existing arrangement
    /// with exactly that order is reused instead of adding a copy.
    public static func anthemArrangement(
        order: [String], in arrangements: [Arrangement], newID: String
    ) -> (arrangement: Arrangement, isNew: Bool) {
        if let same = arrangements.first(where: { $0.sectionIds == order }) {
            return (same, false)
        }
        if var named = arrangements.first(where: { $0.name.caseInsensitiveCompare("Anthem") == .orderedSame }) {
            named.sectionIds = order
            return (named, false)
        }
        return (Arrangement(id: newID, name: "Anthem", sectionIds: order), true)
    }
}

/// Where a cue lands in the arranged order. Anthem triggers a slide by its
/// place in the presentation's own slide order (as ProPresenter does);
/// when the plan's arrangement repeats that slide, the occurrence after the
/// one on screen is the one the band is reaching.
public enum AnthemCue {
    public static func occurrence(of slideID: String, in arranged: [String], current: Int?) -> Int? {
        if let current, arranged.indices.contains(current), arranged[current] == slideID { return current }
        if let current, let next = arranged.indices.first(where: { $0 > current && arranged[$0] == slideID }) {
            return next
        }
        return arranged.firstIndex(of: slideID)
    }
}
