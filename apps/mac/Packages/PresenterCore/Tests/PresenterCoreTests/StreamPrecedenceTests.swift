import Testing

@testable import PresenterCore

@Test func aSlideWithNoChoiceFollowsTheSwitch() {
    #expect(StreamPrecedence.decide(global: .lowerThird, slide: nil) == .themeRoute)
    #expect(StreamPrecedence.decide(global: .fullScreen, slide: nil) == .audience)
    #expect(StreamPrecedence.decide(global: .transparent, slide: nil) == .nothing)
}

@Test func aSlidesFullScreenTakesOverTheStreamWhateverTheSwitch() {
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        #expect(StreamPrecedence.decide(global: global, slide: .audience) == .audience)
    }
}

@Test func aSlidesLowerThirdShowsWhateverTheSwitch() {
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        #expect(StreamPrecedence.decide(global: global, slide: .design) == .slideDesign)
    }
}

@Test func aSlidesNothingClearsTheStreamButNeverAddsOverlaysToTransparent() {
    #expect(StreamPrecedence.decide(global: .lowerThird, slide: .clear) == .clear)
    #expect(StreamPrecedence.decide(global: .fullScreen, slide: .clear) == .clear)
    #expect(StreamPrecedence.decide(global: .transparent, slide: .clear) == .nothing)
}

@Test func aPlayingVideoTakesTheStreamFullScreenWhateverElseSays() {
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        for slide in [nil, StreamDesignMode.clear, .audience, .design] {
            #expect(StreamPrecedence.decide(global: global, slide: slide, video: .playing) == .audience)
            #expect(StreamPrecedence.decide(global: global, slide: slide, video: .over) == .nothing,
                    "a held last frame or a fade to black never sits over the camera")
            #expect(StreamPrecedence.decide(global: global, slide: slide, video: .none)
                    == StreamPrecedence.decide(global: global, slide: slide))
        }
    }
}

@Test func theVideoHoldEndsClearAndTheNextSlideDecides() {
    var hold = StreamVideoOverride()
    #expect(hold.phase == .none)
    hold.videoStarted("intro")
    #expect(hold.phase == .playing)
    hold.videoEnded("intro")
    #expect(hold.phase == .over)
    hold.slideWentLive()
    #expect(hold.phase == .none, "the slide's own choice, or the switch, from here")
}

@Test func onlyThePlayingVideoCanEndTheHold() {
    var hold = StreamVideoOverride()
    hold.videoStarted("first")
    hold.videoStarted("second")
    hold.videoEnded("first")
    #expect(hold.phase == .playing, "the replaced video ending says nothing about the new one")
    hold.videoEnded("second")
    #expect(hold.phase == .over)
}

@Test func aSlideOverTheVideoEndsTheHoldWithoutClearingTheStream() {
    var hold = StreamVideoOverride()
    hold.videoStarted("intro")
    hold.slideWentLive()
    // The slide swept the video off; its end arrives afterwards.
    hold.videoEnded("intro")
    #expect(hold.phase == .none)
}

@Test func choosingAStreamModeEndsTheHold() {
    var hold = StreamVideoOverride()
    hold.videoStarted("intro")
    hold.modeChosen()
    #expect(hold.phase == .none)
    hold.videoEnded("intro")
    #expect(hold.phase == .none, "the operator's pick stands after the video too")
}

@Test func aSlidesLowerThirdImageShowsWhateverTheSwitch() {
    let image = StreamDesign.lowerThirdImage("png-1")
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        #expect(StreamPrecedence.decide(global: global, design: image) == .slideImage(mediaID: "png-1"))
    }
}

@Test func theWholeChoiceDecidesLikeItsModeWhenItNamesNoImage() {
    let choices: [StreamDesign?] = [
        nil,
        StreamDesign(category: "", mode: .clear),
        StreamDesign(category: "", mode: .audience),
        StreamDesign(category: "", mode: .design),
        StreamDesign(category: "", mode: .design, themeId: "t", slideId: "s"),
        StreamDesign(category: "", mode: .design, mediaId: ""),
    ]
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        for choice in choices {
            #expect(StreamPrecedence.decide(global: global, design: choice)
                    == StreamPrecedence.decide(global: global, slide: choice?.mode))
        }
    }
}

@Test func aMediaIDOnlyCountsOnALowerThird() {
    // Full Screen or Nothing with a stale id left over is still that choice.
    #expect(StreamDesign(category: "", mode: .audience, mediaId: "png-1").lowerThirdImageID == nil)
    #expect(StreamDesign(category: "", mode: .clear, mediaId: "png-1").lowerThirdImageID == nil)
    #expect(StreamPrecedence.decide(
        global: .lowerThird, design: StreamDesign(category: "", mode: .clear, mediaId: "png-1")) == .clear)
}

@Test func aPlayingVideoStillBeatsALowerThirdImage() {
    let image = StreamDesign.lowerThirdImage("png-1")
    for global in [StreamPrecedence.GlobalMode.lowerThird, .fullScreen, .transparent] {
        #expect(StreamPrecedence.decide(global: global, design: image, video: .playing) == .audience)
        #expect(StreamPrecedence.decide(global: global, design: image, video: .over) == .nothing)
        #expect(StreamPrecedence.decide(global: global, design: image, video: .none) == .slideImage(mediaID: "png-1"))
    }
}
