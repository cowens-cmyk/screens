import AppKit
import Foundation
import PresenterCore
import SlideScene

/// Song slides show two lines at most (LyricSlideFit), on this Mac: the
/// line counter Shepherd imports use, and Fit Song Slides to Two Lines…, a
/// pass over the songs already in the library, made before imports split
/// slides by themselves.
@MainActor
enum SongSlideFit {

    /// Measures lyrics in the theme with this id. Nil when that theme isn't
    /// here: measured without it the box would be the wrong size, so slides
    /// are then cut by line count alone, as before.
    static func lineCount(themeId: String, model: AppModel) -> LyricSlideFit.LineCount? {
        guard let theme = model.theme(themeId) else { return nil }
        return LyricSlideFitter.lineCount(theme: { _ in theme })
    }

    /// One song the pass would change.
    struct Change: Sendable {
        var id: String
        var name: String
        var splitSlides: Int
        var addedSlides: Int
        /// The slides as measured, so a song edited since isn't written over.
        var before: [Slide]
        var after: [Slide]
    }

    /// The songs in the library (or just `ids`) with a slide that takes more
    /// than two lines in its theme, and what they'd become. Nothing changes.
    static func survey(model: AppModel, ids: [String]? = nil) async -> [Change] {
        await model.resident.ready([.theme])
        let themes = Dictionary(model.resident.themes.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let all = ids ?? model.entries(of: .presentation).map(\.id)
        var changes: [Change] = []
        // A batch at a time, measured off the main thread, so a large
        // library neither fills memory nor holds up the window.
        for start in stride(from: 0, to: all.count, by: 40) {
            let batch = Array(all[start..<min(start + 40, all.count)])
            guard let loaded = try? await model.client.loadValues(Presentation.self, ids: batch) else { continue }
            let decks = batch.compactMap { loaded.values[$0] }.filter(LyricSlideFit.isWorship)
            let found = await Task.detached(priority: .userInitiated) {
                decks.compactMap { deck -> Change? in
                    let result = LyricSlideFitter.fit(deck, themes: themes)
                    guard result.changed else { return nil }
                    return Change(
                        id: deck.id, name: deck.name, splitSlides: result.splitSlides, addedSlides: result.addedSlides,
                        before: deck.slides, after: result.presentation.slides)
                }
            }.value
            changes += found
        }
        return changes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes the changes. A song whose slides changed since the survey is
    /// left as it is. Returns the ids of the songs changed.
    @discardableResult
    static func apply(_ changes: [Change], model: AppModel) async -> [String] {
        var done: [String] = []
        for change in changes {
            let before = change.before, after = change.after
            let task = model.updatePresentation(change.id) { current in
                guard current.slides == before else { return }
                // A song still as Shepherd imported it stays that way, so
                // plan sync keeps updating it.
                let asImported = current.shepherdImportHash != nil
                    && current.shepherdImportHash == ShepherdSongImport.fingerprint(current)
                current.slides = after
                if asImported { current.shepherdImportHash = ShepherdSongImport.fingerprint(current) }
            }
            guard (try? await task.value) != nil,
                  let written = try? await model.client.loadValue(Presentation.self, id: change.id),
                  written.slides.map(\.id) == after.map(\.id)
            else { continue }
            done.append(change.id)
        }
        return done
    }

    /// "12 slides in 5 songs".
    static func summary(_ changes: [Change]) -> String {
        let slides = changes.reduce(0) { $0 + $1.splitSlides }
        return "\(slides) \(slides == 1 ? "slide" : "slides") in \(changes.count) \(changes.count == 1 ? "song" : "songs")"
    }

    // MARK: The menu command

    private static var running = false

    /// Fit Song Slides to Two Lines…: says what would change, asks, then
    /// does it.
    static func runFromMenu(model: AppModel) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let changes = await survey(model: model)
        guard !changes.isEmpty else {
            tell("Every song slide fits on two lines.", "Nothing was changed.")
            return
        }
        let names = changes.prefix(8).map(\.name).joined(separator: ", ") + (changes.count > 8 ? " and \(changes.count - 8) more" : "")
        let added = changes.reduce(0) { $0 + $1.addedSlides }
        let message = """
            \(summary(changes)) take more than two lines in their theme. Each becomes slides of one or two lines, \
            with the same section label (\(added) \(added == 1 ? "slide" : "slides") added).

            Songs: \(names).

            This changes the songs for every Mac on the library, and Undo can't reverse it.
            """
        guard QuitConfirmation.ask(title: "Fit \(summary(changes)) to two lines?", message: message, button: "Fit Slides")
        else { return }
        let done = await apply(changes, model: model)
        if done.count < changes.count {
            tell("Fitted \(done.count) of \(changes.count) songs.",
                 "The others changed while Screens was checking them. Run Fit Song Slides to Two Lines… again for those.")
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
