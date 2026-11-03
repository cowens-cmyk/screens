import Foundation
import PresenterCore
import Testing
@testable import SlideScene

@Test func beforeServiceLayoutReadsTheTimersTheAppMakes() {
    #expect(ServiceTrackingTimers.id(.untilCountdown, .remaining) == ConfidenceLayoutTemplate.untilCountdownTimerID)
    #expect(ServiceTrackingTimers.id(.untilService, .remaining) == ConfidenceLayoutTemplate.untilServiceTimerID)
    let ids = ConfidenceLayoutTemplate.preService.make(name: "Before Service").objects.compactMap(\.textLink?.timerId)
    #expect(ids == [ConfidenceLayoutTemplate.untilCountdownTimerID, ConfidenceLayoutTemplate.untilServiceTimerID])
}

@Test func untilTimersCountDownToTheirMomentAndStopAfterIt() {
    let now = Date()
    let running = ServiceTrackingTimers.until(.untilService, now.addingTimeInterval(600), now: now)
    #expect(running.isRunning)
    #expect(abs(running.value(at: now.addingTimeInterval(60)) - 540) < 0.5)
    #expect(running.name == "Until Service")
    let past = ServiceTrackingTimers.until(.untilService, now.addingTimeInterval(-5), now: now)
    #expect(!past.isRunning)
    #expect(!ServiceTrackingTimers.until(.untilCountdown, nil, now: now).isRunning)
    #expect(ServiceTrackingTimers.faces(of: .untilCountdown) == [.remaining])
}

@Test func untilTimersHoldAtZeroOnceTheMomentPasses() {
    let now = Date()
    let timer = ServiceTrackingTimers.until(.untilCountdown, now.addingTimeInterval(30), now: now)
    #expect(timer.value(at: now.addingTimeInterval(45)) == 0)
}

@Test func onlyTheLastRepeatOfAClosingChorusIsTheFinalSlide() {
    // V C C: the chorus slide appears twice, the second time last.
    let verse = Slide(id: "v", name: "Verse", objects: [])
    let chorus = Slide(id: "c", name: "Chorus", objects: [])
    let slides = [verse, chorus, chorus]
    #expect(!SlideSceneBuilder.isLastArranged(slideID: "c", occurrence: 1, in: slides))
    #expect(SlideSceneBuilder.isLastArranged(slideID: "c", occurrence: 2, in: slides))
    // Without an occurrence a repeated slide can't be told apart, so it isn't.
    #expect(!SlideSceneBuilder.isLastArranged(slideID: "c", occurrence: nil, in: slides))
    #expect(SlideSceneBuilder.isLastArranged(slideID: "c", occurrence: nil, in: [verse, chorus]))
    #expect(!SlideSceneBuilder.isLastArranged(slideID: "v", occurrence: nil, in: [verse, chorus]))
}
