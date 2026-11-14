import Foundation
import Testing
@testable import PresenterCore

/// What the plan preloader reads into memory, in what order, and how much
/// room it gives itself on Macs of each size.
struct PlanPreloadPlanTests {
    private let gigabyte: UInt64 = 1 << 30

    private func theme(_ id: String, media: String? = nil, lowerThird: String? = nil, designs: [String] = []) -> Theme {
        var slides: [Slide] = []
        if let media {
            var slide = Slide(id: "\(id)-s", name: "Lyrics", objects: [])
            slide.background = CueMedia(mediaId: media)
            slides.append(slide)
        }
        return Theme(
            id: id, name: id, fontFamily: "", fontSize: 1, textColorHex: "", backgroundColorHex: "",
            slides: slides, streamLowerThirdThemeId: lowerThird,
            streamDesigns: designs.map { StreamDesign(category: "Lyrics", mode: .design, themeId: $0) })
    }

    private func item(_ id: String, _ kind: ServiceItemKind, ref: String, actions: [SlideAction]? = nil) -> ServiceItem {
        var item = ServiceItem(id: id, itemKind: kind, name: id, refId: ref)
        item.actions = actions
        return item
    }

    @Test func aPlansMediaComeInPlanOrderEachOnce() {
        var first = Slide(id: "s1", name: "Point 1", objects: [])
        first.background = CueMedia(mediaId: "wide-1")
        first.streamDesign = .lowerThirdImage("lower-1")
        var second = Slide(id: "s2", name: "Point 2", objects: [])
        second.background = CueMedia(mediaId: "wide-2")
        second.streamDesign = .lowerThirdImage("lower-2")
        second.actions = [SlideAction(id: "a", kind: .fireMedia, mediaId: "sting")]
        var message = Presentation(id: "msg", name: "Message", presentationKind: .deck, themeId: "series", slides: [first, second])
        message.background = CueMedia(mediaId: "deck-bg")
        let song = Presentation(id: "song", name: "Song", presentationKind: .song, themeId: "lyrics", slides: [first])
        let themes = ["series": theme("series", media: "series-bg"), "lyrics": theme("lyrics", media: "lyrics-bg")]
        var logo = SlideObject(id: "logo", objectKind: .media, name: "Logo", text: "")
        logo.mediaId = "stage-logo"
        let layout = ConfidenceLayout(id: "stage", name: "Stage", objects: [logo])
        let ids = PlanPreloadPlan.mediaIDs(
            items: [
                item("countdown", .media, ref: "countdown-video"),
                item("song", .presentation, ref: "song"),
                item("header", .header, ref: ""),
                item("message", .presentation, ref: "msg", actions: [SlideAction(id: "m", kind: .fireMedia, mediaId: "walk-in")]),
                item("song-again", .presentation, ref: "song"),
            ],
            decks: ["msg": message, "song": song], themes: { themes[$0] }, stageLayouts: [layout])
        #expect(ids == [
            "stage-logo",
            "countdown-video",
            "lyrics-bg", "lower-1", "wide-1",
            "series-bg", "deck-bg", "lower-1", "wide-1", "lower-2", "sting", "wide-2", "walk-in",
        ].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    }

    @Test func aSlidesLivestreamLowerThirdPictureIsLoaded() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.streamDesign = .lowerThirdImage("lower")
        let deck = Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "", slides: [slide])
        let ids = PlanPreloadPlan.mediaIDs(
            items: [item("i", .presentation, ref: "d")], decks: ["d": deck], themes: { _ in nil }, stageLayouts: [])
        #expect(ids == ["lower"])
    }

    @Test func theTypesActionsAndTheStreamsThemesBringTheirMedia() {
        let deck = Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "", slides: [])
        let themes = ["series": theme("series", media: "series-lower-third")]
        let ids = PlanPreloadPlan.mediaIDs(
            items: [item("i", .presentation, ref: "d")], decks: ["d": deck], themes: { themes[$0] },
            stageLayouts: [], streamThemeIDs: ["series", "gone"],
            typeActions: { _ in [SlideAction(id: "t", kind: .fireMedia, mediaId: "type-bumper")] })
        #expect(ids == ["type-bumper", "series-lower-third"])
    }

    @Test func aDeckMissingFromTheLibraryIsPassedOver() {
        let ids = PlanPreloadPlan.mediaIDs(
            items: [item("i", .presentation, ref: "gone"), item("v", .media, ref: "video")],
            decks: [:], themes: { _ in nil }, stageLayouts: [])
        #expect(ids == ["video"])
    }

    @Test func themesIncludeTheOnesTheLivestreamIsSentTo() {
        var slide = Slide(id: "s", name: "", objects: [])
        slide.themeId = "own"
        slide.streamDesign = StreamDesign(category: "", mode: .design, themeId: "picked")
        var deck = Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "lyrics", slides: [slide])
        deck.streamThemeId = "stream"
        let themes = ["lyrics": theme("lyrics", lowerThird: "lower-thirds", designs: ["bible"])]
        #expect(PlanPreloadPlan.themeIDs(of: deck) == ["lyrics", "stream", "own", "picked"])
        #expect(PlanPreloadPlan.themeIDs(of: deck, themes: { themes[$0] })
                == ["lyrics", "stream", "own", "picked", "lower-thirds", "bible"])
    }

    @Test func audioItemsAreListedOnceInOrder() {
        let ids = PlanPreloadPlan.audioIDs(items: [
            item("a", .audio, ref: "walk-in"), item("p", .presentation, ref: "d"),
            item("b", .audio, ref: "offering"), item("c", .audio, ref: "walk-in"), item("e", .audio, ref: ""),
        ])
        #expect(ids == ["walk-in", "offering"])
    }

    // MARK: Budgets

    @Test func smallMacsKeepTodaysCaution() {
        #expect(PlanPreloadPlan.budget(physicalMemory: 8 * gigabyte)
                == .init(pictures: Int(gigabyte), files: Int(2 * gigabyte)))
        #expect(PlanPreloadPlan.budget(physicalMemory: 16 * gigabyte)
                == .init(pictures: Int(2 * gigabyte), files: Int(4 * gigabyte)))
    }

    @Test func bigMacsHoldAWholePlan() {
        #expect(PlanPreloadPlan.budget(physicalMemory: 32 * gigabyte)
                == .init(pictures: Int(8 * gigabyte), files: Int(8 * gigabyte)))
        let big = PlanPreloadPlan.budget(physicalMemory: 64 * gigabyte)
        #expect(big == .init(pictures: Int(16 * gigabyte), files: Int(16 * gigabyte)))
        // A message of 150 slides, each a _Wide and a _LowerThird picture,
        // plus a dozen songs' backgrounds, fits several times over.
        let message = 300 * PlanPreloadPlan.pictureBytes(width: 1920, height: 1080)
        #expect(message * 5 < big.pictures)
    }

    @Test func playersStandByForTheWholePlanFrom32GB() {
        let small = PlanPreloadPlan.Players(limit: 6, itemsAhead: 3)
        #expect(PlanPreloadPlan.players(physicalMemory: 8 * gigabyte) == small, "as before")
        #expect(PlanPreloadPlan.players(physicalMemory: 16 * gigabyte) == small)
        #expect(PlanPreloadPlan.players(physicalMemory: 32 * gigabyte) == PlanPreloadPlan.Players(limit: 12, itemsAhead: nil))
        #expect(PlanPreloadPlan.players(physicalMemory: 64 * gigabyte) == PlanPreloadPlan.Players(limit: 12, itemsAhead: nil))
    }

    @Test func aPictureWithNoRecordedSizeCountsAsFullHD() {
        #expect(PlanPreloadPlan.pictureBytes(width: nil, height: nil) == 1920 * 1080 * 4)
        #expect(PlanPreloadPlan.pictureBytes(width: 3840, height: 2160) == 3840 * 2160 * 4)
    }
}
