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
