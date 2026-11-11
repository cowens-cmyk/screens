import PresenterCore
import RenderEngine
import SlideScene
import Testing

/// Song slides are measured in the theme's real Lyrics box, so a lyric line
/// that wraps there splits the slide; one that fits leaves it alone.
@Suite struct LyricSlideFitterTests {
    let theme: Theme = {
        let style = TextStyle(fontName: "Helvetica Neue", fontSize: 80, colorHex: "#FFFFFFFF")
        let lyrics = Slide(id: "lyrics", name: "Lyrics", objects: [
            SlideObject(id: "box", objectKind: .text, name: "Lyrics", text: "",
                        x: 360, y: 740, width: 1200, height: 240, textStyle: style),
        ])
        return Theme(id: "t", name: "Worship", fontFamily: "Helvetica Neue", fontSize: 80,
                     textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF", slides: [lyrics])
    }()

    func song(_ chart: String) -> Presentation {
        let built = Reflow.build(from: chart, linesPerSlide: 2)
        var song = Presentation(id: "ag", name: "Ancient Gates", presentationKind: .song, themeId: "t",
                                slides: built.slides, sections: built.sections)
        song.category = PresentationTypes.worship
        return song
    }

    func lines(_ slide: Slide) throws -> Int {
        let box = try #require(slide.objects.first)
        let count = LyricSlideFitter.lineCount(theme: { _ in theme })
        return try #require(count(slide, box, box.text))
    }

    func label(_ slide: Slide, in song: Presentation) -> String? {
        song.sections?.first { $0.id == slide.sectionId }?.name
    }

    @Test func aWrappingLineSplitsTheSlideAndKeepsTheLabel() throws {
        let original = song("""
        Verse 1
        [G]Lift up your heads O you ancient gates and [C]be lifted up
        [Em]You everlasting doors

        Chorus
        [C]Who is this King
        [G]The Lord strong and mighty
        """)
        #expect(try lines(original.slides[0]) > 2, "the theme's box wraps the long line")
        #expect(try lines(original.slides[1]) == 2)

        let result = LyricSlideFitter.fit(original, themes: ["t": theme])
        #expect(result.splitSlides == 1 && result.resultingSlides == 2)
        let fitted = result.presentation
        #expect(fitted.slides.count == 3)
        #expect(fitted.slides.map { label($0, in: fitted) } == ["Verse 1", "Verse 1", "Chorus"])
        #expect(fitted.slides.map { $0.objects.first?.text } == [
            "Lift up your heads O you ancient gates and be lifted up", "You everlasting doors",
            "Who is this King\nThe Lord strong and mighty",
        ])
        for slide in fitted.slides { #expect(try lines(slide) <= 2) }
        // Chords stay over their words.
        #expect(fitted.slides[0].objects[0].chords == [
            ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 0, column: 43, symbol: "C")])
        #expect(fitted.slides[1].objects[0].chords == [ChordPlacement(line: 0, column: 0, symbol: "Em")])
        #expect(fitted.slides[2] == original.slides[1], "the chorus fits and is untouched")
        #expect(fitted.slides.allSatisfy { $0.themeSlideName == "Lyrics" })
    }

    @Test func aLineTooLongForTwoLinesIsCutAtAWord() throws {
        let original = song("""
        Bridge
        Lift up your heads O you ancient gates be lifted up you everlasting doors that the King of glory may come in
        """)
        #expect(try lines(original.slides[0]) > 2)
        let fitted = LyricSlideFitter.fit(original, themes: ["t": theme]).presentation
        #expect(fitted.slides.count >= 2)
        for slide in fitted.slides {
            #expect(try lines(slide) <= 2)
            #expect(label(slide, in: fitted) == "Bridge")
        }
        let words = fitted.slides.compactMap { $0.objects.first?.text }
            .joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        #expect(words == "Lift up your heads O you ancient gates be lifted up you everlasting doors that the King of glory may come in")
    }

    @Test func fittingSongsAreUnchanged() {
        let original = song("""
        Verse 1
        Lift up your heads
        O you ancient gates
        """)
        let result = LyricSlideFitter.fit(original, themes: ["t": theme])
        #expect(!result.changed)
        #expect(result.presentation == original)
    }

    @Test func aBoxThatShrinksToKeepLinesWholeNeverSplits() {
        var shrinking = theme
        shrinking.slides?[0].objects[0].textStyle?.autoShrink = true
        shrinking.slides?[0].objects[0].textStyle?.keepLinesWhole = true
        shrinking.slides?[0].objects[0].textStyle?.minFontSize = 20
        let original = song("""
        Verse 1
        Lift up your heads O you ancient gates and be lifted up
        You everlasting doors
        """)
        #expect(!LyricSlideFitter.fit(original, themes: ["t": shrinking]).changed)
    }
}
