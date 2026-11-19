import Testing
@testable import PresenterCore

@Suite struct ThemeGalleryTests {
    private func theme(_ id: String, _ name: String, designs: [(String, String?)] = [("Title", nil)],
                       series: Bool? = nil, group: String? = nil) -> Theme {
        var theme = Theme(
            id: id, name: name, fontFamily: "", fontSize: 40, textColorHex: "", backgroundColorHex: "",
            slides: designs.map { Slide(id: id + $0.0, name: $0.0, objects: [], folder: $0.1) },
            isSermonSeries: series)
        theme.galleryGroup = group
        return theme
    }

    @Test func themesFallIntoTheirGroups() {
        #expect(ThemeGallery.group(of: theme("a", "God's Promise", series: true)) == .message)
        #expect(ThemeGallery.group(of: theme("b", "Stream", designs: [("Bible", "Lower Thirds")])) == .lowerThirds)
        #expect(ThemeGallery.group(of: theme("c", "Lower Thirds 2026")) == .lowerThirds)
        #expect(ThemeGallery.group(of: theme("d", "Worship Lyrics")) == .worship)
        #expect(ThemeGallery.group(of: theme("e", "Clean"), worshipThemeId: "e") == .worship)
        #expect(ThemeGallery.group(of: theme("f", "Announcements")) == .misc)
        // A wide theme with lower thirds inside it is still wide.
        #expect(ThemeGallery.group(of: theme("g", "Hope", designs: [("Title", nil), ("Bible", "Lower Thirds")])) == .misc)
        // Where someone put it wins.
        #expect(ThemeGallery.group(of: theme("h", "God's Promise", series: true, group: "worship")) == .worship)
        #expect(ThemeGallery.group(of: theme("i", "Clean", group: "nonsense")) == .misc)
    }

    @Test func coverIsTheFirstDesignForItsKind() {
        let wide = theme("w", "Hope", designs: [("Lower", "Lower Thirds"), ("Title", nil)])
        #expect(ThemeGallery.coverDesign(of: wide)?.name == "Title")
        let lower = theme("l", "Stream", designs: [("Bible", "Lower Thirds")])
        #expect(ThemeGallery.coverDesign(of: lower)?.name == "Bible")
    }

    @Test func groupsComeInOrderAndSkipEmptyOnes() {
        let grouped = ThemeGallery.grouped([
            theme("1", "Zeta", group: "misc"), theme("2", "Alpha", group: "misc"),
            theme("3", "Stream", group: "lowerThirds"),
        ])
        #expect(grouped.map(\.group) == [.misc, .lowerThirds])
        #expect(grouped[0].themes.map(\.name) == ["Alpha", "Zeta"])
    }
}
