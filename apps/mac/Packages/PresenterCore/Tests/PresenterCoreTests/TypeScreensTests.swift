import Foundation
import Testing

@testable import PresenterCore

private func deck(_ kind: PresentationKind = .deck, category: String? = nil, streamThemeId: String? = nil) -> Presentation {
    var presentation = Presentation(id: "p", name: "P", presentationKind: kind, themeId: "room", slides: [])
    presentation.category = category
    presentation.streamThemeId = streamThemeId
    return presentation
}

@Test func everyPresentationFallsUnderOneRow() {
    #expect(PresentationTypes.screensType(of: deck(.song)) == PresentationTypes.worship, "songs count as Worship")
    #expect(PresentationTypes.screensType(of: deck(category: "sermon")) == PresentationTypes.sermon)
    #expect(PresentationTypes.screensType(of: deck(category: PresentationTypes.bible)) == PresentationTypes.bible)
    #expect(PresentationTypes.screensType(of: deck(category: PresentationTypes.announcements)) == PresentationTypes.announcements)
    #expect(PresentationTypes.screensType(of: deck()) == PresentationTypes.other)
    #expect(PresentationTypes.screensType(of: deck(category: PresentationTypes.video)) == PresentationTypes.other)
    #expect(PresentationTypes.screensType(of: deck(category: "Baptism")) == PresentationTypes.other)
    #expect(PresentationTypes.screensTitle(PresentationTypes.sermon) == "Message")
    #expect(PresentationTypes.screensTitle(PresentationTypes.bible) == "Scripture")
}

@Test func theMessageFollowsTheSeriesAndEverythingElseItsThemeUntilChosen() {
    let settings = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
    #expect(settings.livestream(for: deck(category: PresentationTypes.sermon)) == .series)
    #expect(settings.livestream(for: deck(.song)) == .theme)
    #expect(settings.livestream(for: deck()) == .theme)
}

@Test func aChoiceIsStoredPerTypeAndTheDefaultStoresNothing() {
    var settings = SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID)
    settings.updateScreens(forType: PresentationTypes.worship) {
        $0.livestream = .design(themeId: "worship", slideId: "worship.lower")
    }
    #expect(settings.livestream(for: deck(.song)) == .design(themeId: "worship", slideId: "worship.lower"),
            "every song gets the Worship lower third")
    #expect(settings.livestream(for: deck(category: PresentationTypes.sermon)) == .series, "other types are untouched")

    settings.updateScreens(forType: PresentationTypes.sermon) { $0.livestream = .theme }
    #expect(settings.livestream(for: deck(category: PresentationTypes.sermon)) == .theme)

    settings.updateScreens(forType: PresentationTypes.worship) { $0.livestream = .theme }
    settings.updateScreens(forType: PresentationTypes.sermon) { $0.livestream = .series }
    #expect(settings.typeScreens == nil, "an untouched church stores nothing")
}

@Test func aWholeThemeIsStoredWithoutADesign() {
    var row = PresentationTypeScreens(category: PresentationTypes.bible)
    row.livestream = .design(themeId: "scripture", slideId: nil)
    #expect(row.stream == "design" && row.streamThemeId == "scripture" && row.streamSlideId == nil)
    #expect(row.livestream == .design(themeId: "scripture", slideId: nil))
    row.livestream = .clear
    #expect(row.streamThemeId == nil, "nothing left over from the design")
}

@Test func aChoiceFromANewerBuildReadsAsTheDefault() throws {
    let json = #"{"id":"slide-building-settings","typeScreens":[{"category":"Sermon","stream":"hologram"},{"category":"Worship","stream":"design"}]}"#
    let settings = try JSONDecoder().decode(SlideBuildingSettings.self, from: Data(json.utf8))
    #expect(settings.livestream(for: deck(category: PresentationTypes.sermon)) == .series)
    #expect(settings.livestream(for: deck(.song)) == .theme, "a design with no theme falls back too")
}

// MARK: Precedence

@Test func thePresentationsOwnLivestreamThemeBeatsItsType() {
    let decided = StreamPrecedence.source(
        presentationStreamThemeId: "song-own", type: .design(themeId: "worship", slideId: "lower"), seriesThemeId: "fall")
    #expect(decided.source == .theme(id: "song-own"))
    #expect(decided.origin == .presentation)
}

@Test func theTypeBeatsTheSlidesTheme() {
    let one = StreamPrecedence.source(
        presentationStreamThemeId: nil, type: .design(themeId: "worship", slideId: "lower"), seriesThemeId: nil)
    #expect(one.source == .design(themeId: "worship", slideId: "lower"))
    #expect(one.origin == .type)
    let whole = StreamPrecedence.source(presentationStreamThemeId: "", type: .design(themeId: "worship", slideId: nil), seriesThemeId: nil)
    #expect(whole.source == .theme(id: "worship"))
    #expect(StreamPrecedence.source(presentationStreamThemeId: nil, type: .audience, seriesThemeId: nil).source == .audience)
    #expect(StreamPrecedence.source(presentationStreamThemeId: nil, type: .clear, seriesThemeId: nil).source == .clear)
    let theme = StreamPrecedence.source(presentationStreamThemeId: nil, type: .theme, seriesThemeId: "fall")
    #expect(theme.source == .slideTheme)
    #expect(theme.origin == .slideTheme)
}

@Test func theMessageUsesThePlansSeriesAndFallsBackToItsTheme() {
    let series = StreamPrecedence.source(presentationStreamThemeId: nil, type: .series, seriesThemeId: "fall")
    #expect(series.source == .theme(id: "fall"))
    #expect(series.origin == .type)
    #expect(StreamPrecedence.source(presentationStreamThemeId: nil, type: .series, seriesThemeId: nil).source == .slideTheme,
            "no series: the slide's theme still has a say")
}

@Test func aSlidesLowerThirdPassesOverTheTypesFullScreenAndNothing() {
    for type in [TypeStream.audience, .clear] {
        #expect(StreamPrecedence.source(
            presentationStreamThemeId: nil, type: type, seriesThemeId: nil, lowerThirdOnly: true).source == .slideTheme)
    }
    #expect(StreamPrecedence.source(
        presentationStreamThemeId: nil, type: .design(themeId: "t", slideId: "s"), seriesThemeId: nil,
        lowerThirdOnly: true).source == .design(themeId: "t", slideId: "s"),
        "a slide's plain Lower Third takes its type's lower third")
}

@Test func theSwitchAndTheSlideStillComeFirst() {
    // The type default lives inside the theme route: Full Screen,
    // Transparent and a slide's own choice decide before it's asked.
    #expect(StreamPrecedence.decide(global: .fullScreen, design: nil, video: .none) == .audience)
    #expect(StreamPrecedence.decide(global: .transparent, design: nil, video: .none) == .nothing)
    #expect(StreamPrecedence.decide(global: .lowerThird, design: nil, video: .none) == .themeRoute)
    #expect(StreamPrecedence.decide(global: .lowerThird, design: .init(category: "", mode: .clear), video: .none) == .clear)
    #expect(StreamPrecedence.decide(global: .lowerThird, design: nil, video: .playing) == .audience, "the video hold still wins")
}
