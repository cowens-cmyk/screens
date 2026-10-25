import Foundation

/// Screens by Type: one church-wide answer, per presentation type, to "what
/// goes on the livestream during worship (the message, scripture…)", so a
/// lower third is chosen once and every song of that type carries it
/// instead of each song or theme being set up on its own.
public extension PresentationTypes {
    /// Anything that isn't one of the four named types: no type, Video, or a
    /// type someone typed in.
    static let other = "Other"

    /// The rows of Screens by Type, in service order.
    static let screensTypes = [worship, sermon, bible, announcements, other]

    /// The row a presentation falls under. Songs count as Worship.
    static func screensType(of presentation: Presentation) -> String {
        screensType(category: category(of: presentation))
    }

    static func screensType(category: String?) -> String {
        guard let category, !category.isEmpty else { return other }
        return [worship, sermon, bible, announcements]
            .first { $0.caseInsensitiveCompare(category) == .orderedSame } ?? other
    }

    /// How the type reads to people: the message and scripture are what the
    /// church calls them, not the stored names.
    static func screensTitle(_ type: String) -> String {
        switch type {
        case sermon: "Message"
        case bible: "Scripture"
        default: type
        }
    }
}

/// What the livestream shows for a type, when the presentation and the slide
/// leave it open.
public enum TypeStream: Equatable, Hashable, Sendable {
    /// Each slide's theme decides (its "Where It Goes" table).
    case theme
    /// The plan's sermon series decides, by the slide's category.
    case series
    /// The room's slide, edge to edge.
    case audience
    /// Nothing over the camera.
    case clear
    /// One design (`slideId`), or with no design named, the theme's own
    /// livestream choices — its lower thirds by category.
    case design(themeId: String, slideId: String?)

    /// The Message follows the plan's series unless told otherwise; every
    /// other type leaves it to each theme, which is how it worked before
    /// types had a say.
    public static func standard(for type: String) -> TypeStream {
        type == PresentationTypes.sermon ? .series : .theme
    }

    /// Stored as a plain string rather than a schema enum: a build that
    /// doesn't know a newer choice reads it as the type's default instead
    /// of failing to open the church's settings.
    var stored: String {
        switch self {
        case .theme: "theme"
        case .series: "series"
        case .audience: "audience"
        case .clear: "clear"
        case .design: "design"
        }
    }
}

public extension PresentationTypeScreens {
    /// The livestream choice, with the type's default where none is stored.
    var livestream: TypeStream {
        get {
            switch stream {
            case "theme": return .theme
            case "series": return .series
            case "audience": return .audience
            case "clear": return .clear
            case "design":
                guard let themeId = streamThemeId, !themeId.isEmpty else { break }
                return .design(themeId: themeId, slideId: streamSlideId.flatMap { $0.isEmpty ? nil : $0 })
            default: break
            }
            return .standard(for: category)
        }
        set {
            // The default is stored as no choice, so a church that never
            // touches a row keeps following any later change of default.
            if newValue == .standard(for: category) {
                stream = nil
                streamThemeId = nil
                streamSlideId = nil
                return
            }
            stream = newValue.stored
            if case .design(let themeId, let slideId) = newValue {
                streamThemeId = themeId
                streamSlideId = slideId
            } else {
                streamThemeId = nil
                streamSlideId = nil
            }
        }
    }

    var isEmpty: Bool { stream == nil }
}

public extension SlideBuildingSettings {
    /// A type's row, or an empty one when nothing is set for it.
    func screens(forType type: String) -> PresentationTypeScreens {
        typeScreens?.first { $0.category.caseInsensitiveCompare(type) == .orderedSame }
            ?? PresentationTypeScreens(category: type)
    }

    /// The livestream choice for a presentation's type.
    func livestream(for presentation: Presentation) -> TypeStream {
        screens(forType: PresentationTypes.screensType(of: presentation)).livestream
    }

    /// Changes one type's row. A row left with nothing set is dropped, and
    /// the list with it when it's empty, so an untouched church stores
    /// nothing.
    mutating func updateScreens(forType type: String, _ edit: (inout PresentationTypeScreens) -> Void) {
        var rows = typeScreens ?? []
        var row = screens(forType: type)
        edit(&row)
        rows.removeAll { $0.category.caseInsensitiveCompare(type) == .orderedSame }
        if !row.isEmpty { rows.append(row) }
        typeScreens = rows.isEmpty ? nil : rows
    }
}

extension StreamPrecedence {

    /// Where the livestream's look comes from once the switch is on Lower
    /// Third and the slide has no choice of its own (or asked for a Lower
    /// Third without naming one). In order: the presentation's own
    /// Livestream theme, then its type's choice in Screens by Type, then the
    /// slide's own theme.
    public enum Source: Equatable, Sendable {
        /// The slide's own theme's livestream choices.
        case slideTheme
        /// Another theme's livestream choices: the presentation's own
        /// Livestream theme, the series, or a theme picked for the type. A
        /// theme someone picked to carry the stream shows its own lower
        /// thirds even when they were never tied up in its theme editor.
        case theme(id: String)
        /// One design over the camera.
        case design(themeId: String, slideId: String)
        case audience
        case clear
    }

    /// Who decided, for "where it comes from" wording in the editors.
    public enum SourceOrigin: Equatable, Sendable {
        case presentation, type, slideTheme
    }

    /// `lowerThirdOnly` is for a slide that asked for a Lower Third: a
    /// type's Full Screen or Nothing would undo what the slide asked for, so
    /// they're passed over for the slide's theme, the same way the theme's
    /// own Full Screen and Nothing picks are.
    public static func source(
        presentationStreamThemeId: String?, type: TypeStream, seriesThemeId: String?,
        lowerThirdOnly: Bool = false
    ) -> (source: Source, origin: SourceOrigin) {
        if let own = presentationStreamThemeId, !own.isEmpty {
            return (.theme(id: own), .presentation)
        }
        switch type {
        case .theme:
            return (.slideTheme, .slideTheme)
        case .series:
            // No series for this plan: the slide's theme still has a say.
            guard let series = seriesThemeId, !series.isEmpty else { return (.slideTheme, .slideTheme) }
            return (.theme(id: series), .type)
        case .audience:
            return lowerThirdOnly ? (.slideTheme, .slideTheme) : (.audience, .type)
        case .clear:
            return lowerThirdOnly ? (.slideTheme, .slideTheme) : (.clear, .type)
        case .design(let themeId, let slideId):
            guard let slideId else { return (.theme(id: themeId), .type) }
            return (.design(themeId: themeId, slideId: slideId), .type)
        }
    }
}
