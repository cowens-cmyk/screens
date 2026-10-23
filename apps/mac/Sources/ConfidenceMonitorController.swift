import Foundation
import Observation
import OutputEngine
import PresenterCore
import SlideScene
import SwiftUI

/// Keeps the stage (confidence) screens' scenes.
///
/// The rule: the stage mode (Worship, Message, Mirror in Show Setup) decides
/// what every stage screen shows. A layout picked for a screen — by a slide's
/// stage layout, a Set Stage Layout action, or the screen's own menu — shows
/// instead, until the stage mode is changed again; changing the mode clears
/// those picks. A playing foreground video takes over all of it until the
/// video ends or is cleared.
@MainActor
@Observable
final class ConfidenceMonitorController {
    static let assignmentsKey = "confidence.screenLayouts"

    /// Layouts picked per screen; they override the stage mode.
    private(set) var assignments: [UUID: String] = [:]

    private(set) var previewLayoutChoices: [PreviewTargetLogic.Choice] = []

    private(set) var previewAspects: [String: Double] = [:]

    private var previewCounts: [String: Int] = [:]

    private let appModel: AppModel
    private let render: RenderContext
    private weak var controls: ServiceControls?

    init(appModel: AppModel, render: RenderContext, controls: ServiceControls) {
        self.appModel = appModel
        self.render = render
        self.controls = controls
        restore()
        refresh()
        armMutationWatch()
        armStageWatch()
        // Setting the mode, even to the one already showing, drops the
        // per-screen picks so the mode shows at once.
        let earlier = ShowSetup.shared.onStageChange
        ShowSetup.shared.onStageChange = { [weak self] in
            earlier?()
            self?.stageModeSet()
        }
    }

    private func stageModeSet() {
        layoutsBeforeAudience = [:]
        if !assignments.isEmpty {
            assignments.removeAll()
            persist()
        }
        refresh()
    }

    var confidenceScreens: [(id: UUID, name: String)] {
        render.outputs.placeholderScreens
            .filter { render.outputs.role(forScreen: $0.id) == .confidence }
            .map { ($0.id, $0.name) }
    }

    func setLayout(_ layoutID: String?, forScreen id: UUID) {
        guard assignments[id] != layoutID else { return }
        if let layoutID, !layoutID.isEmpty {
            assignments[id] = layoutID
        } else {
            assignments.removeValue(forKey: id)
        }
        persist()
        refresh()
    }

    /// A slide's Show on Stage Display lasts for that slide: the stage goes
    /// back to its mode (or the layout picked before) when it's gone.
    func endAudiencePick() {
        let picked = assignments.filter { $0.value == StageLayouts.audienceID }.map(\.key)
        guard !picked.isEmpty else { return }
        for screenID in picked {
            if let earlier = layoutsBeforeAudience[screenID] {
                assignments[screenID] = earlier
            } else {
                assignments.removeValue(forKey: screenID)
            }
        }
        layoutsBeforeAudience = [:]
        persist()
        refresh()
    }

    /// What each screen had picked before a slide put the audience screen
    /// on it, so it comes back after.
    private var layoutsBeforeAudience: [UUID: String] = [:]

    func apply(layoutID: String?, toScreen screenID: UUID?) {
        let resolved = (layoutID?.isEmpty ?? true) ? nil : layoutID
        if resolved == StageLayouts.audienceID {
            let screens = screenID.map { [$0] } ?? confidenceScreens.map { $0.id }
            for screen in screens where assignments[screen] != StageLayouts.audienceID {
                layoutsBeforeAudience[screen] = assignments[screen]
            }
        } else {
            layoutsBeforeAudience = [:]
        }
        if let resolved, resolved != StageLayouts.audienceID, appModel.indexEntry(resolved) == nil {
            DiagnosticsStore.shared.note("confidence.layout.missing", detail: resolved)
            return
        }
        if let screenID {
            setLayout(resolved, forScreen: screenID)
        } else {
            for screen in render.outputs.placeholderScreens
            where render.outputs.role(forScreen: screen.id) == .confidence {
                setLayout(resolved, forScreen: screen.id)
            }
        }
    }

    func beginPreview(layoutID: String) {
        previewCounts[layoutID, default: 0] += 1
        if previewCounts[layoutID] == 1 {
            refresh()
        }
    }

    func endPreview(layoutID: String) {
        if let count = previewCounts[layoutID] {
            previewCounts[layoutID] = count > 1 ? count - 1 : nil
            if count == 1 {
                refresh()
            }
        }
    }

    func refresh() {
        var layouts: [UUID: ConfidenceLayout] = [:]
        var pruned = false
        upgradeMessageLayoutIfUntouched()
        for (screenID, layoutID) in assignments where layoutID != StageLayouts.audienceID {
            if let layout = appModel.resident.confidenceLayouts.value(layoutID) {
                layouts[screenID] = layout
            } else if appModel.client.isReady, appModel.indexEntry(layoutID) == nil {

                assignments.removeValue(forKey: screenID)
                pruned = true
            }
        }
        render.confidenceLayoutsBox.value = layouts
        let modeLayout = refreshStagePlan()
        var wants: [String: Bool?] = [:]
        for layout in layouts.values + [modeLayout].compactMap({ $0 }) {
            wants.merge(SlideSceneBuilder.mediaWants(for: layout.objects)) { first, _ in first }
        }
        controls?.setConfidenceMediaWants(wants)
        if pruned { persist() }
        refreshPreviews()
    }

    /// Copies the stage mode's layout (or the audience screen, for Mirror)
    /// to the render thread. Returns the mode's layout, if it has one.
    @discardableResult
    private func refreshStagePlan() -> ConfidenceLayout? {
        let setup = ShowSetup.shared
        let source: StageSource
        var modeLayout: ConfidenceLayout?
        switch setup.stageMode {
        case .mirror:
            source = .mirror
        case .worship, .message:
            let id = setup.stageLayoutOverride ?? StageLayouts.id(for: setup.stageMode)
            let layout = appModel.resident.confidenceLayouts.value(id) ?? StageLayouts.fallback(for: id)
            modeLayout = layout
            source = .layout(layout)
        }
        let audience = ShowTargets.mirrorSource(setup: setup, render: render)
            .map { render.outputs.previewProvider(for: $0) }
        let mirrored = Set(assignments.filter { $0.value == StageLayouts.audienceID }.keys)
        render.stageBox.value = StagePlan(source: source, audience: audience, mirroredScreens: mirrored)
        return modeLayout
    }

    private var checkedMessageLayout = false

    /// The Message layout got a new design (a big sermon timer over the
    /// clock). A saved copy still exactly as the old template made it takes
    /// the new design once; one anybody has changed is left as it is.
    private func upgradeMessageLayoutIfUntouched() {
        guard !checkedMessageLayout,
              let layout = appModel.resident.confidenceLayouts.value(StageLayouts.messageID)
        else { return }
        checkedMessageLayout = true
        guard ConfidenceLayoutTemplate.upgradedSermonObjects(for: layout) != nil else { return }
        DiagnosticsStore.shared.note("stage.messageLayout.upgraded", detail: layout.name)
        appModel.updateConfidenceLayout(StageLayouts.messageID) { layout in
            // Checked again on the document itself, in case it changed since.
            if let objects = ConfidenceLayoutTemplate.upgradedSermonObjects(for: layout) {
                layout.objects = objects
            }
        }
    }

    /// Re-plans when the audience screen (the one Mirror shows) changes.
    private func armStageWatch() {
        withObservationTracking {
            _ = ShowTargets.mirrorSource(setup: ShowSetup.shared, render: render)
            _ = render.outputs.screenRoles
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshStagePlan()
                self.armStageWatch()
            }
        }
    }

    private func refreshPreviews() {
        previewLayoutChoices = appModel.entries(of: .confidenceLayout)
            .map { .init(id: PreviewTargetLogic.layoutTarget($0.id), name: $0.name) }
        var previews: [String: ConfidenceLayout] = [:]
        for layoutID in previewCounts.keys {
            if let layout = appModel.resident.confidenceLayouts.value(layoutID) {
                previews[layoutID] = layout
            }
        }
        render.previewLayoutsBox.value = previews
        previewAspects = previews.mapValues {
            PreviewTargetLogic.aspect(canvasWidth: $0.canvasWidth, canvasHeight: $0.canvasHeight)
        }
        var wants: [String: Bool?] = [:]
        for layout in previews.values {
            wants.merge(SlideSceneBuilder.mediaWants(for: layout.objects)) { first, _ in first }
        }
        controls?.setPreviewMediaWants(wants)
    }

    private func restore() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.assignmentsKey)
            as? [String: String]
        else { return }
        for (key, layoutID) in stored {
            guard let screenID = UUID(uuidString: key) else { continue }
            assignments[screenID] = layoutID
        }
    }

    private func persist() {
        let stored = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.key.uuidString, $0.value) }
        )
        UserDefaults.standard.set(stored, forKey: Self.assignmentsKey)
    }

    private func armMutationWatch() {
        withObservationTracking {
            _ = appModel.version(of: .confidenceLayout)
            _ = appModel.fillVersion(of: .confidenceLayout)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.armMutationWatch()
            }
        }
    }
}

private struct ConfidenceMonitorKey: EnvironmentKey {
    static let defaultValue: ConfidenceMonitorController? = nil
}

extension EnvironmentValues {
    var confidenceMonitor: ConfidenceMonitorController? {
        get { self[ConfidenceMonitorKey.self] }
        set { self[ConfidenceMonitorKey.self] = newValue }
    }
}
