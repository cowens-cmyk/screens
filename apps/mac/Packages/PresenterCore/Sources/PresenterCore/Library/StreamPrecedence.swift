import Foundation

/// Who decides what the livestream shows for the live slide. A playing
/// video comes first. Then a choice made on the slide itself (right-click ›
/// Livestream, or the Screens sheet) is the operator asking for exactly
/// that, so it beats the Show Setup switch. Full Screen and Transparent on
/// the switch are the operator too, so they beat everything set up ahead
/// of time. On Lower Third the look comes from, in order: the
/// presentation's own Livestream theme, its type's choice in Screens by
/// Type, then the slide's theme's routing table (see `source`).
public enum StreamPrecedence {

    /// The Show Setup switch (Lower Third · Full Screen · Transparent).
    public enum GlobalMode: Sendable {
        case lowerThird, fullScreen, transparent
    }

    public enum Decision: Equatable, Sendable {
        /// Not even overlays or alerts: Transparent with nothing asked for.
        case nothing
        /// The camera, with overlays and alerts still on top.
        case clear
        /// Whatever the room sees, edge to edge.
        case audience
        /// The slide's own design, or its theme's lower third when the slide
        /// asked for a lower third without naming one.
        case slideDesign
        /// Set up ahead of time: the presentation, its type, then the theme.
        case themeRoute
        /// The slide's own lower-third picture (a PNG over the camera).
        case slideImage(mediaID: String)
    }

    public static func decide(global: GlobalMode, slide: StreamDesignMode?) -> Decision {
        switch slide {
        case .audience:
            return .audience
        case .clear:
            // Transparent already shows less than a clear camera; asking
            // for nothing never brings the overlays back.
            return global == .transparent ? .nothing : .clear
        case .design:
            return .slideDesign
        case nil:
            switch global {
            case .lowerThird: return .themeRoute
            case .fullScreen: return .audience
            case .transparent: return .nothing
            }
        }
    }

    /// As above, for the slide's whole choice: a Lower Third that names a
    /// picture shows that picture. It stands where the slide's Lower Third
    /// stands, so it beats the switch the same way.
    public static func decide(global: GlobalMode, design: StreamDesign?) -> Decision {
        if let mediaID = design?.lowerThirdImageID { return .slideImage(mediaID: mediaID) }
        return decide(global: global, slide: design?.mode)
    }
}

extension StreamDesign {
    /// A slide's lower-third picture. Stored as a Lower Third with a media id
    /// rather than as a mode of its own: a build that predates the picture
    /// reads it as the theme's lower third instead of failing on an unknown
    /// mode and dropping the whole presentation.
    public static func lowerThirdImage(_ mediaID: String) -> StreamDesign {
        StreamDesign(category: "", mode: .design, mediaId: mediaID)
    }

    /// The picture this choice puts over the camera, if it names one.
    public var lowerThirdImageID: String? {
        guard mode == .design, let mediaId, !mediaId.isEmpty else { return nil }
        return mediaId
    }
}

extension StreamPrecedence {

    /// Where a video media item stands on the audience screen.
    public enum Video: Equatable, Sendable {
        /// No video, or a slide has gone live since the last one.
        case none
        /// A video that plays once is on the audience screen.
        case playing
        /// It ended, was held on its last frame, cleared or replaced.
        case over
    }

    /// A video beats everything else: while it plays the livestream carries
    /// it full screen, whatever the switch or the slide says. Once it's over
    /// nothing goes over the camera (a held last frame or a fade to black
    /// must never sit on the stream) until a slide goes live and the usual
    /// rules take over again.
    public static func decide(global: GlobalMode, slide: StreamDesignMode?, video: Video) -> Decision {
        switch video {
        case .playing: .audience
        case .over: .nothing
        case .none: decide(global: global, slide: slide)
        }
    }

    public static func decide(global: GlobalMode, design: StreamDesign?, video: Video) -> Decision {
        switch video {
        case .playing: .audience
        case .over: .nothing
        case .none: decide(global: global, design: design)
        }
    }
}

/// The livestream's temporary hold for a video, kept apart from the Show
/// Setup switch so the operator's saved choice is never changed.
public struct StreamVideoOverride: Equatable, Sendable {
    /// The video playing now, if any.
    public private(set) var videoID: String?
    /// A video ended and no slide has gone live since.
    public private(set) var cleared = false

    public init() {}

    public var phase: StreamPrecedence.Video {
        if videoID != nil { return .playing }
        return cleared ? .over : .none
    }

    public mutating func videoStarted(_ id: String) {
        videoID = id
        cleared = false
    }

    /// Only the video that's playing can end the hold: one that was
    /// replaced (or followed by a slide) has nothing left to say.
    public mutating func videoEnded(_ id: String) {
        guard videoID == id else { return }
        videoID = nil
        cleared = true
    }

    /// A slide went live: its own livestream choice, or the switch, decides.
    public mutating func slideWentLive() {
        videoID = nil
        cleared = false
    }

    /// The operator (or an action) picked a livestream mode: that wins.
    public mutating func modeChosen() {
        videoID = nil
        cleared = false
    }
}

extension StreamPrecedence {

    /// The plan a newly live slide was fired from, so the Message's series
    /// lower third stays with the service on screen while the operator looks
    /// ahead at next week's plan. More of the item already live (its own
    /// timing, the remote) stays with its plan; a new item belongs to the
    /// plan being viewed if it's in it, else to the plan that was live. A
    /// slide fired from the library belongs to no plan.
    public static func firedPlan(
        item: String?, previousItem: String?, previousPlan: String?, currentPlan: String?,
        holds: (_ plan: String, _ item: String) -> Bool
    ) -> String? {
        if let item {
            if item == previousItem, let previousPlan, holds(previousPlan, item) {
                previousPlan
            } else if let currentPlan, holds(currentPlan, item) {
                currentPlan
            } else if let previousPlan, holds(previousPlan, item) {
                previousPlan
            } else {
                nil
            }
        } else {
            nil
        }
    }
}

extension Theme {
    /// The other themes this theme's livestream choices draw on: the design
    /// picked for each category and its lower-third theme. A theme chosen to
    /// carry the stream needs these read too, or its lower third stays clear.
    public var streamThemeReferences: [String] {
        ([streamLowerThirdThemeId] + (streamDesigns ?? []).map(\.themeId))
            .compactMap { $0 }.filter { !$0.isEmpty }
    }
}
