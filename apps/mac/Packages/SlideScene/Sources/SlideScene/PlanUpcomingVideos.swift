import PresenterCore

/// The videos the plan is about to play, for the players the app readies
/// ahead of time (PlanPreloader.readyUpcomingPlayers).
public enum PlanUpcomingVideos {
    /// One video the plan is about to play, and how.
    public struct Video: Hashable, Sendable {
        public var mediaID: String
        public var loop: Bool

        public init(mediaID: String, loop: Bool) {
            self.mediaID = mediaID
            self.loop = loop
        }
    }

    /// The videos of the item on screen and the `itemsAhead - 1` after it,
    /// or of the whole plan when `itemsAhead` is nil (the item on screen
    /// first, then on to the end, then the items before it, so the nearest
    /// come first when `limit` cuts the list short). Each with the loop it
    /// will be played with: a slide's own choice, else the video's; the
    /// countdown always once. A presentation brings its slides' backgrounds,
    /// its own and its slides' background fills, and the videos its slides'
    /// actions fire; any item brings the videos its own actions fire. The
    /// operator jumps around the plan, and a song further down started its
    /// background cold when only the next two items had players.
    public static func videos(
        items: [ServiceItem], liveIndex: Int?, limit: Int, itemsAhead: Int? = 3,
        deck: (String) -> Presentation?, media: (String) -> MediaItem?
    ) -> [Video] {
        let from = min(max(liveIndex ?? 0, 0), items.count)
        let ordered: [ServiceItem]
        if let itemsAhead {
            ordered = Array(items.dropFirst(from).prefix(itemsAhead))
        } else {
            ordered = Array(items[from...]) + Array(items[..<from])
        }
        var found: [Video] = []
        func add(_ id: String?, loops: Bool?, once: Bool = false) {
            guard let id, !id.isEmpty, found.count < limit,
                  let item = media(id), item.mediaKind == .video else { return }
            let video = Video(mediaID: id, loop: once ? false : loops ?? item.playsLooping)
            if !found.contains(video) { found.append(video) }
        }
        func addFired(_ actions: [SlideAction]?) {
            for action in actions ?? [] where action.kind == .fireMedia {
                add(action.mediaId, loops: nil)
            }
        }
        for item in ordered {
            switch item.itemKind {
            case .media:
                add(item.refId, loops: nil, once: item.isCountdown == true)
            case .presentation:
                guard let deck = deck(item.refId) else { continue }
                if let fill = deck.backgroundFill { add(fill.mediaId, loops: fill.loops) }
                for slide in deck.slides {
                    if let background = SlideSceneBuilder.effectiveBackground(
                        slide: slide, presentation: deck, arrangementId: item.arrangementId) {
                        add(background.mediaId, loops: background.loops)
                    }
                    if let fill = slide.backgroundFill { add(fill.mediaId, loops: fill.loops) }
                    addFired(slide.actions)
                }
            default:
                break
            }
            addFired(item.actions)
        }
        return found
    }
}
