import Foundation
import PresenterCore

/// Keeps every song's slides to one or two lines without anyone asking:
/// a slide that would take three in its theme is split, each part in the
/// same section (LyricSlideFit, the rule Fit Song Slides to Two Lines…
/// applies by hand). Songs are checked once at launch and again whenever
/// one changes, here or on another Mac.
///
/// It waits until a song has been left alone for a while, never touches the
/// song that is on screen, and holds off while this Mac is in Edit, so a
/// slide isn't split under someone still typing its third line. The Main Mac
/// (or a Mac on its own) goes first; the others wait longer, and by then the
/// split has usually synced in and there is nothing left for them to do.
@MainActor
final class SongSlideAutoFit {
    static let shared = SongSlideAutoFit()

    private static let tickSeconds: TimeInterval = 15
    private static let quietSeconds: TimeInterval = 20
    private static let quietSecondsOtherMacs: TimeInterval = 90

    private weak var model: AppModel?
    private weak var controls: ServiceControls?
    private var timer: Timer?
    private var running = false
    /// Each song's `updatedAt` when it was last checked.
    private var checked: [String: Date] = [:]

    func start(model: AppModel, controls: ServiceControls) {
        guard timer == nil else { return }
        self.model = model
        self.controls = controls
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { _ in
            Task { @MainActor in SongSlideAutoFit.shared.tick() }
        }
    }

    /// The songs changed since they were last checked and quiet since.
    static func due(
        _ entries: [LibraryIndex.Entry], checked: [String: Date], liveID: String?, quiet: TimeInterval, now: Date
    ) -> [LibraryIndex.Entry] {
        entries.filter {
            $0.kind == .presentation && checked[$0.id] != $0.updatedAt && $0.id != liveID
                && now.timeIntervalSince($0.updatedAt) >= quiet
        }
    }

    private func tick() {
        guard !running, let model, model.isLibraryReady else { return }
        guard UserDefaults.standard.string(forKey: "appMode") != AppMode.edit.rawValue else { return }
        let quiet = MainMacCoordinator.shared.role == .editor ? Self.quietSecondsOtherMacs : Self.quietSeconds
        let due = Self.due(
            model.entries(of: .presentation), checked: checked, liveID: controls?.livePresentationID,
            quiet: quiet, now: Date())
        guard !due.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            let changes = await SongSlideFit.survey(model: model, ids: due.map(\.id))
            // Gone live while it was being measured: next time.
            let liveID = controls?.livePresentationID
            let done = await SongSlideFit.apply(changes.filter { $0.id != liveID }, model: model)
            for entry in due where entry.id != liveID { checked[entry.id] = entry.updatedAt }
            if !done.isEmpty {
                let fitted = changes.filter { done.contains($0.id) }
                DiagnosticsStore.shared.note(
                    "songs.fitToTwoLines",
                    detail: SongSlideFit.summary(fitted) + ": " + fitted.map(\.name).joined(separator: ", "))
            }
        }
    }
}
