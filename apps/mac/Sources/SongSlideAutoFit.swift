import AppKit
import Foundation
import PresenterCore

/// Keeps every song's slides to one or two lines without anyone asking:
/// a slide that would take three in its theme is split, each part in the
/// same section (LyricSlideFit, the rule Fit Song Slides to Two Lines…
/// applies by hand). Songs are checked once at launch and again whenever
/// one changes, here or on another Mac.
///
/// One Mac does it: the Main Mac of a linked library, once it has caught up
/// with the others, or a Mac on its own. Two Macs splitting the same slide
/// each make new slides, and the library keeps both sets, so an Editor Mac
/// never splits and the Main Mac waits until sync is live.
///
/// It also waits until a song has been left alone for a minute, holds off
/// while this Mac is in Edit, never touches a song in the current plan while
/// anything is on the screens (the song just sung, or the next one, must not
/// change under the operator), and leaves a song alone when one of its
/// theme's fonts isn't on this Mac: measured in a stand-in font the lines
/// come out a different width and it would split what fits.
@MainActor
final class SongSlideAutoFit {
    static let shared = SongSlideAutoFit()

    private static let tickSeconds: TimeInterval = 15
    private static let quietSeconds: TimeInterval = 60

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

    /// Whether this is the Mac that splits: the Main Mac of a linked library
    /// once sync is live, or a Mac that isn't linked to one.
    static var thisMacFits: Bool {
        guard MainMacCoordinator.isLinked else { return true }
        guard MainMacCoordinator.shared.role == .main else { return false }
        if case .live = CloudSync.shared.status { return true }
        return false
    }

    /// The current plan's songs while anything is on the screens: a slide, a
    /// plan item, or a video. Before the first slide and after Clear All
    /// they are free to be fitted.
    private func songsHeldForTheService(_ model: AppModel) -> Set<String> {
        guard let controls,
              controls.livePresentationID != nil || controls.liveContextID != nil || controls.media.target != nil,
              let planID = model.currentServiceID, let plan = model.resident.services.value(planID)
        else { return [] }
        return Set(plan.items.map(\.refId).filter { !$0.isEmpty })
    }

    /// Every font the song's themes name is installed here. A song or theme
    /// that isn't in memory to be checked counts as not: it waits.
    static func fontsAreHere(for presentationID: String, model: AppModel) -> Bool {
        guard let deck = model.presentation(presentationID) else { return false }
        let themeIDs = Set([deck.themeId] + deck.slides.compactMap(\.themeId)).filter { !$0.isEmpty }
        for id in themeIDs {
            guard let theme = model.theme(id) else { return false }
            var names = Set([theme.fontFamily])
            for slide in theme.slides ?? [] {
                for object in slide.objects { names.insert(object.textStyle?.fontName ?? "") }
            }
            for name in names where !name.isEmpty {
                let installed = NSFont(name: name, size: 12) != nil
                    || NSFontManager.shared.availableMembers(ofFontFamily: name) != nil
                if !installed { return false }
            }
        }
        return true
    }

    private func tick() {
        guard !running, let model, model.isLibraryReady else { return }
        guard UserDefaults.standard.string(forKey: "appMode") != AppMode.edit.rawValue else { return }
        guard Self.thisMacFits else { return }
        let held = songsHeldForTheService(model)
        let due = Self.due(
            model.entries(of: .presentation), checked: checked, liveID: controls?.livePresentationID,
            quiet: Self.quietSeconds, now: Date()
        ).filter { !held.contains($0.id) }
        guard !due.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            let changes = await SongSlideFit.survey(model: model, ids: due.map(\.id))
            // Edit opened while they were being measured: someone may be
            // typing in one of them, so nothing is split until they leave.
            guard UserDefaults.standard.string(forKey: "appMode") != AppMode.edit.rawValue else { return }
            // Gone live while it was being measured: next time.
            let liveID = controls?.livePresentationID
            // A service that started meanwhile, or this Mac no longer the
            // one that fits: leave them all for a later pass.
            guard Self.thisMacFits else { return }
            let heldNow = songsHeldForTheService(model)
            let safe = changes.filter { $0.id != liveID && !heldNow.contains($0.id) && Self.fontsAreHere(for: $0.id, model: model) }
            let done = await SongSlideFit.apply(safe, model: model)
            let left = Set(changes.map(\.id)).subtracting(safe.map(\.id))
            for entry in due where entry.id != liveID && !left.contains(entry.id) { checked[entry.id] = entry.updatedAt }
            if !done.isEmpty {
                let fitted = changes.filter { done.contains($0.id) }
                DiagnosticsStore.shared.note(
                    "songs.fitToTwoLines",
                    detail: SongSlideFit.summary(fitted) + ": " + fitted.map(\.name).joined(separator: ", "))
            }
        }
    }
}
