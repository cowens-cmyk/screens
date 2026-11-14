import Foundation
import PresenterCore

/// The import a piece of work belongs to, so an import started inside
/// another (a PDF's pages, the files of a drop that also pairs lower thirds
/// and makes slides) counts on the same line of the activity bar.
enum ImportActivity {
    @TaskLocal static var current: ActivityBoard.Ticket?
}

extension AppModel {

    func beginImportActivity(_ stage: ActivityBoard.ImportStage = .preparing) -> ActivityBoard.Ticket {
        activity.beginImport(stage)
    }

    func endImportActivity(_ ticket: ActivityBoard.Ticket) {
        activity.endImport(ticket, at: Date())
        scheduleActivityExpiry()
    }

    /// Takes each summary down when its time is up. One waiting task,
    /// re-aimed whenever the board changes what's due next.
    func scheduleActivityExpiry() {
        activityExpiry?.cancel()
        guard let due = activity.nextExpiry else { return }
        activityExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0)))
            guard !Task.isCancelled, let self else { return }
            self.activity.expire(at: Date())
            self.scheduleActivityExpiry()
        }
    }

    func dismissActivity(_ kind: ActivityBoard.Line.Kind) {
        activity.dismiss(kind)
        scheduleActivityExpiry()
    }

    /// Work with no count of its own (a PowerPoint or ProPresenter import)
    /// on the activity bar's import line, named by its first file. Inside
    /// another import it joins that one.
    func withImportActivity<T>(named urls: [URL], _ body: () async -> T) async -> T {
        // Inside another import (a Keynote deck goes through PowerPoint)
        // the line keeps the name the operator dropped.
        if ImportActivity.current != nil { return await body() }
        let ticket = beginImportActivity(.document(name: urls.first?.lastPathComponent ?? ""))
        defer { endImportActivity(ticket) }
        let before = lastImportSummary
        let result = await ImportActivity.$current.withValue(ticket) { await body() }
        if lastImportSummary != before, let said = lastImportSummary {
            activity.note(said, of: ticket)
        }
        return result
    }

    /// Files dropped from the Finder to become slides: shown in the
    /// activity bar from the moment of the drop, through finding their
    /// lower thirds, the import itself and making the slides. `pairing`
    /// adds the lower thirds lying beside them in their folders.
    func importForSlides(
        _ urls: [URL], pairing: Bool = true, makeSlides: @MainActor ([String]) -> Void
    ) async {
        let ticket = beginImportActivity(.preparing)
        defer { endImportActivity(ticket) }
        await ImportActivity.$current.withValue(ticket) {
            let files = pairing ? await MediaSlides.withLowerThirds(urls) : urls
            let imported = await importFiles(files)
            activity.setStage(.makingSlides, of: ticket)
            makeSlides(imported)
        }
    }
}
