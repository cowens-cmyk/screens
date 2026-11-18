import Foundation

/// A song slide's look made into the worship theme (right-click a song's
/// slide › Make This the Worship Theme…), so every new song, on a Sunday or
/// a Wednesday, is built in it and it can be changed in Theme Editor.
///
/// A slide that already follows a theme just makes that theme the lyrics
/// theme. A slide with its own look (a ProPresenter import, say) becomes a
/// theme of one design, "Lyrics": how its words are shown (their box, font,
/// size and color), with the words kept as sample text and the chords left
/// off. The background isn't part of it: each song keeps its own.
public enum WorshipThemeFromSlide {
    public static let designID = "lyrics"
    public static let defaultName = "Hope Worship"

    /// The theme the slide already follows, if any.
    public static func followedTheme(of slide: Slide, in presentation: Presentation) -> String? {
        let id = presentation.themeId(for: slide)
        return id.isEmpty ? nil : id
    }

    /// A theme drawn from the slide's text boxes alone.
    public static func theme(from slide: Slide, in presentation: Presentation, id: String, name: String = defaultName) -> Theme {
        // Songs ask for the "Lyrics" design and put their words in its
        // "Lyrics" box: the slide's first text box is that box.
        let wordsID = slide.objects.first { $0.objectKind == .text }?.id
        let design = Slide(id: designID, name: "Lyrics", objects: slide.objects.filter { $0.objectKind == .text }.map { object in
            var copy = object
            copy.chords = nil
            if copy.id == wordsID { copy.name = "Lyrics" }
            return copy
        })
        let words = slide.objects.first { $0.objectKind == .text }?.textStyle
        return Theme(
            id: id, name: name,
            fontFamily: words?.fontName ?? "Montserrat",
            fontSize: words?.fontSize ?? 72,
            textColorHex: words?.colorHex ?? "#FFFFFFFF",
            backgroundColorHex: "#000000FF",
            slides: [design])
    }
}
