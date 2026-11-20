import Testing

@testable import PresenterCore

struct PlanItemCueTests {
    private let blue = PrismScene(id: "blue", name: "Blue Wash", note: 70)
    private let blackout = PrismScene(id: "blackout", name: "Blackout", note: 74)

    private func macro(_ id: String) -> SlideAction {
        var action = SlideAction(id: "m-\(id)", kind: .fireCombo)
        action.comboId = id
        return action
    }

    @Test func aCueDroppedOnTheItemBeatsItsPosition() {
        let actions = PrismScenes.settingItemScene(blue, in: nil) ?? []
        let cue = PlanItemCue.resolve(
            itemActions: actions, firstSlideActions: [], position: .song(2), combo: { _ in nil })
        #expect(cue == .scene(id: "blue", name: "Blue Wash", from: .item))
    }

    @Test func withNothingChosenItIsThePosition() {
        let cue = PlanItemCue.resolve(itemActions: [], firstSlideActions: [], position: .message, combo: { _ in nil })
        #expect(cue == .position(.message))
        #expect(PlanItemCue.resolve(itemActions: [], firstSlideActions: [], position: nil, combo: { _ in nil }) == nil)
    }

    @Test func theFirstSlidesOwnSceneLandsLastSoItShows() {
        let cue = PlanItemCue.resolve(
            itemActions: PrismScenes.settingItemScene(blue, in: nil) ?? [],
            firstSlideActions: [PrismScenes.action(for: blackout)], position: .song(1), combo: { _ in nil })
        #expect(cue == .scene(id: "blackout", name: "Blackout", from: .firstSlide))
    }

    @Test func aMacroThatCuesPrismIsNamed() {
        let combos: [String: (name: String, actions: [SlideAction])] = [
            "outer": ("Prayer", [macro("inner")]),
            "inner": ("Dim", [PrismScenes.action(for: blackout)]),
        ]
        let cue = PlanItemCue.resolve(
            itemActions: [macro("outer")], firstSlideActions: [], position: .song(1), combo: { combos[$0] })
        #expect(cue == .scene(id: "blackout", name: "Blackout", from: .macro("Prayer")))
    }

    @Test func settingASceneKeepsMacrosAndReplacesTheOldCue() {
        var actions = PrismScenes.settingItemScene(blue, in: [macro("walk")])
        actions = PrismScenes.settingItemScene(blackout, in: actions)
        #expect(actions?.count == 2)
        #expect(actions?.filter(PrismScenes.isPrism).map(\.prismCueId) == ["blackout"])
        #expect(PrismScenes.settingItemScene(nil, in: actions)?.map(\.comboId) == ["walk"])
        #expect(PrismScenes.settingItemScene(nil, in: PrismScenes.settingItemScene(blue, in: nil)) == nil)
    }

    @Test func dragPayloadsRoundTrip() {
        #expect(PrismScenes.draggedSceneID(PrismScenes.dragPayload(blue)) == "blue")
        #expect(PrismScenes.draggedSceneID("svc::abc") == nil)
        #expect(PrismScenes.draggedSceneID("prism-scene::") == nil)
    }

    @Test func theFirstSlideFollowsTheArrangement() {
        let deck = Presentation(
            id: "p", name: "Song", presentationKind: .song, themeId: "",
            slides: [
                Slide(id: "v1", name: "v1", objects: [], sectionId: "verse"),
                Slide(id: "c1", name: "c1", objects: [], sectionId: "chorus"),
            ],
            arrangements: [Arrangement(id: "a", name: "Chorus First", sectionIds: ["chorus", "verse"])])
        #expect(PlanItemCue.firstSlide(of: deck, arrangementId: "a")?.id == "c1")
        #expect(PlanItemCue.firstSlide(of: deck, arrangementId: nil)?.id == "v1")
    }
}
