import Foundation
import Testing
@testable import PresenterCore

@Test func aSongSlidesLookBecomesALyricsTheme() {
    var words = SlideObject(id: "w", objectKind: .text, name: "Text", text: "COME TO JESUS", x: 100, y: 60, width: 1720, height: 160)
    words.textStyle = TextStyle(fontName: "Montserrat-Black", fontSize: 40, colorHex: "#FFFFFFFF")
    words.chords = [ChordPlacement(line: 0, column: 0, symbol: "B")]
    let picture = SlideObject(id: "pic", objectKind: .media, name: "Glow", text: "")
    var slide = Slide(id: "s", name: "Verse 1", objects: [picture, words])
    slide.background = CueMedia(mediaId: "slide-glow", layer: .stillGraphics, classification: .background)
    slide.unthemed = true
    var song = Presentation(id: "p", name: "Come To Jesus", presentationKind: .song, themeId: "", slides: [slide])
    song.background = CueMedia(mediaId: "glow", layer: .stillGraphics, classification: .background)
    #expect(WorshipThemeFromSlide.followedTheme(of: slide, in: song) == nil)

    let theme = WorshipThemeFromSlide.theme(from: slide, in: song, id: "t")
    let design = try! #require(theme.slides?.first)
    #expect(design.name == "Lyrics")
    #expect(design.background == nil, "the background stays with each song")
    #expect(design.objects.count == 1, "only the words")
    #expect(design.objects.first?.name == "Lyrics")
    #expect(design.objects.first?.y == 60, "the words stay where they were")
    #expect(design.objects.first?.chords == nil)
    #expect(theme.fontFamily == "Montserrat-Black")
    #expect(theme.fontSize == 40)
}

@Test func aSlideFollowingAThemeKeepsIt() {
    let slide = Slide(id: "s", name: "Verse", objects: [])
    let song = Presentation(id: "p", name: "Song", presentationKind: .song, themeId: "worship", slides: [slide])
    #expect(WorshipThemeFromSlide.followedTheme(of: slide, in: song) == "worship")
}
