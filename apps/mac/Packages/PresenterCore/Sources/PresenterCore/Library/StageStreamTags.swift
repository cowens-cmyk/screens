import Foundation

/// What a plan item (or one slide) does to the stage display and the
/// livestream, in a couple of words each, for the quiet tags on the plan.
/// It reads only the synced documents — the plan item, its presentation or
/// media item, the slide-building settings and themes — so the CMS's
/// browser editor works the same tags out from the same fields. The rules
/// are written down for it in docs/stage-stream-tags.md; change both
/// together.
///
/// Stage, first match wins:
/// 1. A header has no tags.
/// 2. `item.isPreService`, or the presentation is
///    `slideBuildingSettings.serviceDay.preServicePresentationId`:
///    "Before service".
/// 3. `presentation.stageLayoutId` (or, for a slide, `slide.stageLayoutId`)
///    set: "Own layout".
/// 4. A `setStageMode` action — in `item.actions`, then the type's actions
///    (`slideBuildingSettings.presentationTypeRules` for the presentation's
///    type), then the slide's `actions` (for an item, its first slide's) —
///    by `stageMode`: worship "Lyrics + chords", message "Message timer",
///    preService "Before service", mirror "Audience screen".
/// 5. A video that plays once: a media item with `mediaKind` video that
///    doesn't loop, or a presentation whose every slide's `background` is
///    such a video (a slide: its own background): "Video time left".
/// 6. Type (`presentation.category`, a song with none counts as Worship):
///    Sermon "Message timer", Worship "Lyrics + chords".
/// 7. The plan's last presentation item, not a Sermon: "Before service"
///    (its last slide puts the stage there).
/// 8. Otherwise "No change".
///
/// Livestream, assuming the operator's switch is on Lower Third (the
/// usual), first match wins:
/// 1. A header has no tags.
/// 2. A video that plays once (stage rule 5): "Full screen".
/// 3. A media item that is a picture, or a looping video: "No change".
/// 4. A `setStreamMode` action (same places as stage rule 4) by
///    `streamMode`: fullScreen "Full screen", off "Camera only" (both stay
///    for the rest of the service), auto falls through.
/// 5. Per slide, `slide.streamDesign`: a `mediaId` with mode design "Lower
///    third picture"; mode audience "Full screen"; mode clear "Camera
///    only"; mode design without a picture "Lower third". An item whose
///    slides all say the same takes it; slides that differ give "Varies by
///    slide"; slides with none fall through.
/// 6. `presentation.streamThemeId` set: "Lower third" (that theme's).
/// 7. The type's row in `slideBuildingSettings.typeScreens`
///    (`stream`: "audience" "Full screen", "clear" "Camera only", "design"
///    "Lower third", "series" "Series lower third" when the plan has a
///    `sermonThemeId`); "theme", no row, or "series" with no series fall to 8.
///    The Sermon type with no row counts as "series".
/// 8. The slide's theme (`slide.themeId`, else `presentation.themeId`):
///    `streamLowerThirdThemeId` set or any `streamDesigns` entry with mode
///    design: "Lyrics lower third" for Worship, else "Lower third"; any
///    entry with mode audience and none with design: "Full screen";
///    otherwise "Camera only".
public enum StageStreamTags {

    public struct Tags: Equatable, Sendable {
        public var stage: String
        public var stream: String

        public init(stage: String, stream: String) {
            self.stage = stage
            self.stream = stream
        }

        /// The longer wording for help text.
        public var help: String { "Stage display: \(stage). Livestream: \(stream)." }
    }

    public static let lyrics = "Lyrics + chords"
    public static let messageTimer = "Message timer"
    public static let beforeService = "Before service"
    public static let videoTimeLeft = "Video time left"
    public static let ownLayout = "Own layout"
    public static let audienceScreen = "Audience screen"
    public static let noChange = "No change"

    public static let fullScreen = "Full screen"
    public static let cameraOnly = "Camera only"
    public static let lowerThird = "Lower third"
    public static let lowerThirdPicture = "Lower third picture"
    public static let lyricsLowerThird = "Lyrics lower third"
    public static let seriesLowerThird = "Series lower third"
    public static let variesBySlide = "Varies by slide"

    /// What the tags need from the library.
    public struct Library {
        public var presentation: (String) -> Presentation?
        public var media: (String) -> MediaItem?
        public var theme: (String) -> Theme?
        public var settings: SlideBuildingSettings?

        public init(
            presentation: @escaping (String) -> Presentation?, media: @escaping (String) -> MediaItem?,
            theme: @escaping (String) -> Theme?, settings: SlideBuildingSettings?
        ) {
            self.presentation = presentation
            self.media = media
            self.theme = theme
            self.settings = settings
        }
    }

    /// A plan item's tags; nil for a header, or an item with nothing linked.
    public static func tags(for item: ServiceItem, in plan: Service, library: Library) -> Tags? {
        switch item.itemKind {
        case .media:
            guard let media = library.media(item.refId) else { return nil }
            if playsOnce(media, loops: nil) { return Tags(stage: videoTimeLeft, stream: fullScreen) }
            return Tags(stage: item.isPreService == true ? beforeService : noChange, stream: noChange)
        case .presentation:
            guard let presentation = library.presentation(item.refId) else { return nil }
            return Tags(
                stage: stage(item: item, slide: nil, presentation: presentation, plan: plan, library: library),
                stream: stream(item: item, slide: nil, presentation: presentation, plan: plan, library: library))
        default:
            return nil
        }
    }

    /// One slide's tags, where the slide decides for itself.
    public static func tags(
        for slide: Slide, of item: ServiceItem, in plan: Service, library: Library
    ) -> Tags? {
        guard item.itemKind == .presentation, let presentation = library.presentation(item.refId) else { return nil }
        return Tags(
            stage: stage(item: item, slide: slide, presentation: presentation, plan: plan, library: library),
            stream: stream(item: item, slide: slide, presentation: presentation, plan: plan, library: library))
    }

    // MARK: Stage

    static func stage(
        item: ServiceItem, slide: Slide?, presentation: Presentation, plan: Service, library: Library
    ) -> String {
        let preServiceID = library.settings?.serviceDay?.preServicePresentationId
        if item.isPreService == true || (preServiceID?.isEmpty == false && presentation.id == preServiceID) {
            return beforeService
        }
        if nonEmpty(slide?.stageLayoutId) || nonEmpty(presentation.stageLayoutId) { return ownLayout }
        if let mode = actions(item: item, slide: slide, presentation: presentation, library: library)
            .first(where: { $0.kind == .setStageMode })?.stageMode {
            switch mode {
            case "worship": return lyrics
            case "message": return messageTimer
            case "preService": return beforeService
            case "mirror": return audienceScreen
            default: break
            }
        }
        if videoOnly(slide: slide, presentation: presentation, library: library) { return videoTimeLeft }
        let category = PresentationTypes.category(of: presentation)
        if category == PresentationTypes.sermon { return messageTimer }
        if category == PresentationTypes.worship { return lyrics }
        if isLastPresentation(item, in: plan) { return beforeService }
        return noChange
    }

    // MARK: Livestream

    static func stream(
        item: ServiceItem, slide: Slide?, presentation: Presentation, plan: Service, library: Library
    ) -> String {
        if videoOnly(slide: slide, presentation: presentation, library: library) { return fullScreen }
        if let mode = actions(item: item, slide: slide, presentation: presentation, library: library)
            .first(where: { $0.kind == .setStreamMode && $0.streamMode != "auto" })?.streamMode {
            switch mode {
            case "fullScreen": return fullScreen
            case "off": return cameraOnly
            default: break
            }
        }
        let slides = slide.map { [$0] } ?? presentation.slides
        let own = slides.map { slideDesign($0.streamDesign) }
        if !own.isEmpty, own.allSatisfy({ $0 != nil }) {
            let distinct = Set(own.compactMap { $0 })
            return distinct.count == 1 ? distinct.first! : variesBySlide
        }
        let fallback = setUp(presentation: presentation, slides: slides, plan: plan, library: library)
        guard own.contains(where: { $0 != nil }) else { return fallback }
        let distinct = Set(own.map { $0 ?? fallback })
        return distinct.count == 1 ? distinct.first! : variesBySlide
    }

    /// The slide's own Livestream choice; nil when it has none.
    static func slideDesign(_ design: StreamDesign?) -> String? {
        guard let design else { return nil }
        if design.lowerThirdImageID != nil { return lowerThirdPicture }
        switch design.mode {
        case .audience: return fullScreen
        case .clear: return cameraOnly
        case .design: return lowerThird
        }
    }

    /// What was set up ahead of time: the presentation's Livestream theme,
    /// its type's row in Screens by Type, then the slides' theme.
    static func setUp(presentation: Presentation, slides: [Slide], plan: Service, library: Library) -> String {
        if nonEmpty(presentation.streamThemeId) { return lowerThird }
        let type = PresentationTypes.screensType(of: presentation)
        let row = library.settings?.screens(forType: type) ?? PresentationTypeScreens(category: type)
        switch row.livestream {
        case .audience: return fullScreen
        case .clear: return cameraOnly
        case .design: return lowerThird
        case .series where nonEmpty(plan.sermonThemeId): return seriesLowerThird
        case .series, .theme: break
        }
        let isWorship = PresentationTypes.category(of: presentation) == PresentationTypes.worship
        let themeIDs = Set(slides.map { nonEmpty($0.themeId) ? $0.themeId! : presentation.themeId })
        let looks = Set(themeIDs.map { id -> String in
            guard let theme = library.theme(id) else { return cameraOnly }
            let designs = theme.streamDesigns ?? []
            if nonEmpty(theme.streamLowerThirdThemeId) || designs.contains(where: { $0.mode == .design }) {
                return isWorship ? lyricsLowerThird : lowerThird
            }
            if designs.contains(where: { $0.mode == .audience }) { return fullScreen }
            return cameraOnly
        })
        return looks.count == 1 ? looks.first! : (looks.isEmpty ? cameraOnly : variesBySlide)
    }

    // MARK: Shared

    /// The item's own actions, its type's, then the slide's (an item's
    /// first slide's).
    static func actions(item: ServiceItem, slide: Slide?, presentation: Presentation, library: Library) -> [SlideAction] {
        (item.actions ?? [])
            + PresentationTypes.actions(for: presentation, rules: library.settings?.presentationTypeRules)
            + ((slide ?? presentation.slides.first)?.actions ?? [])
    }

    /// The slide (or every slide) is a video that plays once.
    static func videoOnly(slide: Slide?, presentation: Presentation, library: Library) -> Bool {
        let slides = slide.map { [$0] } ?? presentation.slides
        guard !slides.isEmpty else { return false }
        return slides.allSatisfy { slide in
            guard let background = slide.background, let media = library.media(background.mediaId) else { return false }
            return playsOnce(media, loops: background.loops)
        }
    }

    static func playsOnce(_ media: MediaItem, loops: Bool?) -> Bool {
        media.mediaKind == .video && !(loops ?? media.playsLooping)
    }

    static func isLastPresentation(_ item: ServiceItem, in plan: Service) -> Bool {
        plan.items.last { $0.itemKind == .presentation && !$0.isHidden }?.id == item.id
    }

    private static func nonEmpty(_ text: String?) -> Bool {
        text.map { !$0.isEmpty } ?? false
    }
}
