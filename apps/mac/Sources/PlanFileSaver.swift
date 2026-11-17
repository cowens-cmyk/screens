import AppKit
import Foundation
import PresenterCore

/// Keeps every upcoming plan as files in Screens › Plans (ScreensFolder), so
/// another Mac running Screens (one not on the church library) can open it:
/// a folder per plan, named for it, with a .screensplan file of the whole
/// plan and a .screenspres file for each presentation in it. Each file is
/// written again only when what it holds has changed since. A plan's folder
/// goes to the Trash once the plan is gone from the library.
///
/// Only the Mac with Run on this Mac on writes them, like the old-plan and
/// message cleanup, so two Macs don't both copy the media.
@MainActor
final class PlanFileSaver {
    static let shared = PlanFileSaver()
    /// Settings › General: on unless turned off, kept per Mac.
    static let enabledKey = "plans.saveFiles"

    private static let intervalSeconds: TimeInterval = 15 * 60

    private weak var model: AppModel?
    private var timer: Timer?
    private var running = false
    private(set) var lastSaved: Date?
    private(set) var problem: String?

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

    /// Save Now, and every 15 minutes.
    func runSoon() {
        guard !running, Self.isEnabled, ServiceStation.runsService, let model, model.isLibraryReady else { return }
        running = true
        Task {
            defer { running = false }
            await run(model)
        }
    }

    private func run(_ model: AppModel) async {
        await model.resident.ready([.service])
        let today = AppModel.isoDate(.now)
        let plans = model.resident.services.values.filter {
            $0.isTemplate != true && String($0.serviceDate.prefix(10)) >= today
        }
        let root = model.client.rootURL
        let files = FileManager.default
        let look = ShareTransferRunner.lookExtras(model)
        problem = nil
        for plan in plans {
            let folder = ScreensFolder.plans.appendingPathComponent(ScreensFolder.fileName(plan.name), isDirectory: true)
            do {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                problem = "Couldn't make \(folder.path): \(error.localizedDescription)"
                return
            }
            var newest = model.libraryEntry(plan.id)?.updatedAt ?? .distantPast
            var seen = Set<String>()
            for item in plan.items where item.itemKind == .presentation && seen.insert(item.refId).inserted {
                guard let entry = model.libraryEntry(item.refId) else { continue }
                newest = max(newest, entry.updatedAt)
                let file = folder.appendingPathComponent(ScreensFolder.fileName(entry.name) + "." + ShareBundle.presentationExtension)
                guard Self.modified(file).map({ $0 < entry.updatedAt }) ?? true else { continue }
                do {
                    _ = try await ShareBundle.export(
                        root: root, kind: .presentation, id: entry.id, name: entry.name,
                        extraFiles: look.files, alsoIDs: look.ids, to: file)
                } catch {
                    problem = "Couldn't save \(entry.name): \(error.localizedDescription)"
                }
            }
            let planFile = folder.appendingPathComponent(ScreensFolder.fileName(plan.name) + "." + ShareBundle.planExtension)
            if Self.modified(planFile).map({ $0 < newest }) ?? true {
                do {
                    _ = try await ShareBundle.export(
                        root: root, kind: .service, id: plan.id, name: plan.name,
                        extraFiles: look.files, alsoIDs: look.ids, to: planFile)
                } catch {
                    problem = "Couldn't save \(plan.name): \(error.localizedDescription)"
                }
            }
        }
        removeGoneFolders(keeping: Set(model.resident.services.values.map { ScreensFolder.fileName($0.name) }))
        lastSaved = Date()
    }

    /// Folders of plans no longer in the library (taken out after four
    /// weeks, or deleted) go to the Trash. A folder someone made here by
    /// hand, with no plan file in it, stays.
    private func removeGoneFolders(keeping names: Set<String>) {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(
            at: ScreensFolder.plans, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders where !names.contains(folder.lastPathComponent) {
            let contents = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            guard contents.contains(where: { $0.hasSuffix("." + ShareBundle.planExtension) }) else { continue }
            try? files.trashItem(at: folder, resultingItemURL: nil)
        }
    }

    private static func modified(_ file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
