import Foundation
import PresenterCore

/// Keeps each Sunday's message presentation in the library's Messages
/// folder and takes out the ones whose last service was 30 days ago or
/// more (MessageCleanup decides which), and takes out plans more than four
/// weeks past, each saved to the Trash first (PlanCleanup). Runs at launch
/// and every few hours, only on the Mac with **Run on this Mac** on, like
/// the countdowns, so two Macs don't both do it. Songs are never touched.
@MainActor
final class MessageCleanupRunner {
    static let shared = MessageCleanupRunner()
    /// Settings › General: on unless turned off, kept per Mac.
    static let enabledKey = "messages.removeOldAutomatically"
    /// Settings › General: on unless turned off, kept per Mac.
    static let plansEnabledKey = "plans.removeOldAutomatically"

    private static let intervalSeconds: TimeInterval = 6 * 3600

    private weak var model: AppModel?
    private var timer: Timer?
    private var running = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var removesOldPlans: Bool {
        UserDefaults.standard.object(forKey: plansEnabledKey) as? Bool ?? true
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
        guard !running, Self.isEnabled || Self.removesOldPlans, ServiceStation.runsService, let model,
              model.isLibraryReady else { return }
        running = true
        Task {
            defer { running = false }
            await run(model)
        }
    }

    private func run(_ model: AppModel) async {
        await model.resident.ready([.service])
        if Self.isEnabled { await removeOldMessages(model) }
        if Self.removesOldPlans { await removeOldPlans(model) }
    }

    private func protectedPresentations(_ model: AppModel) -> Set<String> {
        let day = model.slideBuilding.serviceDay
        return Set([day?.preServicePresentationId, day?.transitionPresentationId, day?.walkoutPresentationId]
            .compactMap { $0 }.filter { !$0.isEmpty } + [model.preServiceSlideshowID()].compactMap { $0 })
    }

    /// Plans more than four weeks past: each is written to a file in the
    /// Trash, then taken out of the library with the message only it used.
    /// A plan that couldn't be saved to the Trash stays.
    private func removeOldPlans(_ model: AppModel) async {
        let plans = Array(model.resident.services.values)
        let keep = Set([model.currentServiceID].compactMap { $0 })
        let old = PlanCleanup.oldPlans(plans, cutoff: PlanCleanup.cutoff(today: .now), keep: keep)
        guard !old.isEmpty else { return }
        let trashed = old.filter(Self.saveToTrash)
        guard !trashed.isEmpty else { return }
        let gone = Set(trashed.map(\.id))
        let named = Array(Set(trashed.compactMap(\.messagePresentationId)))
        let decks = await model.presentationsFilled(named)
        let messages = PlanCleanup.messages(
            of: trashed, remaining: plans.filter { !gone.contains($0.id) },
            isSermon: { id in decks[id].map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true },
            protected: protectedPresentations(model))
        for plan in trashed { model.client.delete(kind: .service, id: plan.id) }
        let removing = messages.compactMap { model.libraryEntry($0) }
        if !removing.isEmpty { model.delete(removing) }
    }

    /// The plan as a JSON file in the Mac's Trash; false when it couldn't be.
    private static func saveToTrash(_ plan: Service) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("screens-old-plans-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent(PlanCleanup.trashFileName(for: plan))
            try encoder.encode(plan).write(to: file, options: .atomic)
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    private func removeOldMessages(_ model: AppModel) async {
        let plans = Array(model.resident.services.values)
        let candidates = Array(MessageCleanup.messageIDs(in: plans))
        guard !candidates.isEmpty else { return }
        let decks = await model.presentationsFilled(candidates)
        let protected = protectedPresentations(model)
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
