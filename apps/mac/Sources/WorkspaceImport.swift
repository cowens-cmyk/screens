import AppKit
import Foundation
import PresenterCore
import ProImport
import RenderEngine
import SlideScene

@MainActor
struct WorkspaceImportRunner {
    let model: AppModel
    let render: RenderContext
    let controls: ServiceControls
    let confidenceMonitor: ConfidenceMonitorController?

    var inlineHost: ((ImportActivityModel?) -> Void)?

    func present() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a ProPresenter show directory (it contains Libraries, Themes, and Configuration)"
        panel.prompt = "Import Workspace"
        if let showDirectory = ProPresenterImporter.proPresenterShowDirectory() {
            panel.directoryURL = showDirectory
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await preflight(showDirectory: url)
            }
        }
    }

    private static let optionsDefaultsKey = "import.workspace.options"

    static func loadOptions() -> WorkspaceImportOptions {
        guard let data = UserDefaults.standard.data(forKey: optionsDefaultsKey),
              let stored = try? JSONDecoder().decode(WorkspaceImportOptions.self, from: data)
        else { return WorkspaceImportOptions() }
        return stored
    }

    static func saveOptions(_ options: WorkspaceImportOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: optionsDefaultsKey)
        }
    }

    func preflight(showDirectory: URL) async {
        guard let importer = try? await ProWorkspaceImporter(client: model.client) else { return }
        let activity = ImportActivityModel(title: "Import ProPresenter Workspace")
        if let inlineHost {
            inlineHost(activity)
        } else {
            ImportActivityWindow.present(activity)
        }
        activity.phase = "Scanning\u{2026}"
        let scan = importer.scan(showDirectory: showDirectory)
        activity.requestOptions(scan: scan, options: Self.loadOptions()) { confirmed in
            guard let confirmed else {
                if let inlineHost {
                    inlineHost(nil)
                } else {
                    ImportActivityWindow.dismiss()
                }
                return
            }
            Self.saveOptions(confirmed)
            Task { @MainActor in
                await run(
                    importer: importer, activity: activity,
                    showDirectory: showDirectory, options: confirmed)
            }
        }
    }

    func run(
        importer: ProWorkspaceImporter, activity: ImportActivityModel,
        showDirectory: URL, options: WorkspaceImportOptions
    ) async {
        // This app has exactly three screens and no overlays or Looks, so a
        // workspace's screens, slices, masks, Looks and props stay behind.
        var options = options
        options.overlays = false
        options.screens = false
        options.screenCorrections = false
        options.screenSlices = false
        options.screenMasks = false
        options.looks = false
        let result = await importer.importWorkspace(
            showDirectory: showDirectory,

            existingTimers: controls.timers.timers.map { ProTimerSeed(id: $0.id, name: $0.name) },

            existingInputs: VideoInputInventory.shared.entries.map {
                ProInputSeed(id: $0.id, name: $0.name, sourceId: $0.sourceId)
            },
            options: options
        ) { progress in
            activity.apply(progress)
        }
        activity.phase = "Finishing…"

        let refreshExisting = options.policy == .replace

        for plan in result.timerPlans where options.timers {
            if !refreshExisting, controls.timers.timers.contains(where: { $0.id == plan.newID }) {
                continue
            }
            switch plan.mode {
            case .countdown(let seconds):
                controls.timers.importTimer(id: plan.newID, name: plan.name, mode: .countdown, durationSeconds: seconds)
            case .countdownToTime(let hour, let minute):
                controls.timers.importTimer(
                    id: plan.newID, name: plan.name, mode: .countdownToTime,
                    targetTime: TimersController.nextOccurrence(hour: hour, minute: minute)
                )
            case .countUp(let limit):
                controls.timers.importTimer(id: plan.newID, name: plan.name, mode: .countUp, durationSeconds: limit)
            }
        }

        var inputsImported = 0
        if options.videoInputs {
            for plan in result.inputPlans where VideoInputInventory.shared.importEntry(
                id: plan.newID, name: plan.name, kind: plan.kind, sourceId: plan.sourceId
            ) {
                inputsImported += 1
            }
        }

        if options.stageAssignments,
           let first = result.screenPlan.stageAssignments.first,
           let stage = UUID(uuidString: ShowSetup.shared.stageTarget) {
            confidenceMonitor?.setLayout(first.layoutID, forScreen: stage)
        }

        if !result.midiDevicesImported.isEmpty {
            MIDIDeviceInventory.shared.reload()
        }

        if options.groupHotKeys {
            var merged = result.groupHotKeys
            for summary in result.presentations {
                merged.merge(summary.groupHotKeys) { first, _ in first }
            }
            await model.applyImportedGroupHotKeys(merged, policy: options.policy)
        }

        await model.client.settled()
        model.noteExternalMutation()
        model.noteImportReplacedDocuments()

        model.adoptFallbackServiceIfNeeded()
        summarize(
            result, inputsImported: inputsImported, into: activity
        )
    }

    private func summarize(
        _ result: ProWorkspaceImporter.Result, inputsImported: Int,
        into activity: ImportActivityModel
    ) {
        let imported = result.presentations.filter { $0.presentationID != nil && $0.skipped == nil }
        var lines: [String] = []
        lines.append("\(imported.count) presentations, \(result.mediaImported) media files")
        if result.mediaWithheld > 0 {
            lines.append("\(result.mediaWithheld) referenced media files left out (Include referenced media files was off)")
        }
        if !result.mediaFoldersImported.isEmpty {
            lines.append("\(result.mediaFoldersImported.count) media bin playlists → Folders: \(result.mediaFoldersImported.joined(separator: ", "))")
        }

        if result.skippedExisting > 0 {
            lines.append("\(result.skippedExisting) already here — kept yours (only adding new)")
        }
        if !result.skippedEdited.isEmpty {
            lines.append("\(result.skippedEdited.count) kept — edited here since import")
        }
        if !result.themesImported.isEmpty { lines.append("\(result.themesImported.count) themes: \(result.themesImported.joined(separator: ", "))") }
        if !result.alertsImported.isEmpty { lines.append("\(result.alertsImported.count) messages → Alerts") }
        if !result.layoutsImported.isEmpty { lines.append("\(result.layoutsImported.count) stage layouts → Confidence Layouts") }
        if !result.combosImported.isEmpty { lines.append("\(result.combosImported.count) macros → Action Combos") }
        if !result.timerPlans.isEmpty { lines.append("\(result.timerPlans.count) timers") }
        if inputsImported > 0 { lines.append("\(inputsImported) video inputs") }
        if !result.midiDevicesImported.isEmpty { lines.append("\(result.midiDevicesImported.count) MIDI devices: \(result.midiDevicesImported.joined(separator: ", "))") }
        if !result.servicesImported.isEmpty { lines.append("\(result.servicesImported.count) playlists → Services: \(result.servicesImported.joined(separator: ", "))") }
        if !result.schedulesImported.isEmpty { lines.append("\(result.schedulesImported.count) calendar events → Scheduler: \(result.schedulesImported.joined(separator: ", "))") }

        var warnings = result.warnings + result.presentations.flatMap { summary in
            summary.presentationID == nil ? summary.warnings.map { "\(summary.name): \($0)" } : []
        }
        if !result.skippedEdited.isEmpty {
            warnings.append(
                "Edited here since import, kept yours: \(result.skippedEdited.joined(separator: ", ")). Run the import again with \u{201C}Replace with imported\u{201D} to overwrite them.")
        }
        activity.finish(summaryLines: lines, warnings: warnings)

        model.noteImportSummary("Workspace import: \(imported.count) presentations, \(result.themesImported.count) themes, \(result.alertsImported.count) alerts, \(result.layoutsImported.count) layouts, \(result.combosImported.count) combos, \(result.servicesImported.count) services")
    }
}
