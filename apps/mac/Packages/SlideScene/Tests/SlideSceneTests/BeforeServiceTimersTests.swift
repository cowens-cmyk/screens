import Foundation
import PresenterCore
import Testing
@testable import SlideScene

@Test func beforeServiceLayoutReadsTheTimerTheAppMakes() {
    #expect(ServiceTrackingTimers.id(.untilCountdown, .remaining) == ConfidenceLayoutTemplate.untilCountdownTimerID)
    #expect(ServiceTrackingTimers.id(.untilService, .remaining) == ConfidenceLayoutTemplate.untilServiceTimerID)
    let objects = ConfidenceLayoutTemplate.preService.make(name: "Before Service").objects
    #expect(objects.compactMap(\.textLink?.timerId) == [ConfidenceLayoutTemplate.untilServiceTimerID],
            "one timer, to the service's start")
}

private let stageNow = Date(timeIntervalSince1970: 2_000_000)

/// What the Before Service stage draws, as the render thread would, with the
/// app's Until Service timer in the state `timer` gives.
private func beforeServiceText(_ timer: TimerSnapshot, at date: Date = stageNow) -> [String] {
    var layout = ConfidenceLayoutTemplate.preService.make(name: "Before Service")
    layout.id = BasicTemplates.preServiceStageID
    let scene = ConfidenceSceneBuilder.scene(
        layout: layout, info: ConfidenceInfo(timers: [timer]), at: date)
    return (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled.string }
        return nil
    }
}

@Test func beforeServiceShowsOnlyTheCountdownToTheService() {
    let timer = ServiceTrackingTimers.until(.untilService, stageNow.addingTimeInterval(754), now: stageNow)
    #expect(beforeServiceText(timer) == ["SERVICE STARTS IN", "12:34"])
}

@Test func beforeServiceCountsDownAsTheClockMoves() {
    // It reads the wall clock, so the countdown video playing (or not)
    // makes no difference to it.
    let timer = ServiceTrackingTimers.until(.untilService, stageNow.addingTimeInterval(300), now: stageNow)
    #expect(beforeServiceText(timer, at: stageNow.addingTimeInterval(120)).last == "3:00")
    #expect(beforeServiceText(timer, at: stageNow.addingTimeInterval(299)).last == "0:01")
}

@Test func beforeServiceShowsHoursOverAnHour() {
    let timer = ServiceTrackingTimers.until(.untilService, stageNow.addingTimeInterval(3600 + 5 * 60 + 9), now: stageNow)
    #expect(beforeServiceText(timer).last == "1:05:09")
}

@Test func beforeServiceHoldsAtZeroWhenTheServiceTimePasses() {
    let timer = ServiceTrackingTimers.until(.untilService, stageNow.addingTimeInterval(30), now: stageNow)
    #expect(beforeServiceText(timer, at: stageNow.addingTimeInterval(45)) == ["SERVICE STARTS IN", "0:00"])
    // Rebuilt after the moment (the walk-in ran late): still 0:00, never negative.
    let late = ServiceTrackingTimers.until(
        .untilService, stageNow, now: stageNow.addingTimeInterval(90), holdsAtZero: true)
    #expect(beforeServiceText(late, at: stageNow.addingTimeInterval(95)) == ["SERVICE STARTS IN", "0:00"])
}

@Test func beforeServiceShowsTheClockWhenNoServiceIsLeft() {
    let none = ServiceTrackingTimers.until(.untilService, nil, now: stageNow, holdsAtZero: true)
    let text = beforeServiceText(none)
    #expect(text.count == 2)
    #expect(text.first == "TIME")
    #expect(!text.contains("SERVICE STARTS IN"))
    // A moment that passed without the hold is the same as none.
    let past = ServiceTrackingTimers.until(.untilService, stageNow.addingTimeInterval(-5), now: stageNow)
    #expect(beforeServiceText(past).first == "TIME")
}

@Test func theUntilTimerHoldsAtZeroOnlyWhenAskedTo() {
    let past = stageNow.addingTimeInterval(-60)
    #expect(!ServiceTrackingTimers.until(.untilService, past, now: stageNow).isRunning)
    let held = ServiceTrackingTimers.until(.untilService, past, now: stageNow, holdsAtZero: true)
    #expect(held.isRunning)
    #expect(held.value(at: stageNow.addingTimeInterval(500)) == 0)
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
