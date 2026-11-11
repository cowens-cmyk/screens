import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let canvas = CGSize(width: 1920, height: 1080)

/// A worship theme set for the big wall: two small lines at the top, with
/// a bar and a CCLI line the theme draws itself.
private func wallTheme() -> Theme {
    var lyrics = SlideObject(id: "ph-lyrics", objectKind: .text, name: "Lyrics", text: "Sample")
    lyrics.x = 160; lyrics.y = 40; lyrics.width = 1600; lyrics.height = 180
    var bar = SlideObject(id: "bar", objectKind: .shape, name: "Bar", text: "")
    bar.x = 0; bar.y = 20; bar.width = 1920; bar.height = 220
    var ccli = SlideObject(
        id: "ccli", objectKind: .text, name: "CCLI", text: "CCLI 123",
        textLink: TextLink(source: .currentPresentation))
    ccli.x = 40; ccli.y = 1020; ccli.width = 600; ccli.height = 40
    return Theme(
        id: "wall", name: "Wall", fontFamily: "Helvetica", fontSize: 54,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
        slides: [Slide(id: "wall-lyrics", name: "Lyrics", objects: [bar, lyrics, ccli])])
}

private func lyricSlide() -> Slide {
    var slide = Slide(id: "verse-1", name: "", objects: [
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics",
                    text: "Amazing grace how sweet the sound\nThat saved a wretch like me")
    ])
    slide.themeSlideName = "Lyrics"
    return slide
}

private func presentation(kind: PresentationKind, category: String? = nil) -> Presentation {
    Presentation(
        id: "p", name: "Amazing Grace", presentationKind: kind, themeId: "wall",
        slides: [lyricSlide()],
        background: CueMedia(mediaId: "worship-loop", layer: .loopingVideos),
        category: category)
}

private func roomScene(_ presentation: Presentation) -> RenderScene {
    SlideSceneBuilder.scene(for: lyricSlide(), theme: wallTheme(), presentation: presentation)
}

private func item(_ id: String, in scene: RenderScene) -> RenderItem? {
    scene.layers.first { $0.kind == .slide }?.items.first { $0.id == id }
}

private func text(of item: RenderItem?) -> StyledText? {
    guard case .text(let text)? = item?.content else { return nil }
    return text
}

@Test func aSongsLyricsAreDrawnLargerOnTheSideTVs() throws {
    let song = presentation(kind: .song)
    let room = roomScene(song)
    let side = SideScreenLyrics.scene(room, presentation: song, scale: 1.6)

    let roomText = try #require(text(of: item("lyrics", in: room)))
    let sideText = try #require(text(of: item("lyrics", in: side)))
    #expect(sideText.string == roomText.string, "the same words")
    #expect(abs(sideText.fontSize - roomText.fontSize * 1.6) < 0.001)
    #expect(sideText.autoShrink, "shrinks to fit when the box can't grow as much")
    #expect(sideText.minFontSize == roomText.fontSize, "never smaller than the wall's")
    #expect(sideText.keepLinesWhole, "two lines on the wall stay two lines")

    let roomFrame = try #require(item("lyrics", in: room)?.frame)
    let sideFrame = try #require(item("lyrics", in: side)?.frame)
    #expect(sideFrame.height > roomFrame.height * 1.5)
    #expect(sideFrame.width > roomFrame.width, "grows as wide as the safe area allows")
    #expect(abs(sideFrame.midX - roomFrame.midX) < 0.001, "still centred")
    // The theme put the box above the safe line; it keeps that top edge
    // and grows down, and otherwise stays inside the safe area.
    let safe = CGRect(origin: .zero, size: canvas).insetBy(dx: 96, dy: 54)
    #expect(safe.union(roomFrame).contains(sideFrame))
    #expect(sideFrame.minY == roomFrame.minY)
    #expect(!TextRasterizer.overflows(sideText, sceneFrame: sideFrame.size), "the larger words fit their box")
}

@Test func theBackgroundAndTheThemesOwnPiecesStayTheRooms() {
    let song = presentation(kind: .song)
    let room = roomScene(song)
    let side = SideScreenLyrics.scene(room, presentation: song, scale: 1.6)

    #expect(side.canvasSize == room.canvasSize)
    #expect(side.background == room.background)
    for layer in room.layers where layer.kind != .slide {
        #expect(side.layers.first { $0.kind == layer.kind } == layer, "\(layer.kind) untouched")
    }
    let roomLoop = room.layers.first { $0.kind == .loopingVideos }?.items.compactMap(\.content.mediaID).first
    #expect(roomLoop == "worship-loop", "the fixture has its worship background")
    let roomSlide = room.layers.first { $0.kind == .slide }!.items
    let sideSlide = side.layers.first { $0.kind == .slide }!.items
    #expect(sideSlide.map(\.id) == roomSlide.map(\.id), "same items in the same order")
    #expect(roomSlide.contains { $0.id == "theme-bar" } && roomSlide.contains { $0.id == "theme-ccli" },
            "the fixture has the theme's bar and CCLI line")
    for (before, after) in zip(roomSlide, sideSlide) where before.id != "lyrics" {
        #expect(after == before, "\(before.id) is the room's")
    }
}

@Test func worshipTypedDecksCountAsSongs() {
    let deck = presentation(kind: .deck, category: PresentationTypes.worship)
    let room = roomScene(deck)
    #expect(SideScreenLyrics.scene(room, presentation: deck, scale: 1.6) != room)
}

@Test func anythingThatIsntASongGoesOutAsTheRoomHasIt() {
    for category in [PresentationTypes.sermon, PresentationTypes.bible, PresentationTypes.announcements] {
        let deck = presentation(kind: .deck, category: category)
        let room = roomScene(deck)
        #expect(SideScreenLyrics.scene(room, presentation: deck, scale: 1.6) == room, "\(category)")
    }
    let untyped = presentation(kind: .deck)
    let room = roomScene(untyped)
    #expect(SideScreenLyrics.scene(room, presentation: untyped, scale: 1.6) == room)
    #expect(SideScreenLyrics.scene(room, presentation: nil, scale: 1.6) == room, "media fired on its own")
}

@Test func aScaleOfOneLeavesTheSceneAlone() {
    let song = presentation(kind: .song)
    let room = roomScene(song)
    #expect(SideScreenLyrics.scene(room, presentation: song, scale: 1) == room)
    #expect(SideScreenLyrics.scene(room, presentation: song, scale: 0.5) == room, "never smaller than the room")
}

@Test func aBoxAtTheTopGrowsDownIntoThePicture() {
    let top = CGRect(x: 160, y: 40, width: 1600, height: 180)
    let grown = SideScreenLyrics.frame(top, scaledBy: 1.6, canvas: canvas)
    // The theme put the box above the safe line, so its own top edge holds.
    #expect(grown.minY == 40)
    #expect(grown.height == 288)
    #expect(grown.minX == 96 && grown.maxX == 1824, "cut to the safe area's width")

    let middle = CGRect(x: 560, y: 440, width: 800, height: 200)
    let centred = SideScreenLyrics.frame(middle, scaledBy: 2, canvas: canvas)
    #expect(centred == CGRect(x: 160, y: 340, width: 1600, height: 400), "grows around its centre")

    let huge = SideScreenLyrics.frame(middle, scaledBy: 10, canvas: canvas)
    #expect(huge == CGRect(x: 96, y: 54, width: 1728, height: 972), "no bigger than the safe area")
}

@Test func theTypesMeasuresGrowWithIt() {
    var styled = StyledText(string: "Grace", fontName: "Helvetica", fontSize: 50)
    styled.tracking = 2
    styled.insetTop = 10
    styled.shadow = TextShadow(color: .black, blurRadius: 4, offsetX: 1, offsetY: 2)
    styled.outline = TextOutline(color: .black, width: 3)
    styled.lineOverrides = [TextLineOverride(lineIndex: 1, fontSize: 40)]
    styled.autoShrink = true
    styled.minFontSize = 30
    let grown = SideScreenLyrics.styled(styled, scaledBy: 2)
    #expect(grown.fontSize == 100)
    #expect(grown.tracking == 4)
    #expect(grown.insetTop == 20)
    #expect(grown.shadow?.blurRadius == 8 && grown.shadow?.offsetY == 4)
    #expect(grown.outline?.width == 6)
    #expect(grown.lineOverrides.first?.fontSize == 80)
    #expect(grown.minFontSize == 30, "a theme that already shrinks keeps its own floor")
}

@Test func pageTurnStatesGrowWithTheBox() throws {
    var room = RenderScene(canvasSize: canvas)
    let small = RenderItem(
        id: "lyrics", frame: CGRect(x: 560, y: 440, width: 800, height: 200),
        content: .text(StyledText(string: "One", fontName: "Helvetica", fontSize: 50)))
    var live = small
    var step = SceneAnimationStep(
        id: "lyrics::page::2", kind: .morph, animation: .move, group: .click(0), duration: 0.5)
    step.toItem = small
    live.animationSteps = [step]
    room.addItem(live, to: .slide)
    let side = SideScreenLyrics.scene(enlargingTextOf: room, scale: 2)
    let grown = try #require(side.layers.first { $0.kind == .slide }?.items.first)
    #expect(grown.animationSteps.first?.toItem?.frame == grown.frame)
    #expect(text(of: grown.animationSteps.first?.toItem)?.fontSize == 100)
}
