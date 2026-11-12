import Foundation
import PresenterCore

/// Keeps each Sunday's message presentation in the library's Messages
/// folder and takes out the ones whose last service was 30 days ago or
/// more (MessageCleanup decides which). Runs at launch and every few hours,
/// only on the Mac with **Run on this Mac** on, like the countdowns, so two
/// Macs don't both do it. Songs are never touched.
@MainActor
final class MessageCleanupRunner {
    static let shared = MessageCleanupRunner()
    /// Settings › General: on unless turned off, kept per Mac.
    static let enabledKey = "messages.removeOldAutomatically"

    private static let intervalSeconds: TimeInterval = 6 * 3600

    private weak var model: AppModel?
    private var timer: Timer?
    private var running = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func start(model: AppModel) {
        self.model = model
        model.whenLibraryReady { [weak self] in self?.runSoon() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runSoon() }
        }
    }

    private func runSoon() {
        guard !running, Self.isEnabled, ServiceStation.runsService, let model, model.isLibraryReady else { return }
        running = true
        Task {
            defer { running = false }
            await run(model)
        }
    }

    private func run(_ model: AppModel) async {
        await model.resident.ready([.service])
        let plans = Array(model.resident.services.values)
        let candidates = Array(MessageCleanup.messageIDs(in: plans))
        guard !candidates.isEmpty else { return }
        let decks = await model.presentationsFilled(candidates)
        let day = model.slideBuilding.serviceDay
        let protected = Set([day?.preServicePresentationId, day?.transitionPresentationId, day?.walkoutPresentationId]
            .compactMap { $0 }.filter { !$0.isEmpty } + [model.preServiceSlideshowID()].compactMap { $0 })
        let sweep = MessageCleanup.sweep(
            plans: plans,
            isSermon: { id in decks[id].map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true },
            folderOf: { decks[$0]?.folder },
            protected: protected,
            cutoff: MessageCleanup.cutoff(today: .now))

        for id in sweep.toFile {
            guard let entry = model.libraryEntry(id) else { continue }
            model.moveToFolder(entry, folder: MessageCleanup.folder)
        }
        let removing = sweep.toRemove.compactMap { model.libraryEntry($0) }
        if !removing.isEmpty {
            model.delete(removing)
        }
    }
}
