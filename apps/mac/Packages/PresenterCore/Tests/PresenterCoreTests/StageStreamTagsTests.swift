import Foundation
@testable import PresenterCore
import Testing

struct StageStreamTagsTests {
    private func video(_ id: String, loops: Bool = false) -> MediaItem {
        var item = MediaItem(
            id: id, name: id, mediaKind: .video, classification: .foreground, fileHash: "h", fileName: "\(id).mov",
            fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: loops)
        item.durationSeconds = 30
        return item
    }

    private func picture(_ id: String) -> MediaItem {
        MediaItem(
            id: id, name: id, mediaKind: .image, classification: .foreground, fileHash: "h", fileName: "\(id).png",
            fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: false)
    }

    private func deck(_ id: String, category: String? = nil, kind: PresentationKind = .deck, themeId: String = "plain", slides: [Slide]) -> Presentation {
        var deck = Presentation(id: id, name: id, presentationKind: kind, themeId: themeId, slides: slides)
        deck.category = category
        return deck
    }

    private func slide(_ id: String, background: String? = nil, stream: StreamDesign? = nil, actions: [SlideAction]? = nil) -> Slide {
        Slide(
            id: id, name: id, objects: [],
            background: background.map { CueMedia(mediaId: $0, layer: .videos, classification: .foreground) },
            actions: actions, streamDesign: stream)
    }

    private func library(
        _ decks: [Presentation], media: [MediaItem] = [], themes: [Theme] = [], settings: SlideBuildingSettings? = nil
    ) -> StageStreamTags.Library {
        StageStreamTags.Library(
            presentation: { id in decks.first { $0.id == id } },
            media: { id in media.first { $0.id == id } },
            theme: { id in themes.first { $0.id == id } },
            settings: settings)
    }

    private func item(_ id: String, ref: String, kind: ServiceItemKind = .presentation) -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: id, refId: ref)
    }

    private let lyricsTheme = Theme(
        id: "lyrics", name: "Lyrics", fontFamily: "", fontSize: 1, textColorHex: "", backgroundColorHex: "",
        streamDesigns: [StreamDesign(category: "", mode: .design, themeId: "lt")])
    private let plainTheme = Theme(id: "plain", name: "Plain", fontFamily: "", fontSize: 1, textColorHex: "", backgroundColorHex: "")

    @Test func aSongShowsLyricsOnStageAndItsThemesLowerThird() {
        let song = deck("song", kind: .song, themeId: "lyrics", slides: [slide("a"), slide("b")])
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("i", ref: "song"), item("x", ref: "other")])
        let tags = StageStreamTags.tags(for: plan.items[0], in: plan, library: library([song], themes: [lyricsTheme]))
        #expect(tags == .init(stage: "Lyrics + chords", stream: "Lyrics lower third"))
    }

    @Test func theAnnouncementsKeepTheirStageThroughTheirVideos() {
        let logo = video("logo")
        let announcements = deck("ann", category: PresentationTypes.announcements, slides: [slide("logo", background: "logo")])
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("i", ref: "ann"), item("x", ref: "other")])
        let tags = StageStreamTags.tags(for: plan.items[0], in: plan, library: library([announcements], media: [logo]))
        #expect(tags?.stage == "Announcements")
        #expect(tags?.stream == "Full screen")
    }

    @Test func theMessageShowsTheTimerAndFollowsTheSeries() {
        let message = deck("msg", category: PresentationTypes.sermon, slides: [slide("a")])
        var plan = Service(id: "p", name: "", serviceDate: "", items: [item("m", ref: "msg"), item("c", ref: "close")])
        let lib = library([message], themes: [plainTheme])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stage == "Message timer")
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stream == "Camera only")
        plan.sermonThemeId = "series"
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stream == "Series lower third")
    }

    @Test func sermonSlidesWithPicturesShowThemOrVary() {
        let slides = [
            slide("1", stream: .lowerThirdImage("lt1")),
            slide("2", stream: .lowerThirdImage("lt2")),
        ]
        let message = deck("msg", category: PresentationTypes.sermon, slides: slides)
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("m", ref: "msg"), item("z", ref: "z")])
        let lib = library([message], themes: [plainTheme])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stream == "Lower third picture")

        let mixed = deck("msg", category: PresentationTypes.sermon, slides: slides + [slide("3")])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([mixed], themes: [plainTheme]))?.stream
            == "Varies by slide")
        #expect(StageStreamTags.tags(for: mixed.slides[0], of: plan.items[0], in: plan, library: library([mixed]))?.stream
            == "Lower third picture")
    }

    @Test func aBumperVideoTakesTheStreamAndShowsTimeLeft() {
        let transition = deck("t", slides: [slide("v", background: "bumper")])
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("t", ref: "t"), item("m", ref: "m")])
        let tags = StageStreamTags.tags(for: plan.items[0], in: plan, library: library([transition], media: [video("bumper")]))
        #expect(tags == .init(stage: "Video time left", stream: "Full screen"))

        let media = Service(id: "p", name: "", serviceDate: "", items: [item("v", ref: "bumper", kind: .media)])
        #expect(StageStreamTags.tags(for: media.items[0], in: media, library: library([], media: [video("bumper")]))
            == .init(stage: "Video time left", stream: "Full screen"))
        #expect(StageStreamTags.tags(for: media.items[0], in: media, library: library([], media: [video("bumper", loops: true)]))
            == .init(stage: "No change", stream: "No change"))
        #expect(StageStreamTags.tags(for: media.items[0], in: media, library: library([], media: [picture("bumper")]))
            == .init(stage: "No change", stream: "No change"))
    }

    @Test func actionsAndOwnLayoutsWin() {
        let fullScreen = SlideAction(id: "a", kind: .setStreamMode, streamMode: "fullScreen")
        let toMessage = SlideAction(id: "b", kind: .setStageMode, stageMode: "message")
        let walkout = deck("w", slides: [slide("logo", actions: [fullScreen, toMessage])])
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("w", ref: "w")])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([walkout]))
            == .init(stage: "Message timer", stream: "Full screen"))

        var own = walkout
        own.stageLayoutId = "custom"
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([own]))?.stage == "Own layout")
    }

    @Test func preServiceAndTheLastItem() {
        let pre = deck("pre", slides: [slide("a")])
        let logo = deck("logo", slides: [slide("a")])
        var pi = item("pre", ref: "pre")
        pi.isPreService = true
        let plan = Service(id: "p", name: "", serviceDate: "", items: [pi, item("mid", ref: "logo"), item("end", ref: "logo")])
        let lib = library([pre, logo], themes: [plainTheme])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stage == "Before service")
        #expect(StageStreamTags.tags(for: plan.items[1], in: plan, library: lib)?.stage == "No change")
        #expect(StageStreamTags.tags(for: plan.items[2], in: plan, library: lib)?.stage == "Before service")
    }

    @Test func theWalkoutIsBeforeServiceOnEverySlideAndWhereverItSits() {
        let loop = deck("loop", slides: [slide("a"), slide("b")])
        var walkout = item("w", ref: "loop")
        walkout.isWalkout = true
        // Not last in the plan, and not a sermon or a song: only the item says so.
        let plan = Service(id: "p", name: "", serviceDate: "", items: [walkout, item("z", ref: "other")])
        let lib = library([loop], themes: [plainTheme])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: lib)?.stage == "Before service")
        #expect(StageStreamTags.tags(for: loop.slides[0], of: plan.items[0], in: plan, library: lib)?.stage == "Before service")

        // Service Day's walkout presentation counts without the item flag.
        var settings = SlideBuildingSettings(id: "s")
        settings.serviceDay = ServiceDaySettings(services: [], walkoutPresentationId: "loop")
        let plain = Service(id: "p", name: "", serviceDate: "", items: [item("w", ref: "loop"), item("z", ref: "other")])
        #expect(StageStreamTags.tags(for: plain.items[0], in: plain, library: library([loop], themes: [plainTheme], settings: settings))?.stage == "Before service")
        #expect(StageStreamTags.tags(for: plain.items[0], in: plain, library: library([loop], themes: [plainTheme]))?.stage == "No change")

        // Its own stage layout still wins, as for the walk-in.
        var own = loop
        own.stageLayoutId = "custom"
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([own], themes: [plainTheme]))?.stage == "Own layout")
    }

    @Test func screensByTypeDecidesBeforeTheTheme() {
        var settings = SlideBuildingSettings(id: "s")
        settings.updateScreens(forType: PresentationTypes.worship) { $0.livestream = .audience }
        let song = deck("song", kind: .song, themeId: "lyrics", slides: [slide("a")])
        let plan = Service(id: "p", name: "", serviceDate: "", items: [item("i", ref: "song"), item("z", ref: "z")])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([song], themes: [lyricsTheme], settings: settings))?.stream
            == "Full screen")
        var themed = song
        themed.streamThemeId = "x"
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([themed], settings: settings))?.stream
            == "Lower third")
    }

    @Test func headersHaveNoTags() {
        let plan = Service(id: "p", name: "", serviceDate: "", items: [ServiceItem(id: "h", itemKind: .header, name: "WORSHIP", refId: "")])
        #expect(StageStreamTags.tags(for: plan.items[0], in: plan, library: library([])) == nil)
    }
}
