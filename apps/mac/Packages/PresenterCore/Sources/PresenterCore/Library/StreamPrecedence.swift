import Foundation

/// Who decides what the livestream shows for the live slide. A choice made
/// on the slide itself (right-click › Livestream, or the Screens sheet) is
/// the operator asking for exactly that, so it beats the Show Setup switch;
/// the switch beats the theme; the theme's routing table only speaks when
/// the switch is on Lower Third and the slide has no choice of its own.
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
        /// The theme's pick for the slide's category.
        case themeRoute
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
}
