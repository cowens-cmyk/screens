import AppKit
import Foundation
import PresenterCore

/// Match Chords to Shepherd…: every song's stage display chords made to
/// match its Shepherd chord chart (ShepherdChordMatch). Words, slides and
/// order stay as they are; chords set by hand on lines the chart decides
/// are dropped. Says what would change, asks, then does it.
@MainActor
enum ShepherdChordSync {

    struct Change: Sendable {
        var id: String
        var name: String
        var before: Presentation
        var after: Presentation
        var changedLines: Int
        var droppedHandEdits: Int
        var unmatched: [String]
        var examples: [String]
        /// Words shown split in two, now joined as the chart writes them.
        var joined: [String] = []
        /// Intro, Instrumental and other wordless slides given the chart's chords.
        var chordOnly = 0
        /// The Shepherd song it now follows, when the link was missing or gone.
        var relinkedTo: String?
    }

    struct Survey {
        var changes: [Change] = []
        var alreadyMatching = 0
        var notOnShepherd: [String] = []
        var failed: [String] = []
        /// Lines left as they were in songs already matching, by song.
        var unmatched: [String: [String]] = [:]
    }

    /// Every song (or just `ids`) against Shepherd. Nothing changes.
    static func survey(model: AppModel, ids: [String]? = nil) async -> Survey {
        let sync = ShepherdSync.shared
        let client = sync.client
        await model.resident.ready([.theme])
        var survey = Survey()
        let all = ids ?? model.entries(of: .presentation).map(\.id)
        for start in stride(from: 0, to: all.count, by: 40) {
            let batch = Array(all[start ..< min(start + 40, all.count)])
            guard let loaded = try? await model.client.loadValues(Presentation.self, ids: batch) else { continue }
            for song in batch.compactMap({ loaded.values[$0] }) where song.presentationKind == .song {
                // The linked Shepherd song, else one of the same title.
                var detail: ShepherdClient.SongDetail?
                var relinked = false
                do {
                    if let id = song.shepherdSongId, let linked = try? await client.song(id: id) {
                        detail = linked
                    } else {
                        let hits = try await client.searchSongs(song.name, limit: 10)
                        let title = ShepherdChordMatch.normalized(song.name)
                        if let hit = hits.first(where: { ShepherdChordMatch.normalized($0.title) == title }) {
                            detail = try await client.song(id: hit.id)
                            relinked = true
                        }
                    }
                } catch {
                    survey.failed.append(song.name)
                    continue
                }
                guard let detail else {
                    survey.notOnShepherd.append(song.name)
                    continue
                }
                let arrangement = ShepherdSongImport.trackedArrangement(
                    of: detail, id: relinked ? nil : song.shepherdArrangementId)
                guard let chart = ShepherdSongImport.presentation(
                    song: detail, arrangement: arrangement,
                    options: sync.importOptions(playingKey: nil, model: model, themeId: song.themeId))
                else {
                    survey.notOnShepherd.append(song.name)
                    continue
                }
                let match = ShepherdChordMatch.matching(song, to: chart)
                var after = match.presentation
                let hash = ShepherdSongImport.chartHash(song: detail, arrangement: arrangement)
                // A song still as Shepherd imported it stays that way, so plan
                // sync keeps following its chart.
                let asImported = song.shepherdImportHash != nil
                    && song.shepherdImportHash == ShepherdSongImport.fingerprint(song)
                if relinked {
                    after.shepherdSongId = detail.id
                    after.shepherdArrangementId = arrangement?.id
                }
                after.shepherdChartHash = hash
                if asImported { after.shepherdImportHash = ShepherdSongImport.fingerprint(after) }
                guard match.changed || relinked else {
                    survey.alreadyMatching += 1
                    if !match.unmatchedWords.isEmpty { survey.unmatched[song.name] = match.unmatchedWords }
                    continue
                }
                survey.changes.append(Change(
                    id: song.id, name: song.name, before: song, after: after,
                    changedLines: match.changedLines, droppedHandEdits: match.droppedHandEdits,
                    unmatched: match.unmatchedWords, examples: match.examples,
                    joined: match.joinedWords, chordOnly: match.chordOnlySlides,
                    relinkedTo: relinked ? detail.title : nil))
            }
        }
        survey.changes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return survey
    }

    /// Writes the changes; a song edited since the survey is left alone.
    /// Returns the names of the songs changed.
    @discardableResult
    static func apply(_ changes: [Change], model: AppModel) async -> [String] {
        var done: [String] = []
        for change in changes {
            let before = change.before, after = change.after
            let task = model.updatePresentation(change.id) { current in
                guard current.slides == before.slides, current.chordEdits == before.chordEdits else { return }
                current.slides = after.slides
                current.chordEdits = after.chordEdits
                current.shepherdSongId = after.shepherdSongId
                current.shepherdArrangementId = after.shepherdArrangementId
                current.shepherdChartHash = after.shepherdChartHash
                current.shepherdImportHash = after.shepherdImportHash
            }
            guard (try? await task.value) != nil,
                  let written = try? await model.client.loadValue(Presentation.self, id: change.id),
                  written.slides == after.slides
            else { continue }
            ShepherdSync.shared.newerCharts[change.id] = nil
            done.append(change.name)
        }
        DiagnosticsStore.shared.note(
            "shepherd.chords", detail: "matched chords to Shepherd in \(done.count) of \(changes.count) songs: \(done.joined(separator: ", "))")
        return done
    }

    // MARK: The menu command

    private static var running = false

    static func runFromMenu(model: AppModel) async {
        guard !running else { return }
        guard ShepherdSync.shared.isConfigured else {
            tell("Shepherd isn't set up.", ShepherdError.notConfigured.errorDescription ?? "")
            return
        }
        running = true
        defer { running = false }
        let survey = await survey(model: model)
        var notes: [String] = []
        if !survey.notOnShepherd.isEmpty {
            notes.append("Not on Shepherd (left as they are): \(survey.notOnShepherd.joined(separator: ", ")).")
        }
        if !survey.failed.isEmpty {
            notes.append("Couldn't reach Shepherd for: \(survey.failed.joined(separator: ", ")). Try again for those.")
        }
        guard !survey.changes.isEmpty else {
            tell("Every song's chords match Shepherd.",
                 (["\(survey.alreadyMatching) songs checked; nothing was changed."] + notes).joined(separator: "\n\n"))
            return
        }
        let lines = survey.changes.reduce(0) { $0 + $1.changedLines + $1.chordOnly }
        let list = survey.changes.map { change -> String in
            var parts: [String] = []
            if change.changedLines > 0 || change.chordOnly == 0 {
                parts.append("\(change.changedLines) \(change.changedLines == 1 ? "line" : "lines")")
            }
            if change.chordOnly > 0 {
                parts.append("\(change.chordOnly) chord-only \(change.chordOnly == 1 ? "slide" : "slides") (Intro, Instrumental…)")
            }
            if !change.joined.isEmpty {
                let words = Array(Set(change.joined)).sorted().map { "“\($0)”" }.joined(separator: ", ")
                parts.append("rejoins \(words)")
            }
            if change.droppedHandEdits > 0 { parts.append("\(change.droppedHandEdits) hand-set") }
            if !change.unmatched.isEmpty { parts.append("\(change.unmatched.count) not in the chart, kept") }
            if let relinked = change.relinkedTo { parts.append("now linked to “\(relinked)”") }
            return "• \(change.name): " + parts.joined(separator: ", ")
        }.joined(separator: "\n")
        let message = """
            \(list)

            Chords on the lines whose words are in the chart become the chart's; chords set by hand on those lines \
            are dropped. Wordless slides (Intro, Instrumental…) get the chart's chord rows, and a word shown split \
            in two is joined as the chart writes it. Otherwise words, slides and order stay as they are. Lines the \
            chart doesn't have keep their chords.
            \(notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n"))
            This changes the songs for every Mac on the library, and Undo can't reverse it.
            """
        let title = "Match \(lines) \(lines == 1 ? "line" : "lines") in \(survey.changes.count) \(survey.changes.count == 1 ? "song" : "songs") to Shepherd?"
        guard QuitConfirmation.ask(title: title, message: message, button: "Match Chords") else { return }
        let done = await apply(survey.changes, model: model)
        if done.count < survey.changes.count {
            tell("Matched \(done.count) of \(survey.changes.count) songs.",
                 "The others changed while Screens was checking them. Run Match Chords to Shepherd… again for those.")
        } else {
            tell("Chords now match Shepherd in \(done.count) \(done.count == 1 ? "song" : "songs").", "")
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
