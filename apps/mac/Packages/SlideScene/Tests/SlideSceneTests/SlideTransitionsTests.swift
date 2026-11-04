import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

/// The pre-service slideshow: slides made from videos and pictures, each
/// the media alone with nothing on the slide layer.
private func mediaSlide(_ id: String, video: Bool = true) -> Slide {
    Slide(
        id: id, name: id, objects: [],
        background: CueMedia(
            mediaId: id, layer: video ? .videos : .stillGraphics,
            loops: false, classification: .foreground))
}

private let slideshow = Presentation(
    id: "pre", name: "Pre-Service", presentationKind: .deck, themeId: "",
    slides: [mediaSlide("intro"), mediaSlide("welcome"), mediaSlide("kids"), mediaSlide("dinner", video: false)])

private let slideDefault = SlideTransitions.scene(from: Transition(transitionKind: .dissolve, durationSeconds: 0.2))

/// Fires `from`, then `to`, through the transition engine as the app does,
/// and returns the engine mid-change.
private func take(_ from: Slide, _ to: Slide) -> SceneTransitionEngine {
    var show = ShowState()
    show.fire(slide: from, presentation: slideshow)
    let engine = SceneTransitionEngine(initial: show.scene())
    let before = show.liveMedia
    show.fire(slide: to, presentation: slideshow)
    let carried = SlideTransitions.carried(slideDefault, from: before, to: show.liveMedia)
    engine.push(show.scene()) { carried[$0] ?? ($0 == .slide ? slideDefault : nil) }
    return engine
}

@Test func videoSlideToVideoSlideDissolvesAtTheSlideTransition() {
    let engine = take(mediaSlide("intro"), mediaSlide("welcome"))
    #expect(engine.transition(on: .videos) == SceneTransition(kind: .dissolve, duration: 0.2))
    #expect(engine.heldMediaIDs() == ["intro"], "the outgoing clip plays on through the dissolve")
}

@Test func videoSlideToPictureSlideDissolvesBothLayers() {
    let engine = take(mediaSlide("kids"), mediaSlide("dinner", video: false))
    #expect(engine.transition(on: .videos) == SceneTransition(kind: .dissolve, duration: 0.2))
    #expect(engine.transition(on: .stillGraphics) == SceneTransition(kind: .dissolve, duration: 0.2))
}

@Test func loopingBackToTheFirstVideoSlideDissolves() {
    let engine = take(mediaSlide("dinner", video: false), mediaSlide("intro"))
    #expect(engine.transition(on: .videos) == SceneTransition(kind: .dissolve, duration: 0.2))
    #expect(engine.transition(on: .stillGraphics) == SceneTransition(kind: .dissolve, duration: 0.2))
}

@Test func slideTransitionTravelsOnlyWithMediaTheSlideChanged() {
    let ocean = CueMedia(mediaId: "ocean", mode: .untilReplaced, layer: .loopingVideos)
    let carried = SlideTransitions.carried(
        slideDefault, from: [.loopingVideos: ocean], to: [.loopingVideos: ocean])
    #expect(carried.isEmpty, "a background that stays up isn't redrawn")
    #expect(SlideTransitions.carried(nil, from: [:], to: [.videos: ocean]).isEmpty)
}

@Test func storedTransitionsMapAsBefore() {
    #expect(SlideTransitions.scene(from: nil) == nil)
    #expect(SlideTransitions.scene(from: Transition(transitionKind: .dissolve, durationSeconds: 0)) == .cut)
    #expect(SlideTransitions.scene(from: Transition(transitionKind: .cut)) == .cut)
    #expect(SlideTransitions.scene(from: Transition(transitionKind: .fadeBlack, durationSeconds: 1))
        == SceneTransition(kind: .fade(.black), duration: 1))
}
