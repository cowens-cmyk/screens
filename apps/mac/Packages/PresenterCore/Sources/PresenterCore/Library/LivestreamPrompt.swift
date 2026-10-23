import Foundation

/// "What do you want on the livestream?" — asked when pictures or videos
/// are added as new slides. An announcement is a full-screen picture in the
/// room, which is rarely what the camera should carry, so the question comes
/// when the slide is made rather than when it's live.
public enum LivestreamPrompt {

    public enum Choice: Equatable, Sendable {
        /// A picture over the camera (a PNG with transparency).
        case lowerThirdImage(mediaID: String)
        /// The room's screen, edge to edge.
        case fullScreen
        /// The camera alone.
        case nothing
        /// No choice on the slide: the theme and the Show Setup switch decide.
        case themeDefault
    }

    /// The slide's livestream choice for an answer.
    public static func design(for choice: Choice) -> StreamDesign? {
        switch choice {
        case .lowerThirdImage(let mediaID): .lowerThirdImage(mediaID)
        case .fullScreen: StreamDesign(category: "", mode: .audience)
        case .nothing: StreamDesign(category: "", mode: .clear)
        case .themeDefault: nil
        }
    }

    /// The added slides the question is about, in order: those whose picture
    /// is a picture or video from the library and that have no livestream
    /// choice yet. Lyrics and other text slides never ask, nor does a deck
    /// whose operator said not to.
    public static func slidesToAsk(
        added: [Slide], skipped: Bool, mediaKind: (String) -> MediaKind?
    ) -> [String] {
        guard !skipped else { return [] }
        return added.filter { slide in
            guard slide.streamDesign == nil,
                  let mediaID = slide.background?.mediaId, !mediaID.isEmpty,
                  mediaKind(mediaID) != nil
            else { return false }
            return !slide.objects.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }.map(\.id)
    }
}
