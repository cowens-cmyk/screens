import Foundation

/// Slides ask their theme for a design by category ("Bible", "Sermon
/// Points", "Lyrics"). Themes name designs their own way — the starter themes
/// call scripture "Verse + Reference" and points "Point" — so a category also
/// matches its usual names.
public enum ThemeCategories {

    static let aliases: [String: [String]] = [
        "bible": ["scripture", "verse + reference", "verse", "verse and reference"],
        "scripture": ["bible", "verse + reference", "verse"],
        "sermon points": ["point", "points", "sermon point"],
        "points": ["point", "sermon points"],
        "point": ["points", "sermon points"],
        "announcements": ["call to action", "announcement"],
        // A sermon series names its lyrics design Worship.
        "lyrics": ["lyric", "song", "worship"],
        "worship": ["lyrics", "lyric", "song"],
        "title": ["message title", "sermon title"],
        "point + scripture": ["point and scripture", "point + verse"],
    ]

    static let lowerThirdSuffixes = [" (lower third)", " lower third"]

    /// The design for a category, by exact name then by its usual names.
    public static func match(_ category: String, in slides: [Slide]) -> Slide? {
        let wanted = category.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = slides.first(where: { $0.name.lowercased() == wanted }) { return exact }
        for alias in aliases[wanted] ?? [] {
            if let hit = slides.first(where: { $0.name.lowercased() == alias }) { return hit }
        }
        return nil
    }

    /// The theme as the livestream should draw it: only its Lower Thirds
    /// designs when it has some, named as categories ("Verse + Reference
    /// (Lower Third)" answers to Bible), with the plain "Lower Third" design
    /// first so anything unmatched still lands in a lower third.
    public static func lowerThirds(of theme: Theme) -> Theme {
        let all = theme.slides ?? []
        let folder = all.filter { ($0.folder ?? "").caseInsensitiveCompare("Lower Thirds") == .orderedSame }
        guard !folder.isEmpty else { return theme }
        var designs = folder.map { slide -> Slide in
            var slide = slide
            let lowered = slide.name.lowercased()
            for suffix in lowerThirdSuffixes where lowered.hasSuffix(suffix) {
                slide.name = String(slide.name.dropLast(suffix.count))
                break
            }
            return slide
        }
        if let index = designs.firstIndex(where: { $0.name.caseInsensitiveCompare("Lower Third") == .orderedSame }) {
            designs.insert(designs.remove(at: index), at: 0)
        }
        var scoped = theme
        scoped.slides = designs
        return scoped
    }
}
