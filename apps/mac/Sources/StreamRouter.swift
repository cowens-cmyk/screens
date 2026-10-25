import Foundation
import Observation
import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene

/// What goes over the camera on the Livestream screen, in StreamPrecedence's
/// order: a playing video comes first (full screen while it plays, then
/// nothing over the camera until the next slide); then a choice made on the
/// live slide wins (its Full Screen takes over the
/// stream even when the switch is on Transparent, its Nothing clears the
/// stream even on Full Screen, and its lower-third picture goes over the
/// camera in place of the slide); then the Transparent · Lower Third · Full
/// Screen switch (ShowSetup.streamMode); then, on Lower Third, the
/// presentation's own Livestream theme, then its type's choice in Screens by
/// Type, then the theme's pick for the slide's category, then the theme's
/// lower-third theme, and otherwise the camera stays clear. Every other
/// screen carries every layer.
@MainActor
@Observable
final class StreamRouter {
    private let appModel: AppModel
    private let outputs: OutputManager

    private weak var controls: ServiceControls?

    /// The live slide and its theme, for Lower Third.
    private var liveTheme: Theme?
    private var liveSlide: Slide?
    /// The live presentation's row in Screens by Type.
    private var liveType: String?

    /// A video's temporary hold on the stream. Kept here, not in the switch,
    /// so the operator's saved Show Setup choice never changes.
    private(set) var video = StreamVideoOverride()

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
        ShowSetup.shared.onStreamModeChosen = { [weak self] in self?.video.modeChosen() }
        republishStream()
    }

    /// A theme edit can change the live slide's stream design.
    private func armThemeMutationWatch() {
        withObservationTracking {
            _ = appModel.version(of: .theme)
            // Screens by Type and the current series live in the church's
            // settings: a change there while a song is up shows at once.
            _ = appModel.slideBuilding
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
        var images: [String: String] = [:]
        let setup = ShowSetup.shared
        let stream = setup.streamTarget
        if !stream.isEmpty {
            let overlays: Set<String> = [LayerKind.overlays.rawValue, LayerKind.alerts.rawValue]
            let global: StreamPrecedence.GlobalMode = switch setup.streamMode {
            case .auto: .lowerThird
            case .fullScreen: .fullScreen
            case .off: .transparent
            }
            let choice: StreamChoice?
            switch StreamPrecedence.decide(
                global: global, design: liveSlide?.streamDesign, video: video.phase
            ) {
            case .nothing: choice = nil
            case .clear: choice = .clear
            case .audience: choice = .audience
            case .slideDesign: choice = slideChoice()
            case .themeRoute: choice = themeChoice()
            case .slideImage(let mediaID):
                // A picture that's left the library falls back to the
                // slide's Lower Third, its theme's.
                choice = appModel.media(mediaID) == nil ? themeChoice(lowerThirdOnly: true) : .image(mediaID: mediaID)
            }
            switch choice {
            case nil:
                routing[stream] = []
            case .clear:
                routing[stream] = overlays
            case .audience:
                break
            case .design(let key, let theme):
                routing[stream] = overlays.union([LayerKind.slide.rawValue])
                themeRouting[stream] = key
                overrides[key] = theme
            case .image(let mediaID):
                routing[stream] = overlays.union([LayerKind.slide.rawValue])
                themeRouting[stream] = Self.imageKey
                images[Self.imageKey] = mediaID
            }
        }
        outputs.setLayerRouting(routing)
        outputs.setSlideThemeRouting(themeRouting)
        controls?.setSlideThemeOverrides(overrides, images: images)
    }

    /// The stream's copy of the live scene with the slide's lower-third
    /// picture in place of the slide.
    private static let imageKey = "stream-slide-image"

    enum StreamChoice {
        case clear
        case audience
        case design(key: String, theme: Theme)
        case image(mediaID: String)
    }

    /// The design the live slide asked for. A slide that picked Lower Third
    /// without naming a design gets the lower third its presentation, type
    /// or theme would give it.
    private func slideChoice() -> StreamChoice {
        guard let own = liveSlide?.streamDesign else { return .clear }
        guard let themeID = own.themeId, !themeID.isEmpty else { return themeChoice(lowerThirdOnly: true) }
        guard let source = appModel.theme(themeID) else { return .clear }
        var scoped = source.scoped(toSlideID: own.slideId)
        if own.slideId != nil, var only = scoped.slides?.first, let name = liveSlide?.themeSlideName {
            only.name = name
            scoped.slides = [only]
        }
        return .design(key: "stream-slide:\(themeID)##\(own.slideId ?? "")", theme: scoped)
    }

    /// What the livestream shows for the live slide when nothing on the
    /// slide or the switch decided: the presentation's own Livestream theme,
    /// else its type's choice in Screens by Type, else the slide's theme.
    /// For a slide that asked for a lower third, Nothing and Full Screen set
    /// up ahead of time are passed over: the slide's own choice already beat
    /// them.
    private func themeChoice(lowerThirdOnly: Bool = false) -> StreamChoice {
        let decided = StreamPrecedence.source(
            presentationStreamThemeId: ShowSetup.shared.streamThemeOverride,
            type: liveTypeStream, seriesThemeId: seriesThemeID, lowerThirdOnly: lowerThirdOnly)
        switch decided.source {
        case .audience:
            return .audience
        case .clear:
            return .clear
        case .design(let themeID, let slideID):
            // A design that's left the library falls back to the slide's
            // theme rather than leaving the camera bare.
            guard let source = appModel.theme(themeID), source.hasSlide(id: slideID) else {
                return routed(through: liveTheme, lowerThirdOnly: lowerThirdOnly)
            }
            var scoped = source.scoped(toSlideID: slideID)
            if var only = scoped.slides?.first, let name = liveSlide?.themeSlideName, !name.isEmpty {
                only.name = name
                scoped.slides = [only]
            }
            return .design(key: "stream-type:\(themeID)##\(slideID)", theme: scoped)
        case .theme(let id):
            // Not read yet, or gone: the slide's theme until it arrives.
            guard let chosen = appModel.theme(id) else { return routed(through: liveTheme, lowerThirdOnly: lowerThirdOnly) }
            return routed(through: chosen, chosen: true, lowerThirdOnly: lowerThirdOnly)
        case .slideTheme:
            return routed(through: liveTheme, lowerThirdOnly: lowerThirdOnly)
        }
    }

    /// A theme's own livestream choices: the design picked for the slide's
    /// category in the theme editor, else the theme's lower-third theme. A
    /// theme picked to carry the stream (`chosen`) that was never set up for
    /// the livestream then falls to its own Lower Thirds designs, so a
    /// lower-thirds theme picked for a song or a type shows without being
    /// tied up in the theme editor first. One that was set up keeps its
    /// gaps: a series leaves its Title slide's camera clear on purpose.
    /// Otherwise the camera stays clear.
    private func routed(through theme: Theme?, chosen: Bool = false, lowerThirdOnly: Bool) -> StreamChoice {
        guard let theme else { return .clear }
        let category = liveSlide.flatMap { SlideSceneBuilder.themeSlide(for: $0, theme: theme)?.name } ?? ""
        if let pick = theme.streamDesigns?.first(where: { $0.category.caseInsensitiveCompare(category) == .orderedSame }),
           !lowerThirdOnly || pick.mode == .design {
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
        if chosen, (theme.streamDesigns ?? []).isEmpty, theme.hasSlideFolder(BasicTemplates.lowerThirds) {
            return .design(key: "stream-lower-third:\(theme.id)", theme: ThemeCategories.lowerThirds(of: theme))
        }
        return .clear
    }

    /// The live presentation's type's livestream choice. Before anything has
    /// gone live there's no type, and the theme decides as it always has.
    private var liveTypeStream: TypeStream {
        guard let liveType else { return .theme }
        return appModel.slideBuilding.screens(forType: liveType).livestream
    }

    /// The current plan's sermon series, else the church's current one.
    private var seriesThemeID: String? {
        let plan = appModel.currentServiceID.flatMap { appModel.resident.services.value($0) }
        return [plan?.sermonThemeId, appModel.slideBuilding.sermonThemeId]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Themes the live slide's stream could draw from, so one not yet read
    /// is fetched before it's needed.
    private func wantedThemeIDs(_ theme: Theme?, _ slide: Slide?) -> [String] {
        var ids = [theme?.streamLowerThirdThemeId, slide?.streamDesign?.themeId,
                   ShowSetup.shared.streamThemeOverride, seriesThemeID]
            + (theme?.streamDesigns ?? []).map(\.themeId)
        if case .design(let themeID, _) = liveTypeStream { ids.append(themeID) }
        return ids.compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// A presentation went live: its type picks its row in Screens by Type.
    /// Called before its first slide's noteLiveTheme.
    func presentationWentLive(_ presentation: Presentation) {
        liveType = PresentationTypes.screensType(of: presentation)
    }

    /// The operator changed a slide's livestream choice. When that slide is
    /// live the stream follows now, not at the next fire, since taking over
    /// the stream from the live slide's menu is the point.
    func noteStreamDesign(_ design: StreamDesign?, forSlides slideIDs: Set<String>) {
        guard let id = liveSlide?.id, slideIDs.contains(id) else { return }
        liveSlide?.streamDesign = design
        noteLiveTheme(liveTheme, slide: liveSlide, wentLive: false)
    }

    /// A video that plays once went up on the audience screen.
    func videoStarted(_ mediaID: String) {
        video.videoStarted(mediaID)
        republishStream()
    }

    /// That video ended, was held on its last frame, cleared or replaced.
    func videoEnded(_ mediaID: String) {
        let before = video
        video.videoEnded(mediaID)
        if video != before { republishStream() }
    }

    /// Called as each slide goes live, so Lower Third follows the slide's
    /// theme. A slide going live also ends a video's hold on the stream; a
    /// change to the live slide's own choice (`wentLive` false) doesn't.
    func noteLiveTheme(_ theme: Theme?, slide: Slide? = nil, wentLive: Bool = true) {
        if wentLive { video.slideWentLive() }
        liveTheme = theme
        liveSlide = slide
        let needed = wantedThemeIDs(theme, slide).filter { appModel.theme($0) == nil }
        if !needed.isEmpty {
            Task { @MainActor [weak self] in
                await self?.appModel.themesFilled(needed)
                self?.republishStream()
            }
        }
        republishStream()
    }
}
