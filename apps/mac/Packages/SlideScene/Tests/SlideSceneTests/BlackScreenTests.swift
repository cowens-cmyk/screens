import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func textSlide(_ id: String) -> Slide {
    Slide(id: id, name: id, objects: [SlideObject(id: "\(id)-text", objectKind: .text, name: "Text", text: "hi")])
}

private func buildSlide() -> Slide {
    let clicks = (0..<2).map { index in
        AnimationStep(
            id: "c\(index)", kind: .in, animation: .fade, trigger: .onClick, delaySeconds: nil,
            durationSeconds: 0.5, ramp: nil, ranges: [AnimationRange(line: index, column: 0, length: 3)])
    }
    return Slide(
        id: "build", name: "Build",
        objects: [SlideObject(
            id: "pts", objectKind: .text, name: "Points", text: "one\ntwo", animationSteps: clicks)])
}

private func live() -> ShowState {
    var show = ShowState()
    show.fire(slide: textSlide("a"), atHostTime: 1)
    show.setBlack(true)
    return show
}

@Test func blackStartsOffAndToggles() {
    var show = ShowState()
    #expect(!show.isBlack)
    show.toggleBlack()
    #expect(show.isBlack)
    show.toggleBlack()
    #expect(!show.isBlack)
}

@Test func blackKeepsWhatIsLiveSoItComesBackAsItWas() {
    let show = live()
    #expect(show.isBlack)
    #expect(show.liveSlide?.slide.id == "a")
    // The stage mirrors this scene, so black is applied to the outputs, not here.
    #expect(!(show.scene().layers.first { $0.kind == .slide }?.items.isEmpty ?? true))
}

@Test func clearingSlidesMediaOrALayerLeavesBlackOn() {
    var show = live()
    show.clear(function: .slides)
    show.clear(function: .media)
    show.clear(layer: .overlays)
    #expect(show.isBlack, "only Clear All, or something new going up, ends it")
}

@Test func clearAllEndsBlack() {
    var show = live()
    show.clearAll()
    #expect(!show.isBlack)
    var protected = live()
    protected.clearAll(protecting: [.videoInput])
    #expect(!protected.isBlack)
}

@Test func firingASlideEndsBlack() {
    var show = live()
    show.fire(slide: textSlide("b"), atHostTime: 2)
    #expect(!show.isBlack)
    #expect(show.liveSlide?.slide.id == "b")
}

@Test func refiringTheLiveSlideEndsBlackToo() {
    var show = live()
    show.fire(slide: textSlide("a"), atHostTime: 2)
    #expect(!show.isBlack)
}

@Test func firingMediaEndsBlackEvenWhenItIsAlreadyLive() {
    var show = ShowState()
    show.fire(media: CueMedia(mediaId: "ocean"), on: .loopingVideos)
    show.setBlack(true)
    show.fire(media: CueMedia(mediaId: "ocean"), on: .loopingVideos)
    #expect(!show.isBlack, "the same video fired again is still the operator asking to see it")
    show.setBlack(true)
    show.fire(media: CueMedia(mediaId: "fire"), on: .videos)
    #expect(!show.isBlack)
}

@Test func aMessageToTheStageAloneLeavesBlackOn() {
    var show = live()
    show.fire(alert: CueAlert(message: "Wrap up", behavior: .persist, target: .confidence))
    #expect(show.isBlack, "the stage is never blacked out, and typing to it mustn't bring the room back")
    #expect(show.stageAlert?.message == "Wrap up")
}

@Test func firingAnOverlayOrAlertEndsBlack() {
    var show = live()
    show.fire(overlay: Overlay(
        id: "l3", name: "Lower Third",
        objects: [SlideObject(id: "t", objectKind: .text, name: "Name", text: "Pastor")]))
    #expect(!show.isBlack)
    show.setBlack(true)
    show.fire(alert: CueAlert(message: "Nursery", behavior: .persist, target: .both))
    #expect(!show.isBlack)
}

@Test func firingAudioLeavesBlackOn() {
    var show = live()
    show.fire(audio: CueAudio(audioItemId: "walk-in"))
    #expect(show.isBlack, "music isn't on a screen")
}

@Test func aBuildStepForwardOrBackEndsBlack() {
    var show = ShowState()
    show.fire(slide: buildSlide(), atHostTime: 1)
    show.setBlack(true)
    let forward = show.advanceStep(atHostTime: 2)
    #expect(forward)
    #expect(!show.isBlack)
    show.setBlack(true)
    let back = show.unadvanceStep()
    #expect(back)
    #expect(!show.isBlack)
}

@Test func anAdvanceWithNothingToStepLeavesBlackForTheFireThatFollows() {
    var show = live()
    let stepped = show.advanceStep(atHostTime: 2)
    #expect(!stepped, "no builds on this slide, so Next fires the next one")
    #expect(show.isBlack)
}

@Test func editingTheLiveSlideDoesNotEndBlack() {
    var show = live()
    let presentation = Presentation(
        id: "p", name: "Song", presentationKind: .deck, themeId: "", slides: [textSlide("a")])
    show.presentationEdited(presentation)
    #expect(show.isBlack)
}
