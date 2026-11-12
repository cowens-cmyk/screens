import Foundation

/// Planned songs play in the arrangement chosen in Shepherd for that plan
/// item, whether the Screens song was built from Shepherd or was already in
/// the library and only linked by CCLI number or title.
///
/// Each sync, for each linked song item: the Screens song gets an
/// arrangement named like Shepherd's ("Default", "Short", "Easter") whose
/// order is Shepherd's sequence matched to the song's sections by name, and
/// the item is set to it.
///
/// - An arrangement sync made carries `shepherdArrangementId` and follows
///   Shepherd: when the sequence (or the name) changes there, it changes
///   here. Its id is fixed by the Shepherd arrangement, so every Mac writes
///   the same one and a second Mac finds nothing to do.
/// - Once someone changes sync's arrangement by hand (its order or name, in
///   any order editor), it is marked as edited (`editedTag`) and sync stops
///   rewriting it, but still points the plan item at it: the change the
///   worship leader asked for is what plays. Deleting it lets sync make
///   Shepherd's again.
/// - An arrangement made by hand is never rewritten. When one already has
///   Shepherd's name, it is used as is if it already plays Shepherd's
///   order; otherwise sync's is named "<name> (Shepherd)".
/// - A song imported from this Shepherd arrangement keeps the arrangement
///   the import made; the chart refresh owns its order (it is part of the
///   import fingerprint), so it is only selected here.
/// - The item's pick changes only while it is the one sync last set, or
///   none: a different pick made in Screens after a sync stays.
/// - When Anthem leads the song (its setlist is the plan's, the song is in
///   it, and Match Anthem runs automatically), Anthem's rule decides the
///   pick. Shepherd's arrangement is still made, so it is there to choose.
/// - Names in Shepherd's sequence the song has no section for are skipped,
///   and the item says so ("Shepherd's arrangement has Bridge 2; this song
///   has no Bridge 2"). Wordless parts (an intro, a turnaround) are skipped
///   quietly: a song without one is missing nothing on screen.
public enum ShepherdArrangementSync {

    // MARK: Section names

    /// A section name reduced to its kind and number: "V1", "Verse 1" and
    /// "verse1" are all verse 1; "Pre Chorus", "PreChorus" and "Pre-Chorus"
    /// are one kind; "Chorus (2x)" is chorus, twice.
    public struct SectionLabel: Hashable, Sendable {
        /// "verse", "chorus", "prechorus", "bridge", … or the name itself,
        /// squashed, when it isn't one of the usual parts.
        public var kind: String
        /// "2", "1b"; nil when the name has none.
        public var number: String?

        public init(kind: String, number: String? = nil) {
            self.kind = kind
            self.number = number
        }

        /// Parts with no words: a song without one loses nothing on screen.
        public var isWordless: Bool { Self.wordless.contains(kind) }

        static let wordless: Set<String> = ["intro", "instrumental", "interlude", "turnaround", "solo", "blank"]

        /// Parts a band plays without new words: a vamp, an outro, an
        /// ending, a breakdown, and the wordless ones above. A song that
        /// lacks one is only missing a blank to hold its place in the
        /// order, so it can be added without anyone typing. Verses,
        /// choruses, pre-choruses, bridges, refrains and tags carry
        /// lyrics: an empty slide there would hide a real gap.
        public var takesBlankSlide: Bool { Self.wordless.contains(kind) || Self.blankKinds.contains(kind) }

        static let blankKinds: Set<String> = ["vamp", "outro", "ending", "breakdown"]

        /// "Verse 3", "Pre-Chorus", for a warning.
        public var displayName: String {
            let names = [
                "verse": "Verse", "chorus": "Chorus", "prechorus": "Pre-Chorus", "bridge": "Bridge",
                "tag": "Tag", "intro": "Intro", "outro": "Outro", "ending": "Ending",
                "interlude": "Interlude", "instrumental": "Instrumental", "turnaround": "Turnaround",
                "vamp": "Vamp", "refrain": "Refrain", "solo": "Solo", "blank": "Blank",
            ]
            let base = names[kind] ?? kind.prefix(1).uppercased() + kind.dropFirst()
            return number.map { "\(base) \($0)" } ?? base
        }
    }

    private static let shortNames: [String: String] = [
        "v": "verse", "vs": "verse", "vrs": "verse",
        "c": "chorus", "ch": "chorus", "cho": "chorus", "chr": "chorus",
        "pc": "prechorus", "pre": "prechorus", "prech": "prechorus",
        "b": "bridge", "br": "bridge", "brdg": "bridge",
        "t": "tag", "tg": "tag",
        "i": "intro", "in": "intro",
        "o": "outro", "out": "outro",
        "e": "ending", "end": "ending",
        "int": "interlude", "inter": "interlude",
        "inst": "instrumental", "instr": "instrumental", "instrum": "instrumental",
        "ta": "turnaround", "turn": "turnaround", "turnaroud": "turnaround",
    ]

    /// The label a section name stands for and how many times it is
    /// played. Nil for a name with no letters.
    public static func label(_ raw: String) -> (label: SectionLabel, repeats: Int)? {
        var text = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "\u{00D7}", with: "x")
        var repeats = 1
        // Repeats and performance notes: "Chorus (2x)", "Chorus x2",
        // "Bridge 1 (2x) (Girl lead)".
        if let match = text.firstMatch(of: /(?:^|[\s(\[])(?:x\s*(\d+)|(\d+)\s*x)\s*[)\]]?(?=\s|$|[(\[])/) {
            repeats = Int(match.output.1 ?? match.output.2 ?? "1") ?? 1
            text.removeSubrange(match.range)
        }
        text = text.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ")
        text = String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }

        // A trailing number, written apart ("verse 2") or not ("v2", "1b").
        var kindWords = words
        var number: String?
        if let last = kindWords.last, kindWords.count > 1, last.first?.isNumber == true,
           last.wholeMatch(of: /\d+[a-z]?/) != nil {
            number = last
            kindWords.removeLast()
        } else if let last = kindWords.last, let match = last.wholeMatch(of: /([a-z]+)(\d+[a-z]?)/) {
            number = String(match.output.2)
            kindWords[kindWords.count - 1] = String(match.output.1)
        }
        var kind = kindWords.joined()
        kind = shortNames[kind] ?? kind
        if let digits = number, let value = Int(digits) { number = String(value) }
        return (SectionLabel(kind: kind, number: number), max(1, min(repeats, 8)))
    }

    /// The section a name in Shepherd's sequence plays, by label:
    /// - the same kind and number;
    /// - a name with no number ("Chorus") is the first of its kind;
    /// - number 1 is the kind's unnumbered section ("Verse 1" → "Verse");
    /// - a later number ("Chorus 2") is the kind's only section when that
    ///   one has no number, except for verses: a second verse has other
    ///   words, so it is reported missing rather than shown as the first.
    public static func sectionIndex(for wanted: SectionLabel, in labels: [SectionLabel?]) -> Int? {
        if let exact = labels.firstIndex(where: { $0 == wanted }) { return exact }
        let sameKind = labels.indices.filter { labels[$0]?.kind == wanted.kind }
        guard let first = sameKind.first else { return nil }
        guard let number = wanted.number else { return first }
        if number == "1", let plain = sameKind.first(where: { labels[$0]?.number == nil }) { return plain }
        if wanted.kind != "verse", sameKind.count == 1, labels[first]?.number == nil { return first }
        return nil
    }

    public struct Mapping: Equatable, Sendable {
        /// Section ids in Shepherd's order.
        public var sectionIds: [String]
        /// Shepherd's names the song has no section for, once each, as
        /// "Bridge 2".
        public var missing: [String]
    }

    /// Shepherd's sequence as the song's section ids. A song that opens on
    /// a blank (a "Blank" section, or an intro with no words) keeps it
    /// first, as an import does, so the screen starts clear.
    public static func mapping(sequence: [String], onto presentation: Presentation) -> Mapping {
        let sections = presentation.sections ?? []
        let labels = sections.map { label($0.name)?.label }
        var ids: [String] = []
        var missing: [String] = []
        for name in sequence {
            guard let (wanted, repeats) = label(name) else { continue }
            guard let index = sectionIndex(for: wanted, in: labels) else {
                let shown = wanted.displayName
                if !wanted.isWordless, !missing.contains(shown) { missing.append(shown) }
                continue
            }
            // A repeat plays the words again; a wordless part is one blank.
            ids += Array(repeating: sections[index].id, count: wanted.isWordless ? 1 : repeats)
        }
        if !ids.isEmpty, let opener = sections.first, ids.first != opener.id, opensOnBlank(presentation) {
            ids.insert(opener.id, at: 0)
        }
        return Mapping(sectionIds: ids, missing: missing)
    }

    /// The song's first section is a blank to open on: "Blank", or an
    /// intro with no words.
    public static func opensOnBlank(_ presentation: Presentation) -> Bool {
        guard let opener = presentation.sections?.first else { return false }
        if opener.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Blank") == .orderedSame { return true }
        guard Reflow.isIntro(opener.name) else { return false }
        return !presentation.slides.contains { slide in
            slide.sectionId == opener.id && slide.objects.contains {
                $0.objectKind == .text && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// "Shepherd's arrangement has Bridge 2; this song has no Bridge 2".
    public static func warning(missing name: String) -> String {
        "Shepherd's arrangement has \(name); this song has no \(name)"
    }

    /// The name in a warning made by `warning(missing:)`: "Bridge 2" from
    /// "Shepherd's arrangement has Bridge 2; this song has no Bridge 2". Nil
    /// for any other note.
    public static func missingName(fromWarning warning: String) -> String? {
        let head = "Shepherd's arrangement has "
        guard warning.hasPrefix(head), let split = warning.range(of: "; this song has no ") else { return nil }
        let name = String(warning[warning.index(warning.startIndex, offsetBy: head.count)..<split.lowerBound])
        guard !name.isEmpty, warning == Self.warning(missing: name) else { return nil }
        return name
    }

    // MARK: Following Shepherd's chart

    /// The song rebuilt from Shepherd's chart (`fresh`, the ChordPro chart
    /// of the plan's arrangement, else the song's) when the song can't play
    /// Shepherd's order and the chart can: Shepherd's ChordPro decides what
    /// a planned song holds, so the plan's arrangement always has every
    /// part it names. Nil when the song already has every part, or when the
    /// chart is missing the same parts (rebuilding would not help).
    ///
    /// This is what clears "Shepherd's arrangement has Bridge 2; this song
    /// has no Bridge 2" for a song linked from elsewhere in the library
    /// (ProPresenter, SongSelect) or edited in Screens. Themes, backgrounds,
    /// slide settings, the display key and other arrangements are kept, as
    /// an Update from Shepherd keeps them. A song taken over from elsewhere
    /// starts on Shepherd's order, as Import from Shepherd does.
    public static func catchingUp(
        _ presentation: Presentation, to fresh: Presentation, sequence: [String]
    ) -> Presentation? {
        guard !sequence.isEmpty else { return nil }
        let before = mapping(sequence: sequence, onto: presentation).missing
        guard !before.isEmpty else { return nil }
        var caught = ShepherdSongImport.replacing(presentation, with: fresh)
        if presentation.shepherdSongId != fresh.shepherdSongId {
            caught.defaultArrangementId = fresh.defaultArrangementId
            caught.shepherdImportHash = ShepherdSongImport.fingerprint(caught)
        }
        let after = mapping(sequence: sequence, onto: caught).missing
        guard after.count < before.count else { return nil }
        return caught
    }

    /// The song with a blank slide for each wordless part (Vamp, Outro,
    /// Ending…) Shepherd's order names and the song lacks, placed where
    /// Shepherd sings it; nil when there is none to add. Sync does this by
    /// itself, so those parts never show as missing.
    public static func fillingWordlessParts(
        _ presentation: Presentation, sequence: [String], arrangementId: String?, shepherdTag: String
    ) -> Presentation? {
        guard !sequence.isEmpty else { return nil }
        let blanks = blankFixableNames(in: mapping(sequence: sequence, onto: presentation).missing)
        guard !blanks.isEmpty else { return nil }
        let fix = addBlankSections(
            presentation, missing: blanks, sequence: sequence, arrangementId: arrangementId, shepherdTag: shepherdTag)
        return fix.added.isEmpty ? nil : fix.presentation
    }

    // MARK: Adding the parts a song lacks

    /// Of Shepherd's names the song has no section for, the ones that can
    /// be added as an empty slide (see `SectionLabel.takesBlankSlide`),
    /// once each and in the order given.
    public static func blankFixableNames(in names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            guard let label = label(name)?.label, label.takesBlankSlide else { return false }
            return seen.insert(label.displayName).inserted
        }
    }

    public struct BlankSectionFix: Equatable, Sendable {
        /// The song after.
        public var presentation: Presentation
        /// Names of the sections made ("Vamp", "Outro").
        public var added: [String]
        /// The names asked for that the song now has a section for: the
        /// ones added, and any that were there already. Their warnings
        /// are done with.
        public var resolved: [String]
    }

    /// Gives the song a blank slide, in a section of its own, for each of
    /// `missing` that is normally wordless (Vamp, Outro, Ending…), and puts
    /// the section where Shepherd's arrangement sings it. Lyric parts are
    /// left alone, and a name the song already has is not added again, so
    /// running it twice changes nothing more.
    ///
    /// - Parameters:
    ///   - missing: names from the warnings ("Vamp", "Bridge 2").
    ///   - sequence: Shepherd's order for the plan item; nil when it can't
    ///     be had, and the new sections go on the end.
    ///   - arrangementId: the arrangement the plan item plays (nil: the
    ///     song's default).
    ///   - shepherdTag: `tag(_:)` of the item's Shepherd arrangement. The
    ///     Screens arrangement that follows it (and the one in use, when
    ///     Shepherd made it) takes the new sections where Shepherd sings
    ///     them, and nothing else in it moves.
    ///
    /// An arrangement made by hand is never reordered: when it is the one in
    /// use, the new sections are added on its end, so they play.
    public static func addBlankSections(
        _ presentation: Presentation, missing: [String], sequence: [String]?, arrangementId: String?,
        shepherdTag: String? = nil, themeSlideName: String = "Lyrics"
    ) -> BlankSectionFix {
        var result = presentation
        guard var sections = presentation.sections, !sections.isEmpty else {
            return BlankSectionFix(presentation: presentation, added: [], resolved: [])
        }
        var labels: [SectionLabel?] = sections.map { label($0.name)?.label }
        var added: [String] = []
        var resolved: [String] = []
        var addedIds = Set<String>()
        for name in blankFixableNames(in: missing) {
            guard let wanted = label(name)?.label else { continue }
            resolved.append(name)
            if sectionIndex(for: wanted, in: labels) != nil { continue }
            let section = PresentationSection(id: UUID().uuidString, name: wanted.displayName)
            sections.append(section)
            labels.append(wanted)
            // Deliberately no `objects`: a blank slide, like the ones an
            // import makes for a part with no words. Themed as a lyric
            // slide so it takes the song's look.
            result.slides.append(Slide(
                id: UUID().uuidString, name: "", objects: [], sectionId: section.id, themeSlideName: themeSlideName))
            added.append(section.name)
            addedIds.insert(section.id)
        }
        guard !addedIds.isEmpty else { return BlankSectionFix(presentation: presentation, added: [], resolved: resolved) }
        result.sections = sections

        let newIds = sections.map(\.id).filter(addedIds.contains)
        let inUse = arrangementId ?? presentation.defaultArrangementId
        let target = sequence.map { mapping(sequence: $0, onto: result).sectionIds }
        var arrangements = result.arrangements ?? []
        for index in arrangements.indices {
            var arrangement = arrangements[index]
            let follows = shepherdTag.map { isSyncs(arrangement, tag: $0) } ?? false
            if follows || (arrangement.id == inUse && arrangement.shepherdArrangementId != nil) {
                arrangement.sectionIds = inserting(newIds, into: arrangement.sectionIds, following: target)
            } else if arrangement.id == inUse {
                arrangement.sectionIds += newIds.filter { !arrangement.sectionIds.contains($0) }
            }
            arrangements[index] = arrangement
        }
        if !arrangements.isEmpty { result.arrangements = arrangements }

        // A song still exactly as imported keeps following Shepherd's chart.
        if let imported = presentation.shepherdImportHash,
           imported == ShepherdSongImport.fingerprint(presentation) {
            result.shepherdImportHash = ShepherdSongImport.fingerprint(result)
        }
        return BlankSectionFix(presentation: result, added: added, resolved: resolved)
    }

    /// `order` with the new sections placed where `target` (Shepherd's
    /// order, with them) has them. Nothing already in `order` moves or goes:
    /// when `order` isn't `target` less the new ones, in the same order, the
    /// new sections go on the end instead.
    private static func inserting(_ new: [String], into order: [String], following target: [String]?) -> [String] {
        let newSet = Set(new)
        let appended = order + new.filter { !order.contains($0) }
        guard let target, target.contains(where: newSet.contains) else { return appended }
        var merged: [String] = []
        var next = 0
        for id in target {
            if newSet.contains(id) {
                merged.append(id)
            } else if next < order.count, order[next] == id {
                merged.append(id)
                next += 1
            }
        }
        return next == order.count ? merged : appended
    }

    // MARK: The song's arrangement

    public struct Outcome: Equatable, Sendable {
        /// The song's arrangements after, when they change; nil when the
        /// song needs no write.
        public var arrangements: [Arrangement]?
        /// The Screens arrangement that plays Shepherd's order; nil when the
        /// order matches none of the song's sections.
        public var arrangementId: String?
        public var warnings: [String]

        public init(arrangements: [Arrangement]? = nil, arrangementId: String? = nil, warnings: [String] = []) {
            self.arrangements = arrangements
            self.arrangementId = arrangementId
            self.warnings = warnings
        }
    }

    /// What `shepherdArrangementId` holds for a Shepherd arrangement: its
    /// id, or "song" for the song's own sequence when it has none.
    public static func tag(_ arrangement: ShepherdClient.SongArrangement?) -> String {
        arrangement?.id ?? "song"
    }

    /// What `shepherdArrangementId` holds once someone has changed sync's
    /// arrangement for `tag` by hand: still Shepherd's arrangement for the
    /// plan, but no longer one sync rewrites.
    public static func editedTag(_ tag: String) -> String {
        editedPrefix + tag
    }

    private static let editedPrefix = "edited:"

    /// `after` (an arrangement as an operator just changed it) marked as
    /// edited when it was one sync keeps in Shepherd's order. Anything else
    /// comes back as it is.
    public static func editedByHand(_ after: Arrangement, before: Arrangement) -> Arrangement {
        guard after != before, let tag = before.shepherdArrangementId, !tag.hasPrefix(editedPrefix) else { return after }
        var marked = after
        marked.shepherdArrangementId = editedTag(tag)
        return marked
    }

    /// Made by sync for this Shepherd arrangement: tagged, or (before the
    /// tag) under the fixed id an import or an earlier sync gave it.
    static func isSyncs(_ arrangement: Arrangement, tag: String) -> Bool {
        arrangement.shepherdArrangementId == tag
            || (arrangement.shepherdArrangementId == nil && arrangement.id == ShepherdSongImport.arrangementID(tag))
    }

    /// Makes sure the song has an arrangement in the order of `arrangement`
    /// (Shepherd's, for this plan item) and says which one it is.
    public static func reconcile(
        _ presentation: Presentation, song: ShepherdClient.SongDetail,
        arrangement: ShepherdClient.SongArrangement?
    ) -> Outcome {
        let sequence = ShepherdSongMatch.sequence(of: song, arrangement: arrangement)
        guard !sequence.isEmpty else { return Outcome() }
        guard presentation.sections?.isEmpty == false else {
            return Outcome(warnings: ["Shepherd's arrangement can't be used: this song's slides aren't in sections"])
        }
        let mapping = mapping(sequence: sequence, onto: presentation)
        let warnings = mapping.missing.map(warning(missing:))
        let tag = tag(arrangement)
        let fixedID = ShepherdSongImport.arrangementID(arrangement?.id)
        let existing = presentation.arrangements ?? []

        // The arrangement a Shepherd import made: the chart refresh keeps it.
        if presentation.shepherdSongId == song.id, presentation.shepherdArrangementId == arrangement?.id,
           existing.contains(where: { $0.id == fixedID }) {
            return Outcome(arrangementId: fixedID, warnings: warnings)
        }
        guard !mapping.sectionIds.isEmpty else { return Outcome(warnings: warnings) }

        let shepherdName = arrangement.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Shepherd"

        // A second copy (two Macs adding it at once) is dropped.
        var arrangements: [Arrangement] = []
        var seen = Set<String>()
        for item in existing where seen.insert(item.id).inserted { arrangements.append(item) }
        var changed = arrangements.count != existing.count

        // Sync's arrangement as an operator changed it: it plays as they left it.
        if let edited = arrangements.first(where: { $0.shepherdArrangementId == editedTag(tag) }) {
            return Outcome(arrangements: changed ? arrangements : nil, arrangementId: edited.id, warnings: warnings)
        }

        if let index = arrangements.firstIndex(where: { isSyncs($0, tag: tag) }) {
            var own = arrangements[index]
            own.sectionIds = mapping.sectionIds
            own.shepherdArrangementId = tag
            // It keeps its name while that is still Shepherd's (with or
            // without "(Shepherd)"); a renamed Shepherd arrangement renames it.
            if baseName(own.name).caseInsensitiveCompare(shepherdName) != .orderedSame
                || nameTaken(own.name, in: arrangements, except: own.id) {
                own.name = freeName(shepherdName, in: arrangements, except: own.id)
            }
            if own != arrangements[index] {
                arrangements[index] = own
                changed = true
            }
            return Outcome(arrangements: changed ? arrangements : nil, arrangementId: own.id, warnings: warnings)
        }

        // A hand-made arrangement of the same name that already plays
        // Shepherd's order is used as it is.
        if let same = arrangements.first(where: {
            $0.shepherdArrangementId == nil && $0.name.caseInsensitiveCompare(shepherdName) == .orderedSame
                && $0.sectionIds == mapping.sectionIds
        }) {
            return Outcome(arrangements: changed ? arrangements : nil, arrangementId: same.id, warnings: warnings)
        }

        let made = Arrangement(
            id: fixedID, name: freeName(shepherdName, in: arrangements, except: nil),
            sectionIds: mapping.sectionIds, shepherdArrangementId: tag)
        arrangements.removeAll { $0.id == made.id }
        arrangements.append(made)
        return Outcome(arrangements: arrangements, arrangementId: made.id, warnings: warnings)
    }

    /// "Default (Shepherd 2)" → "Default".
    static func baseName(_ name: String) -> String {
        name.replacing(/\s*\(Shepherd(?:\s+\d+)?\)$/, with: "")
    }

    private static func nameTaken(_ name: String, in arrangements: [Arrangement], except id: String?) -> Bool {
        arrangements.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Shepherd's name when no other arrangement has it, else
    /// "<name> (Shepherd)", numbered when that is taken too.
    static func freeName(_ name: String, in arrangements: [Arrangement], except id: String?) -> String {
        guard nameTaken(name, in: arrangements, except: id) else { return name }
        var candidate = "\(name) (Shepherd)"
        var number = 1
        while nameTaken(candidate, in: arrangements, except: id) {
            number += 1
            candidate = "\(name) (Shepherd \(number))"
        }
        return candidate
    }

    // MARK: The plan item's pick

    public struct Pick: Equatable, Sendable {
        /// The item's arrangement after (nil: the song's default).
        public var arrangementId: String?
        /// What sync set, to tell an operator's later pick from its own.
        public var syncedArrangementId: String?
    }

    /// The item's arrangement after sync, or nil to leave the item alone.
    ///
    /// - Parameters:
    ///   - current: the item's arrangement now (nil: the song's default).
    ///   - lastSynced: the one sync set last time, if any.
    ///   - target: the Screens arrangement for Shepherd's order.
    ///   - defaultId: the song's default arrangement.
    ///   - available: the song's arrangement ids.
    ///   - anthemLeads: Anthem decides this item's order.
    public static func pick(
        current: String?, lastSynced: String?, target: String?, defaultId: String?,
        available: Set<String>, anthemLeads: Bool
    ) -> Pick? {
        guard let target, !anthemLeads else { return nil }
        // A pick of an arrangement since deleted shows the default: as good as none.
        let current = current.flatMap { available.contains($0) ? $0 : nil }
        if (current ?? defaultId) == target {
            // Already showing it; remember it as sync's so a later Shepherd
            // change can move it.
            return lastSynced == target ? nil : Pick(arrangementId: current, syncedArrangementId: target)
        }
        // Sync's own pick (or never one): Shepherd's now.
        let lastSynced = lastSynced.flatMap { available.contains($0) ? $0 : nil }
        if current == lastSynced { return Pick(arrangementId: target, syncedArrangementId: target) }
        // Someone chose another in Screens since.
        return nil
    }
}
