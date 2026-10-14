import PresenterCore
import RenderEngine
import SlideScene
import Testing

/// Scripture keeps the theme's size: a long passage gets more slides
/// instead of smaller text, even when the theme's verse box auto-shrinks.
@Test func longPassageSplitsInsteadOfShrinking() throws {
    let style = TextStyle(fontName: "Helvetica Neue", fontSize: 60, colorHex: "#FFFFFFFF",
                          autoShrink: true, minFontSize: 20)
    let design = Slide(id: "bible", name: "Bible", objects: [
        SlideObject(id: "v", objectKind: .text, name: "Verse", text: "",
                    x: 220, y: 230, width: 1480, height: 540, textStyle: style),
        SlideObject(id: "r", objectKind: .text, name: "Reference", text: "",
                    x: 220, y: 800, width: 1480, height: 70, textStyle: style),
    ])
    let theme = Theme(id: "t", name: "T", fontFamily: "Helvetica Neue", fontSize: 60,
                      textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF", slides: [design])
    let sentence = "Then Jacob made a vow, saying, If God will be with me and watch over me on this journey."
    let passage = BiblePassage(
        reference: try #require(BibleReference.parse("Genesis 28:1-16")),
        translation: BibleTranslation(source: .esv, id: "ESV", abbreviation: "ESV", name: "ESV"),
        verses: (1...16).map { BibleVerse(chapter: 28, verse: $0, text: sentence) })

    let slides = ScriptureSlideBuilder.slides(for: passage, format: ScriptureFormat(), theme: theme)
    #expect(slides.count > 3)
    for slide in slides {
        let verse = try #require(slide.objects.first)
        let assignments = SlideSceneBuilder.placeholderAssignments(for: slide.objects, in: design)
        let item = SlideSceneBuilder.renderItem(
            for: verse, theme: theme, placeholder: assignments[verse.id], in: SlideSceneBuilder.canvasSize)
        guard case .text(var styled) = item.content else { Issue.record("not text"); continue }
        styled.autoShrink = false
        #expect(!TextRasterizer.overflows(styled, sceneFrame: item.frame.size))
    }
}
