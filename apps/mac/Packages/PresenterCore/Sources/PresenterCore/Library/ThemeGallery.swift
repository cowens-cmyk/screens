import Foundation

/// The Theme gallery (the top bar's Theme button): every theme as a
/// thumbnail, wide themes by what they're for (Worship, Message, Misc) and
/// the lower-third themes on their own, each wide theme showing the lower
/// third it is paired with for the livestream.
public enum ThemeGallery {
    public enum Group: String, CaseIterable, Sendable {
        case worship, message, misc, lowerThirds

        public var title: String {
            switch self {
            case .worship: "Worship"
            case .message: "Message"
            case .misc: "Misc"
            case .lowerThirds: "Lower Thirds"
            }
        }

        public var isWide: Bool { self != .lowerThirds }
    }

    /// A design for the livestream's lower third, not the room's screens.
    public static func isLowerThirdDesign(_ slide: Slide) -> Bool {
        (slide.folder ?? "").range(of: "third", options: .caseInsensitive) != nil
    }

    /// The design a theme's thumbnail shows: its first full-screen design,
    /// or for a lower-third theme its first lower third.
    public static func coverDesign(of theme: Theme) -> Slide? {
        let designs = theme.slides ?? []
        if group(of: theme) == .lowerThirds { return designs.first(where: isLowerThirdDesign) ?? designs.first }
        return designs.first { !isLowerThirdDesign($0) } ?? designs.first
    }

    /// Where a theme sits: where someone put it, else a series theme is
    /// Message, a theme with only lower thirds (or named for them) is Lower
    /// Thirds, the lyrics theme or one named for worship is Worship, and
    /// everything else is Misc.
    public static func group(of theme: Theme, worshipThemeId: String? = nil) -> Group {
        if let chosen = theme.galleryGroup.flatMap(Group.init(rawValue:)) { return chosen }
        let name = theme.name.lowercased()
        let designs = theme.slides ?? []
        if name.contains("lower third") || name.contains("lowerthird")
            || (!designs.isEmpty && designs.allSatisfy(isLowerThirdDesign)) {
            return .lowerThirds
        }
        if theme.isSermonSeries == true { return .message }
        if theme.id == worshipThemeId || ["worship", "lyrics", "song"].contains(where: name.contains) {
            return .worship
        }
        return .misc
    }

    /// The themes in each group, by name.
    public static func grouped(_ themes: [Theme], worshipThemeId: String? = nil) -> [(group: Group, themes: [Theme])] {
        Group.allCases.compactMap { group in
            let inGroup = themes.filter { self.group(of: $0, worshipThemeId: worshipThemeId) == group }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }
}
