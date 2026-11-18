import Foundation
import Testing
@testable import PresenterCore

@Suite struct PrismScenesTests {
    private let show = Data("""
    {"version":1,"cues":[
      {"id":"walkIn","name":"Walk-in","note":60,"looks":{}},
      {"id":"song1","name":"Song 1","note":62},
      {"id":"blackout","name":"Blackout"}
    ]}
    """.utf8)

    @Test func readsPrismsScenesInOrder() throws {
        let scenes = try #require(PrismScenes.scenes(fromShow: show))
        #expect(scenes.map(\.name) == ["Walk-in", "Song 1", "Blackout"])
        #expect(scenes.map(\.note) == [60, 62, nil])
        #expect(PrismScenes.scenes(fromShow: Data("{}".utf8)) == nil)
    }

    @Test func theCueTableStandsInWithPrismsIDs() {
        let scenes = PrismScenes.scenes(fromCueTable: LightingCueTable.defaults)
        #expect(scenes.first == PrismScene(id: "walkIn", name: "Walk-in", note: 60))
        #expect(scenes.contains(PrismScene(id: "song1", name: "Song 1", note: 62)))
    }

    @Test func aSlideCuesOneSceneAtATime() {
        let walkIn = PrismScene(id: "walkIn", name: "Walk-in", note: 60)
        let song = PrismScene(id: "song1", name: "Song 1", note: 62)
        let other = SlideAction(id: "x", kind: .clearAll)
        var slide = Slide(id: "s", name: "", objects: [])
        slide.actions = [other]
        slide = PrismScenes.setting(walkIn, on: slide, actionID: "a")
        slide = PrismScenes.setting(song, on: slide, actionID: "b")
        #expect(slide.actions?.map(\.id) == ["x", "b"])
        let cue = PrismScenes.cue(on: slide)
        #expect(cue?.prismCueId == "song1")
        #expect(cue?.midiDeviceId == PrismScenes.deviceID)
        #expect(cue?.midiNumber == 62)
        #expect(cue.map(PrismScenes.label) == "Prism: Song 1")
        slide = PrismScenes.setting(nil, on: slide)
        #expect(slide.actions?.map(\.id) == ["x"])
        slide = PrismScenes.setting(nil, on: PrismScenes.setting(nil, on: slide))
        slide.actions = []
        #expect(PrismScenes.setting(nil, on: slide).actions == nil)
    }

    @Test func theNoteFollowsTheSceneInPrism() {
        let action = PrismScenes.action(for: PrismScene(id: "song1", name: "Song 1", note: 62))
        #expect(PrismScenes.note(for: action, scenes: []) == 62)
        #expect(PrismScenes.note(for: action, scenes: [PrismScene(id: "song1", name: "Song 1", note: 80)]) == 80)
        #expect(PrismScenes.note(for: action, scenes: [PrismScene(id: "song1", name: "Song 1", note: nil)]) == nil)
    }

    @Test func olderSlidesCuesGoToPrismToo() {
        var older = SlideAction(id: "1", kind: .midiOut)
        older.midiDeviceId = PrismScenes.olderDeviceID
        older.midiNumber = 35
        #expect(PrismScenes.isPrism(older))
        #expect(PrismScenes.label(for: older) == "Prism: note 35")
        var console = SlideAction(id: "2", kind: .midiOut)
        console.midiDeviceId = "console"
        #expect(!PrismScenes.isPrism(console))
    }

    @Test func aMacroThatCuesPrismIsSeenThroughCombos() {
        let cue = PrismScenes.action(for: PrismScene(id: "song1", name: "Song 1", note: 62), id: "1")
        var other = SlideAction(id: "2", kind: .midiOut)
        other.midiDeviceId = "console"
        var fire = SlideAction(id: "3", kind: .fireCombo)
        fire.comboId = "outer"
        var loop = SlideAction(id: "4", kind: .fireCombo)
        loop.comboId = "loop"
        var fireInner = SlideAction(id: "5", kind: .fireCombo)
        fireInner.comboId = "inner"
        let combos: [String: [SlideAction]] = ["outer": [other, fireInner], "inner": [cue], "loop": [loop]]
        let lookup = { (id: String) in combos[id] }
        #expect(PrismScenes.cuesPrism([cue], combo: lookup))
        #expect(!PrismScenes.cuesPrism([other], combo: lookup))
        #expect(PrismScenes.cuesPrism([fire], combo: lookup))
        #expect(!PrismScenes.cuesPrism([loop], combo: lookup))
    }
}
