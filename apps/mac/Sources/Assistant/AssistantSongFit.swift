import Foundation
import PresenterCore

/// fit_song_slides: the Assistant's and Claude's way to Fit Song Slides to
/// Two Lines… (SongSlideFit), for one song or the whole library. Asks first
/// with how many slides in how many songs will change.
extension AssistantToolbox {

    func pendingSongFits(_ input: AssistantJSON) async throws -> [SongSlideFit.Change] {
        if let id = input["presentation_id"]?.string, !id.isEmpty {
            let deck = try await presentation(id)
            guard LyricSlideFit.isWorship(deck) else { throw Failure("\(deck.name) isn't a song.") }
            return await SongSlideFit.survey(model: model, ids: [deck.id])
        }
        return await SongSlideFit.survey(model: model)
    }

    func songFitConfirmation(_ input: AssistantJSON) async throws -> (title: String, detail: String) {
        let changes = try await pendingSongFits(input)
        guard !changes.isEmpty else { throw Failure("Nothing to fit: every song slide already shows two lines or fewer.") }
        var lines = changes.prefix(40).map { change in
            "• \(change.name): \(count(change.splitSlides, "slide")) become \(change.splitSlides + change.addedSlides)"
        }
        if changes.count > 40 { lines.append("…and \(count(changes.count - 40, "more song"))") }
        lines.append("\nEach new slide keeps its section label. Undo can't reverse this.")
        return ("Fit \(SongSlideFit.summary(changes)) to two lines?", lines.joined(separator: "\n"))
    }

    func fitSongSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let changes = try await pendingSongFits(input)
        guard !changes.isEmpty else { throw Failure("Nothing to fit: every song slide already shows two lines or fewer.") }
        let done = Set(await SongSlideFit.apply(changes, model: model))
        let fitted = changes.filter { done.contains($0.id) }
        let rows: [AssistantJSON] = fitted.map { change in
            ["presentation_id": .string(change.id), "name": .string(change.name),
             "slides_split": .number(Double(change.splitSlides)), "slides_added": .number(Double(change.addedSlides))]
        }
        var fields: [String: AssistantJSON] = ["fitted": .array(rows)]
        let skipped = changes.filter { !done.contains($0.id) }.map(\.name)
        if !skipped.isEmpty { fields["changed_since_checked"] = AssistantJSON(skipped) }
        return (.object(fields), "Fitted \(SongSlideFit.summary(fitted)) to two lines")
    }
}
