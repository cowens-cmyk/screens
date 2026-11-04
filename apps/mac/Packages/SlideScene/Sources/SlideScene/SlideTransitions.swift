import PresenterCore
import RenderEngine

/// How a slide change moves on the screens.
public enum SlideTransitions {
    /// A stored transition as the screens run it: nil when none is set, and
    /// a cut for Cut or one too short to see.
    public static func scene(from transition: Transition?) -> SceneTransition? {
        guard let transition else { return nil }
        let duration = transition.durationSeconds ?? 0.5

        guard duration >= 0.05 else { return .cut }
        switch transition.transitionKind {
        case .cut: return .cut
        case .dissolve: return SceneTransition(kind: .dissolve, duration: duration)
        case .fadeBlack: return SceneTransition(kind: .fade(.black), duration: duration)
        case .fadeWhite: return SceneTransition(kind: .fade(.white), duration: duration)
        case .fadeColor:
            let plate = transition.colorHex.flatMap { ColorHex.color($0) } ?? .black
            return SceneTransition(kind: .fade(plate), duration: duration)
        case .blurDissolve: return SceneTransition(kind: .blurDissolve, duration: duration)
        case .filmBurn: return SceneTransition(kind: .filmBurn, duration: duration)
        }
    }

    /// The media layers a slide fire changed, each with the slide's
    /// transition. A slide made from a video or picture is that media on a
    /// media layer with nothing on the slide layer, so the slide transition
    /// has to travel with the media it puts up or takes down, or the slide
    /// changes with the media transition (or a cut) whatever the slide or
    /// the room is set to. A background a song slide brings moves with it
    /// the same way.
    public static func carried(
        _ transition: SceneTransition?,
        from before: [LayerKind: CueMedia], to after: [LayerKind: CueMedia]
    ) -> [LayerKind: SceneTransition] {
        guard let transition else { return [:] }
        var carried: [LayerKind: SceneTransition] = [:]
        for layer in [LayerKind.loopingVideos, .stillGraphics, .videos]
        where before[layer]?.mediaId != after[layer]?.mediaId {
            carried[layer] = transition
        }
        return carried
    }
}
