import Foundation
import PresenterCore
import Testing
@testable import SlideScene

/// The videos the plan is about to play, whose players are readied ahead.
struct PlanUpcomingVideosTests {
    private func video(_ id: String, loops: Bool) -> MediaItem {
        MediaItem(
            id: id, name: id, mediaKind: .video, classification: .background,
            fileHash: id, fileName: "\(id).mov", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: loops)
    }

    private func picture(_ id: String) -> MediaItem {
        MediaItem(
            id: id, name: id, mediaKind: .image, classification: .background,
            fileHash: id, fileName: "\(id).png", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false)
    }

    private func deck(_ id: String, backgrounds: [CueMedia]) -> Presentation {
        let slides = backgrounds.enumerated().map { index, background -> Slide in
            var slide = Slide(id: "\(id)-\(index)", name: "", objects: [])
            slide.background = background
            return slide
        }
        return Presentation(id: id, name: id, presentationKind: .song, themeId: "", slides: slides)
    }

    private func item(_ id: String, _ kind: ServiceItemKind, ref: String, countdown: Bool = false) -> ServiceItem {
        var item = ServiceItem(id: id, itemKind: kind, name: id, refId: ref)
        item.isCountdown = countdown ? true : nil
        return item
    }

    private let media: [String: MediaItem] = [
        "countdown": MediaItem(
            id: "countdown", name: "countdown", mediaKind: .video, classification: .foreground,
            fileHash: "c", fileName: "c.mov", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false),
        "ocean": MediaItem(
            id: "ocean", name: "ocean", mediaKind: .video, classification: .background,
            fileHash: "o", fileName: "o.mov", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false),
        "still": MediaItem(
            id: "still", name: "still", mediaKind: .image, classification: .background,
            fileHash: "s", fileName: "s.png", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false),
        "bumper": MediaItem(
            id: "bumper", name: "bumper", mediaKind: .video, classification: .foreground,
            fileHash: "b", fileName: "b.mov", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false),
    ]

    private var items: [ServiceItem] {
        [
            item("c", .media, ref: "countdown", countdown: true),
            item("song", .presentation, ref: "song"),
            item("h", .header, ref: ""),
            item("b", .media, ref: "bumper"),
        ]
    }

    private var decks: [String: Presentation] {
        ["song": deck("song", backgrounds: [
            CueMedia(mediaId: "ocean", loops: true), CueMedia(mediaId: "still"), CueMedia(mediaId: "ocean", loops: true),
        ])]
    }

    @Test func theItemOnScreenAndTheTwoAfterItInOrder() {
        let found = PlanUpcomingVideos.videos(
            items: items, liveIndex: nil, limit: 6, deck: { decks[$0] }, media: { media[$0] })
        #expect(found == [
            .init(mediaID: "countdown", loop: false),
            .init(mediaID: "ocean", loop: true),
        ], "pictures are left out, a video used twice is readied once, the header counts as an item")
    }

    @Test func itMovesOnWithThePlan() {
        let found = PlanUpcomingVideos.videos(
            items: items, liveIndex: 1, limit: 6, deck: { decks[$0] }, media: { media[$0] })
        #expect(found.map(\.mediaID) == ["ocean", "bumper"])
    }

    @Test func theLimitHolds() {
        let found = PlanUpcomingVideos.videos(
            items: items, liveIndex: nil, limit: 1, deck: { decks[$0] }, media: { media[$0] })
        #expect(found.map(\.mediaID) == ["countdown"])
    }

    @Test func aVideoKeepsItsOwnLoopWhenTheSlideSaysNothing() {
        let plain = ["song": deck("song", backgrounds: [CueMedia(mediaId: "looping")])]
        let looping = video("looping", loops: true)
        let found = PlanUpcomingVideos.videos(
            items: [item("song", .presentation, ref: "song")], liveIndex: 0, limit: 6,
            deck: { plain[$0] }, media: { $0 == "looping" ? looping : nil })
        #expect(found == [.init(mediaID: "looping", loop: true)])
        #expect(picture("x").playsLooping == false)
    }

    /// On a big Mac the whole plan stands by, nearest first: from the item
    /// on screen to the end, then the items before it, because the operator
    /// jumps back as well as forward.
    @Test func theWholePlanFromTheItemOnScreenThenTheItemsBefore() {
        let found = PlanUpcomingVideos.videos(
            items: items, liveIndex: 3, limit: 12, itemsAhead: nil, deck: { decks[$0] }, media: { media[$0] })
        #expect(found.map(\.mediaID) == ["bumper", "countdown", "ocean"])
        let fromStart = PlanUpcomingVideos.videos(
            items: items, liveIndex: nil, limit: 12, itemsAhead: nil, deck: { decks[$0] }, media: { media[$0] })
        #expect(fromStart.map(\.mediaID) == ["countdown", "ocean", "bumper"], "after launch, nothing live: all of it")
    }

    /// A deck's own background fill, a slide's fill and the videos its
    /// slides' and the item's actions fire get players too.
    @Test func fillsAndFiredVideosStandByToo() {
        var song = deck("song", backgrounds: [CueMedia(mediaId: "ocean", loops: true)])
        song.backgroundFill = ObjectFill(fillKind: .media, mediaId: "fill", loops: true)
        song.slides[0].backgroundFill = ObjectFill(fillKind: .media, mediaId: "slideFill")
        song.slides[0].actions = [SlideAction(id: "a", kind: .fireMedia, mediaId: "bumper")]
        var planItem = item("song", .presentation, ref: "song")
        planItem.actions = [SlideAction(id: "m", kind: .fireMedia, mediaId: "macro")]
        var all = media
        all["fill"] = video("fill", loops: false)
        all["slideFill"] = video("slideFill", loops: true)
        all["macro"] = video("macro", loops: false)
        let found = PlanUpcomingVideos.videos(
            items: [planItem], liveIndex: 0, limit: 12, itemsAhead: nil, deck: { $0 == "song" ? song : nil },
            media: { all[$0] })
        #expect(found == [
            .init(mediaID: "fill", loop: true),
            .init(mediaID: "ocean", loop: true),
            .init(mediaID: "slideFill", loop: true),
            .init(mediaID: "bumper", loop: false),
            .init(mediaID: "macro", loop: false),
        ])
    }
}
