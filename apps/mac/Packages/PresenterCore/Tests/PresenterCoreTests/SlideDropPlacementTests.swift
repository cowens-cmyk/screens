import CoreGraphics
import Foundation
@testable import PresenterCore
import Testing

struct SlideDropPlacementTests {

    // MARK: Over a tile

    @Test func aTilesEdgesInsertAndItsMiddleTakesTheBackground() {
        // 200 wide: each edge is a fifth, 40.
        #expect(SlideDropPlacement.target(overTile: 3, x: 5, width: 200) == .before(3))
        #expect(SlideDropPlacement.target(overTile: 3, x: 39, width: 200) == .before(3))
        #expect(SlideDropPlacement.target(overTile: 3, x: 100, width: 200) == .onto(3))
        #expect(SlideDropPlacement.target(overTile: 3, x: 161, width: 200) == .after(3))
        #expect(SlideDropPlacement.target(overTile: 3, x: 199, width: 200) == .after(3))
    }

    @Test func aSmallTileKeepsTheOldStripAndAMiddle() {
        // 100 wide: a fifth is under the old 26-point strip, so the strip holds.
        #expect(SlideDropPlacement.target(overTile: 0, x: 25, width: 100) == .before(0))
        #expect(SlideDropPlacement.target(overTile: 0, x: 50, width: 100) == .onto(0))
        #expect(SlideDropPlacement.target(overTile: 0, x: 75, width: 100) == .after(0))
        // Tiny: no edge takes more than a third.
        #expect(SlideDropPlacement.target(overTile: 0, x: 30, width: 60) == .onto(0))
        // Not measured yet: only the old leading strip inserts.
        #expect(SlideDropPlacement.target(overTile: 2, x: 10, width: 0) == .before(2))
        #expect(SlideDropPlacement.target(overTile: 2, x: 80, width: 0) == .onto(2))
    }

    // MARK: Between tiles

    /// Two rows of three 100×80 tiles, 10 apart, then one more on a third row.
    private var grid: [Int: CGRect] {
        var tiles: [Int: CGRect] = [:]
        for index in 0 ..< 7 {
            let row = index / 3, column = index % 3
            tiles[index] = CGRect(x: CGFloat(column) * 110, y: CGFloat(row) * 90, width: 100, height: 80)
        }
        return tiles
    }

    @Test func aGapGoesBesideTheNearestTile() {
        // Between tiles 0 and 1, nearer 1's left.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 105, y: 40)) == .before(1))
        // Left of the first tile.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: -8, y: 40)) == .before(0))
        // Past the end of the first row: after its last tile, not before the
        // next row's first.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 340, y: 40)) == .after(2))
        // The gap under row one, toward its middle tile.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 150, y: 84)) == .before(1))
        // Just below the halfway line, the second row.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 150, y: 86)) == .before(4))
    }

    @Test func pastTheLastSlideGoesAfterIt() {
        // Beside the lone tile on the last row, and anywhere under it.
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 200, y: 200)) == .after(6))
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 300, y: 400)) == .after(6))
        #expect(SlideDropPlacement.target(among: grid, at: CGPoint(x: 20, y: 400)) == .before(6))
    }

    @Test func noTilesNoPlace() {
        #expect(SlideDropPlacement.target(among: [:], at: .zero) == nil)
    }

    // MARK: Anchors

    @Test func aPlaceIsNamedByTheSlideBesideIt() {
        let ids = ["a", "b", "c"]
        #expect(SlideDropPlacement.anchor(for: .before(0), in: ids) == .before("a"))
        #expect(SlideDropPlacement.anchor(for: .before(2), in: ids) == .before("c"))
        #expect(SlideDropPlacement.anchor(for: .after(2), in: ids) == .after("c"))
        #expect(SlideDropPlacement.anchor(for: .after(0), in: ids) == .after("a"))
        #expect(SlideDropPlacement.anchor(for: .onto(1), in: ids) == nil)
        // A place past the slides is after the last.
        #expect(SlideDropPlacement.anchor(for: .before(3), in: ids) == .after("c"))
        // An empty presentation takes its first slide.
        #expect(SlideDropPlacement.anchor(for: .before(0), in: []) == .end)
        #expect(SlideDropPlacement.anchor(for: .after(0), in: []) == .end)
    }

    private func slide(_ id: String, section: String? = nil) -> Slide {
        Slide(id: id, name: id, objects: [], sectionId: section)
    }

    private func deck(_ slides: [Slide]) -> Presentation {
        Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: slides)
    }

    @Test func insertingBeforeTheFirstSlidePutsItFirst() {
        // The grid once sent "before the first slide" to the end.
        var presentation = deck([slide("a"), slide("b")])
        SlideDropPlacement.insert([slide("new")], at: .before("a"), in: &presentation)
        #expect(presentation.slides.map(\.id) == ["new", "a", "b"])
    }

    @Test func insertingTakesTheSectionBesideIt() {
        var presentation = deck([slide("a", section: "verse"), slide("b", section: "chorus")])
        SlideDropPlacement.insert([slide("x"), slide("y")], at: .after("a"), in: &presentation)
        #expect(presentation.slides.map(\.id) == ["a", "x", "y", "b"])
        #expect(presentation.slides[1].sectionId == "verse" && presentation.slides[2].sectionId == "verse")
        SlideDropPlacement.insert([slide("z")], at: .before("b"), in: &presentation)
        #expect(presentation.slides.map(\.id) == ["a", "x", "y", "z", "b"])
        #expect(presentation.slides[3].sectionId == "chorus")
    }

    @Test func theEndAndAMissingSlideBothAppend() {
        var presentation = deck([])
        SlideDropPlacement.insert([slide("first")], at: .end, in: &presentation)
        #expect(presentation.slides.map(\.id) == ["first"])
        SlideDropPlacement.insert([slide("second")], at: .after("gone"), in: &presentation)
        SlideDropPlacement.insert([slide("third")], at: .before("gone"), in: &presentation)
        #expect(presentation.slides.map(\.id) == ["first", "second", "third"])
    }

    // MARK: Building

    private func media(_ id: String, _ name: String, _ kind: MediaKind) -> MediaItem {
        MediaItem(
            id: id, name: name, mediaKind: kind, classification: .background,
            fileHash: "h-\(id)", fileName: "\(name).bin", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false
        )
    }

    @Test func eachPictureOrVideoBecomesASlideWithItAsTheBackground() {
        var ids = ["s1", "s2"].makeIterator()
        let made = MediaSlideBuilder.make(
            [media("m1", "Welcome", .image), media("m2", "Bumper", .video)],
            sectionId: "intro", newID: { ids.next()! })
        #expect(made.slides.map(\.id) == ["s1", "s2"])
        #expect(made.slides.map(\.name) == ["Welcome", "Bumper"])
        #expect(made.slides.map(\.background?.mediaId) == ["m1", "m2"])
        #expect(made.slides[0].background?.layer == .stillGraphics)
        #expect(made.slides[1].background?.layer == .videos)
        #expect(made.slides.allSatisfy { $0.sectionId == "intro" && $0.objects.isEmpty })
        #expect(made.existingLowerThirds.isEmpty)
    }

    @Test func aLowerThirdRidesOnItsPicture() {
        let made = MediaSlideBuilder.make(
            [media("w", "Slide01_Wide", .image), media("l", "Slide01_LowerThird", .image)])
        #expect(made.slides.count == 1)
        #expect(made.slides[0].streamDesign == .lowerThirdImage("l"))
        let existing = MediaSlideBuilder.make(
            [media("l", "Slide02_LowerThird", .image)], existing: [(id: "old", name: "Slide02")])
        #expect(existing.slides.isEmpty)
        #expect(existing.existingLowerThirds == ["old": "l"])
    }

    @Test func onlyPicturesVideosAndFoldersMakeSlides() {
        #expect(MediaSlideBuilder.makesSlides(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(MediaSlideBuilder.makesSlides(URL(fileURLWithPath: "/tmp/a.MOV")))
        #expect(MediaSlideBuilder.makesSlides(URL(fileURLWithPath: "/tmp/Announcements/", isDirectory: true)))
        #expect(!MediaSlideBuilder.makesSlides(URL(fileURLWithPath: "/tmp/a.pdf")))
        #expect(!MediaSlideBuilder.makesSlides(URL(fileURLWithPath: "/tmp/a.mp3")))
    }

    // MARK: Countdown

    @Test func theCountdownTakesTheFirstVideoFromTheFinder() {
        let urls = [
            URL(fileURLWithPath: "/tmp/notes.pdf"),
            URL(fileURLWithPath: "/tmp/still.jpg"),
            URL(fileURLWithPath: "/tmp/Countdown Nov 16.mp4"),
            URL(fileURLWithPath: "/tmp/other.mov"),
        ]
        #expect(ServiceCountdown.videoFile(in: urls)?.lastPathComponent == "Countdown Nov 16.mp4")
        #expect(ServiceCountdown.videoFile(in: Array(urls.prefix(2))) == nil)
        #expect(ServiceCountdown.videoFile(in: []) == nil)
    }
}
