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
