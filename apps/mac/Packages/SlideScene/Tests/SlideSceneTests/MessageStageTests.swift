import Foundation
import PresenterCore
import Testing
@testable import SlideScene

private let now = Date(timeIntervalSince1970: 2_000_000)

private func sermon(id: String = SermonTimer.id, name: String = "Sermon", left seconds: Double) -> TimerSnapshot {
    TimerSnapshot(
        id: id, name: name, mode: .countdown, isRunning: true, runningSince: now,
        banked: 2400 - seconds, durationSeconds: 2400)
}

private func resolvedTimer(_ timers: [TimerSnapshot]) -> SlideObject? {
    let layout = ConfidenceLayoutTemplate.sermon.make(name: "Stage — Message")
    return LinkedText.resolvedObjects(layout.objects, info: ConfidenceInfo(timers: timers), at: now)
        .first { $0.name == "Sermon Timer" }
}

@Test func theMessageTimerIsGreenUntilZeroThenRed() throws {
    let plenty = try #require(resolvedTimer([sermon(left: 1500)]))
    #expect(plenty.text == "25:00")
    #expect(plenty.textStyle?.colorHex == "#30D158FF")

    let lastSeconds = try #require(resolvedTimer([sermon(left: 20)]))
    #expect(lastSeconds.textStyle?.colorHex == "#30D158FF", "no amber step on the message timer")

    let over = try #require(resolvedTimer([sermon(left: -65)]))
    #expect(over.text == "-1:05", "it keeps counting past zero")
    #expect(over.textStyle?.colorHex == TimerWarning.overtimeHex)
}

@Test func theMessageTimerShowsTheSermonTimerNotTheFirstRunning() throws {
    let walkIn = TimerSnapshot(
        id: "walk-in", name: "Walk-in", mode: .countdown, isRunning: true, runningSince: now,
        durationSeconds: 300)
    let resolved = try #require(resolvedTimer([walkIn, sermon(left: 1800)]))
    #expect(resolved.text == "30:00")
}

@Test func anOlderSermonTimerIsFoundByName() throws {
    let resolved = try #require(resolvedTimer([sermon(id: "made-before-the-fixed-id", left: 600)]))
    #expect(resolved.text == "10:00")
}
