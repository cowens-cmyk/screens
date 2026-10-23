import Foundation
import Testing
@testable import PresenterCore

@Test func decodesClaudesOutline() throws {
    let json = """
    {"title":"Wrestling With God","series":"God's Promise","slides":[
      {"kind":"scripture","text":"Genesis 32:22-32","reference":"Genesis 32:22-32"},
      {"kind":"point","text":"God meets us in the struggle","reference":""},
      {"kind":"pointScripture","text":"He won't let you go","reference":"Romans 8:38-39"}]}
    """
    let outline = try SermonOutline.decode(json)
    #expect(outline.slides.map(\.kind) == [.scripture, .point, .pointScripture])
    #expect(outline.slides[0].reference == "Genesis 32:22-32")
    #expect(outline.series == "God's Promise")
}

@Test func decodesTheTitleSlide() throws {
    let json = """
    {"title":"Wrestling With God","series":"God's Promise","slides":[
      {"kind":"title","text":"Wrestling With God","reference":"God's Promise · Pastor Dan"},
      {"kind":"point","text":"God meets us in the struggle","reference":""}]}
    """
    let outline = try SermonOutline.decode(json)
    #expect(outline.slides.map(\.kind) == [.title, .point])
    #expect(outline.slides[0].reference == "God's Promise · Pastor Dan")
    #expect(SermonOutline.Kind.allCases.first == .title)
    #expect(SermonOutline.instructions.contains("\"title\""))
}

@Test func seriesThemeTiesEveryCategoryToItsLowerThird() {
    let theme = SermonSeriesTheme.make(SermonSeriesStyle(name: "God's Promise", backgroundMediaID: "bg", lowerThirdMediaID: "bar"))
    let slides = theme.slides ?? []
    #expect(theme.isSermonSeries == true)
    #expect(slides.count == 9, "five full-screen designs and four lower thirds")
    for category in [SermonSeriesTheme.pointCategory, SermonSeriesTheme.scriptureCategory,
                     SermonSeriesTheme.pointScriptureCategory, SermonSeriesTheme.worshipCategory] {
        let tie = theme.streamDesigns?.first { $0.category == category }
        #expect(tie?.mode == .design, "\(category)")
        #expect(slides.first { $0.id == tie?.slideId }?.folder == BasicTemplates.lowerThirds, "\(category)")
        #expect(slides.contains { $0.name == category && $0.folder == nil })
    }
    // The title leaves the camera clear.
    #expect(slides.contains { $0.name == SermonSeriesTheme.titleCategory && $0.folder == nil })
    let titleRoute = theme.streamDesigns?.first { $0.category == SermonSeriesTheme.titleCategory }
    #expect(titleRoute?.mode == .clear && titleRoute?.slideId == nil)
    // Text first, art beneath, on every full-screen design.
    for design in slides where design.folder == nil {
        #expect(design.objects.first?.objectKind == .text && design.objects.last?.fill?.mediaId == "bg", "\(design.name)")
    }
    // Point stays the fallback design.
    #expect(slides.first?.name == SermonSeriesTheme.pointCategory)
}

@Test func songsAndTitlesFindTheSeriesDesigns() {
    let theme = SermonSeriesTheme.make(SermonSeriesStyle(name: "Series", headingCaps: true))
    let slides = theme.slides ?? []
    let worship = ThemeCategories.match("Lyrics", in: slides)
    #expect(worship?.name == SermonSeriesTheme.worshipCategory)
    #expect(worship?.objects.first?.name == "Lyrics")
    #expect(worship?.objects.first?.textStyle?.textTransform == nil, "lyrics aren't set in capitals")
    let title = ThemeCategories.match("Title", in: slides)
    #expect(title?.objects.map(\.name).prefix(2) == ["Title", "Subtitle"])
    #expect(title?.objects.first?.textStyle?.textTransform == .uppercase)
    // The livestream's lower thirds answer to Lyrics too.
    let lower = ThemeCategories.lowerThirds(of: theme).slides ?? []
    #expect(ThemeCategories.match("Lyrics", in: lower)?.name == SermonSeriesTheme.worshipCategory)
}

/// A series made before Title and Worship: three designs, three lower thirds.
private func legacySeries() -> Theme {
    var theme = SermonSeriesTheme.make(SermonSeriesStyle(
        name: "Old Series", backgroundMediaID: "old-bg", lowerThirdMediaID: "old-bar",
        font: "Gotham-Book", boldFont: "Gotham-Black", textColor: "#0E1B2AFF", accentColor: "#C8102EFF"))
    let kept: Set<String> = [SermonSeriesTheme.pointCategory, SermonSeriesTheme.scriptureCategory,
                             SermonSeriesTheme.pointScriptureCategory]
    theme.slides = theme.slides?.filter { design in
        kept.contains(design.name) || kept.contains { design.name == "\($0) (Lower Third)" }
    }
    theme.streamDesigns = theme.streamDesigns?.filter { kept.contains($0.category) }
    theme.isSermonSeries = nil
    return theme
}

@Test func oldSeriesGainTitleAndWorshipInTheirOwnLook() throws {
    let old = legacySeries()
    #expect(old.slides?.count == 6)
    #expect(SermonSeriesTheme.isSeries(old))
    let upgraded = try #require(SermonSeriesTheme.upgraded(old))
    let slides = upgraded.slides ?? []
    #expect(upgraded.isSermonSeries == true)
    #expect(slides.count == 9)
    #expect(Array(slides.prefix(6)) == old.slides, "existing designs untouched")

    let title = try #require(slides.first { $0.name == SermonSeriesTheme.titleCategory })
    #expect(title.objects.first?.textStyle?.fontName == "Gotham-Black")
    #expect(title.objects.first?.textStyle?.colorHex == "#0E1B2AFF")
    #expect(title.objects[1].textStyle?.colorHex == "#C8102EFF", "subtitle in the accent color")
    #expect(title.objects.last?.fill?.mediaId == "old-bg")
    let worship = try #require(slides.first { $0.name == SermonSeriesTheme.worshipCategory && $0.folder == nil })
    #expect(worship.objects.first?.name == "Lyrics")
    #expect(worship.objects.last?.fill?.mediaId == "old-bg")
    let worshipLower = try #require(slides.first { $0.name == "Worship (Lower Third)" })
    #expect(worshipLower.folder == BasicTemplates.lowerThirds)
    #expect(worshipLower.objects.last?.fill?.mediaId == "old-bar")

    let routes = upgraded.streamDesigns ?? []
    #expect(routes.first { $0.category == "Title" }?.mode == .clear)
    #expect(routes.first { $0.category == "Worship" }?.slideId == worshipLower.id)
    #expect(routes.count == 5)
    #expect(Set(slides.map(\.id)).count == slides.count, "fresh ids")
    #expect(Set(slides.flatMap(\.objects).map(\.id)).count == slides.flatMap(\.objects).count)

    // Running again changes nothing.
    #expect(SermonSeriesTheme.upgraded(upgraded) == nil)
    #expect(SermonSeriesTheme.upgraded(SermonSeriesTheme.make(SermonSeriesStyle(name: "New"))) == nil)
}

@Test func otherThemesAreNotSeries() {
    for theme in BasicTemplates.themes() {
        #expect(!SermonSeriesTheme.isSeries(theme), "\(theme.name)")
        #expect(SermonSeriesTheme.upgraded(theme) == nil, "\(theme.name)")
    }
    // A flagged series with no lower thirds still gets Title and Worship.
    var bare = legacySeries()
    bare.slides = bare.slides?.filter { $0.folder == nil }
    bare.streamDesigns = nil
    bare.isSermonSeries = true
    let upgraded = SermonSeriesTheme.upgraded(bare)
    #expect(upgraded?.slides?.count == 5)
    #expect(upgraded?.streamDesigns?.map(\.category) == ["Title"])
}

@LibraryActor @Test func libraryUpgradesOnlySeriesThemesOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(rootURL: root)
    let old = legacySeries()
    _ = try library.create(old, seed: .init(id: old.id))
    for theme in BasicTemplates.themes() {
        _ = try library.create(theme, seed: .init(id: theme.id))
    }
    #expect(try library.upgradeSermonSeriesThemes() == 1)
    let stored = try library.open(Theme.self, id: old.id).value
    #expect(stored.isSermonSeries == true && stored.slides?.count == 9)
    for theme in BasicTemplates.themes() {
        let kept = try library.open(Theme.self, id: theme.id).value
        #expect(kept.isSermonSeries == nil && kept.slides?.map(\.id) == theme.slides?.map(\.id))
    }
    #expect(try library.upgradeSermonSeriesThemes() == 0)
}

@Test func importedMessageTakesTheOldMessagesPlace() {
    func item(_ id: String, _ ref: String) -> ServiceItem {
        ServiceItem(id: id, itemKind: .presentation, name: id, refId: ref)
    }
    var plan = Service(id: "p", name: "Sunday", serviceDate: "2026-10-25",
                       items: [item("song", "s1"), item("msg", "old"), item("close", "s2")],
                       messagePresentationId: "old")
    PlanMessage.place("new", name: "Message", series: "series", in: &plan) { _ in false }
    #expect(plan.items.map(\.refId) == ["s1", "new", "s2"])
    #expect(plan.items[1].name == "msg", "the item keeps its name")
    #expect(plan.messagePresentationId == "new" && plan.sermonThemeId == "series")

    // Plans that never recorded their message find it by category.
    var older = Service(id: "q", name: "Sunday", serviceDate: "2026-10-25", items: [item("song", "s1"), item("m", "sermon")])
    PlanMessage.place("new", name: "Message", series: nil, in: &older) { $0 == "sermon" }
    #expect(older.items.map(\.refId) == ["s1", "new"])
    #expect(older.sermonThemeId == nil)

    // No message yet: it goes at the end.
    var empty = Service(id: "r", name: "Sunday", serviceDate: "2026-10-25", items: [item("song", "s1")])
    PlanMessage.place("new", name: "Message", series: "series", in: &empty) { _ in false }
    #expect(empty.items.map(\.refId) == ["s1", "new"] && empty.items.last?.name == "Message")
}

@Test func seriesDesignIsSanitizedAndColorsNormalized() {
    let svg = #"<svg><rect width="10" height="10"/><text x="1">Hi</text><script>x()</script></svg>"#
    let cleaned = SeriesDesign.sanitize(svg)
    #expect(!cleaned.contains("<text") && !cleaned.contains("<script") && cleaned.contains("<rect"))
    #expect(SeriesDesign.color("#ffb21e", fallback: "#000000FF") == "#FFB21EFF")
    #expect(SeriesDesign.color("orange", fallback: "#000000FF") == "#000000FF")
}

@Test func claudeDesignExportDecodesWithSingleOrListedFonts() throws {
    let json = #"""
    {"series":"God's Promise","background":"background.png","lowerThird":"lower-third.png",
     "headingFont":["Gotham Black","Avenir Next Heavy"],"bodyFont":"Gotham Book",
     "headingAllCaps":true,"textColor":"#0E1B2A","lowerThirdTextColor":"#F7F4ED"}
    """#
    let export = try SeriesExport.decode(Data(json.utf8))
    #expect(export.series == "God's Promise")
    #expect(export.headingFont == ["Gotham Black", "Avenir Next Heavy"])
    #expect(export.bodyFont == ["Gotham Book"])
    #expect(export.scriptureFont == nil)
    #expect(export.headingAllCaps == true)
}
