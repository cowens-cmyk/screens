import Foundation
import Observation
import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene

/// What goes over the camera on the Livestream screen. The Transparent ·
/// Lower Third · Full Screen switch (ShowSetup.streamMode) picks the rule; in
/// Lower Third, the live slide's own stream design wins, then its theme's
/// pick for the slide's category, then the theme's lower-third theme, and
/// otherwise the camera stays clear. Every other screen carries every layer.
@MainActor
@Observable
final class StreamRouter {
    private let appModel: AppModel
    private let outputs: OutputManager

    private weak var controls: ServiceControls?

    /// The live slide and its theme, for Lower Third.
    private var liveTheme: Theme?
    private var liveSlide: Slide?

    /// Looks (output presets) were taken out of the app. A Look left active
    /// from before would otherwise route screens nobody can see any more.
    private static let retiredActiveLookKey = "activeOutputPresetID"

    init(appModel: AppModel, outputs: OutputManager, controls: ServiceControls? = nil) {
        self.appModel = appModel
        self.outputs = outputs
        self.controls = controls
        UserDefaults.standard.removeObject(forKey: Self.retiredActiveLookKey)
        for screen in outputs.placeholderScreens {
            outputs.setActiveMaskIDs([], forScreen: screen.id)
        }
        armThemeMutationWatch()
        ShowSetup.shared.onChange = { [weak self] in self?.republishStream() }
        republishStream()
    }

    /// A theme edit can change the live slide's stream design.
    private func armThemeMutationWatch() {
        withObservationTracking {
            _ = appModel.version(of: .theme)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.republishStream()
                self.armThemeMutationWatch()
            }
        }
    }

    func republishStream() {
        var routing: [String: Set<String>] = [:]
        var themeRouting: [String: String] = [:]
        var overrides: [String: Theme] = [:]
        let setup = ShowSetup.shared
        let stream = setup.streamTarget
        if !stream.isEmpty {
            let overlays: Set<String> = [LayerKind.overlays.rawValue, LayerKind.alerts.rawValue]
            switch setup.streamMode {
            case .fullScreen:
                break
            case .off:
                routing[stream] = []
            case .auto:
                switch streamChoice() {
                case .clear:
                    routing[stream] = overlays
                case .audience:
                    break
                case .design(let key, let theme):
                    routing[stream] = overlays.union([LayerKind.slide.rawValue])
                    themeRouting[stream] = key
                    overrides[key] = theme
                }
            }
        }
        outputs.setLayerRouting(routing)
        outputs.setSlideThemeRouting(themeRouting)
        controls?.setSlideThemeOverrides(overrides)
    }

    enum StreamChoice {
        case clear
        case audience
        case design(key: String, theme: Theme)
    }

    /// What the livestream shows for the live slide, from its theme: the
    /// design picked for its category in the theme editor, else the theme's
    /// lower-third theme, else a clear camera.
    private func streamChoice() -> StreamChoice {
        // A choice made on the slide itself wins over the theme's.
        if let own = liveSlide?.streamDesign {
            switch own.mode {
            case .clear: return .clear
            case .audience: return .audience
            case .design:
                if let themeID = own.themeId, let source = appModel.theme(themeID) {
                    var scoped = source.scoped(toSlideID: own.slideId)
                    if own.slideId != nil, var only = scoped.slides?.first, let name = liveSlide?.themeSlideName {
                        only.name = name
                        scoped.slides = [only]
                    }
                    return .design(key: "stream-slide:\(themeID)##\(own.slideId ?? "")", theme: scoped)
                }
            }
        }
        let override = ShowSetup.shared.streamThemeOverride.flatMap { appModel.theme($0) }
        guard let theme = override ?? liveTheme else { return .clear }
        let category = liveSlide.flatMap { SlideSceneBuilder.themeSlide(for: $0, theme: theme)?.name } ?? ""
        if let pick = theme.streamDesigns?.first(where: { $0.category.caseInsensitiveCompare(category) == .orderedSame }) {
            switch pick.mode {
            case .clear:
                return .clear
            case .audience:
                return .audience
            case .design:
                guard let themeID = pick.themeId, let source = appModel.theme(themeID) else { return .clear }
                var scoped = source.scoped(toSlideID: pick.slideId)
                // The picked design answers to this category's name.
                if pick.slideId != nil, var only = scoped.slides?.first {
                    only.name = category
                    scoped.slides = [only]
                }
                return .design(key: "stream-design:\(themeID)##\(pick.slideId ?? "")", theme: scoped)
            }
        }
        if let lowerThirdID = theme.streamLowerThirdThemeId, !lowerThirdID.isEmpty,
           let lowerThird = appModel.theme(lowerThirdID) {
            return .design(key: "stream-lower-third:\(lowerThirdID)", theme: ThemeCategories.lowerThirds(of: lowerThird))
        }
        return .clear
    }

    /// Called as each slide goes live, so Lower Third follows the slide's theme.
    func noteLiveTheme(_ theme: Theme?, slide: Slide? = nil) {
        liveTheme = theme
        liveSlide = slide
        let needed = ([theme?.streamLowerThirdThemeId, slide?.streamDesign?.themeId] + (theme?.streamDesigns ?? []).map(\.themeId))
            .compactMap { $0 }.filter { !$0.isEmpty && appModel.theme($0) == nil }
        if !needed.isEmpty {
            Task { @MainActor [weak self] in
                await self?.appModel.themesFilled(needed)
                self?.republishStream()
            }
        }
        republishStream()
    }
}
