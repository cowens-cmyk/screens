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

    /// The videos of the item on screen and the two after it, in order,
    /// each with the loop it will be played with (a slide's own choice, else
    /// the video's; the countdown always once), at most `limit`.
    public static func videos(
        items: [ServiceItem], liveIndex: Int?, limit: Int,
        deck: (String) -> Presentation?, media: (String) -> MediaItem?
    ) -> [Video] {
        let from = max(liveIndex ?? 0, 0)
        var found: [Video] = []
        func add(_ id: String, loops: Bool?, once: Bool = false) {
            guard found.count < limit, let item = media(id), item.mediaKind == .video else { return }
            let video = Video(mediaID: id, loop: once ? false : loops ?? item.playsLooping)
            if !found.contains(video) { found.append(video) }
        }
        for item in items.dropFirst(from).prefix(3) {
            switch item.itemKind {
            case .media:
                add(item.refId, loops: nil, once: item.isCountdown == true)
            case .presentation:
                guard let deck = deck(item.refId) else { continue }
                for slide in deck.slides {
                    if let background = SlideSceneBuilder.effectiveBackground(
                        slide: slide, presentation: deck, arrangementId: item.arrangementId) {
                        add(background.mediaId, loops: background.loops)
                    }
                }
            default:
                break
            }
        }
        return found
    }
}
