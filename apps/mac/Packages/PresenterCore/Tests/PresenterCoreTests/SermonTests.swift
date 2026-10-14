import Foundation
import Testing
@testable import PresenterCore

@Test func decodesClaudesOutline() throws {
    let json = """
    {"title":"Wrestling With God","slides":[
      {"kind":"scripture","text":"Genesis 32:22-32","reference":"Genesis 32:22-32"},
      {"kind":"point","text":"God meets us in the struggle","reference":""},
      {"kind":"pointScripture","text":"He won't let you go","reference":"Romans 8:38-39"}]}
    """
    let outline = try SermonOutline.decode(json)
    #expect(outline.slides.map(\.kind) == [.scripture, .point, .pointScripture])
    #expect(outline.slides[0].reference == "Genesis 32:22-32")
}

@Test func seriesThemeTiesEveryCategoryToItsLowerThird() {
    let theme = SermonSeriesTheme.make(SermonSeriesStyle(name: "God's Promise", backgroundMediaID: "bg", lowerThirdMediaID: "bar"))
    let slides = theme.slides ?? []
    #expect((theme.slides ?? []).count == 6, "three full-screen designs and three lower thirds")
    for category in [SermonSeriesTheme.pointCategory, SermonSeriesTheme.scriptureCategory,
                     SermonSeriesTheme.pointScriptureCategory] {
        let tie = theme.streamDesigns?.first { $0.category == category }
        #expect(slides.first { $0.id == tie?.slideId }?.folder == BasicTemplates.lowerThirds, "\(category)")
        #expect(slides.contains { $0.name == category && $0.folder == nil })
    }
    // Text first, art beneath.
    let point = slides.first { $0.name == SermonSeriesTheme.pointCategory }
    #expect(point?.objects.first?.objectKind == .text && point?.objects.last?.fill?.mediaId == "bg")
}
