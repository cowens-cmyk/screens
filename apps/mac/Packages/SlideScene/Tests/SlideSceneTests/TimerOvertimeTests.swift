import Foundation
import PresenterCore
import Testing
@testable import SlideScene

private let now = Date(timeIntervalSince1970: 1_784_800_000)

private func countdown(elapsed: TimeInterval, of length: TimeInterval, keepCounting: Bool? = nil) -> TimerSnapshot {
    TimerSnapshot(
        id: "t", name: "Sermon", mode: .countdown,
        banked: elapsed, durationSeconds: length,
        keepsCountingAfterZero: keepCounting
    )
}

private func info(_ timer: TimerSnapshot) -> ConfidenceInfo {
    ConfidenceInfo(timers: [timer])
}

@Test func countdownRunsPastZeroAndCountsUpWithAMinus() {
    #expect(countdown(elapsed: 307, of: 300).displayString(at: now) == "-0:07")
    #expect(countdown(elapsed: 383, of: 300).displayString(at: now) == "-1:23")
    #expect(countdown(elapsed: 300 + 3725, of: 300).displayString(at: now) == "-1:02:05")
    #expect(countdown(elapsed: 383, of: 300).displayString(at: now, format: .abbreviated) == "-1m 23s")
    #expect(countdown(elapsed: 383, of: 300).displayString(at: now, format: nil, pattern: "mm:ss") == "-01:23")
}

@Test func runningCountdownKeepsGoingNegative() {
    let started = now.addingTimeInterval(-70)
    let timer = TimerSnapshot(
        id: "t", name: "T", mode: .countdown, isRunning: true,
        runningSince: started, durationSeconds: 60
    )
    #expect(timer.value(at: now) == -10)
    #expect(timer.displayString(at: now) == "-0:10")
    #expect(timer.isOvertime(at: now))
}

@Test func countdownToTimeGoesNegativePastTheTarget() {
    let timer = TimerSnapshot(
        id: "t", name: "Until", mode: .countdownToTime,
        targetTime: now.addingTimeInterval(-42), armedAt: now.addingTimeInterval(-600)
    )
    #expect(timer.displayString(at: now) == "-0:42")
    #expect(timer.isOvertime(at: now))
}

@Test func holdingAtZeroWhenTheOptionIsOff() {
    let timer = countdown(elapsed: 383, of: 300, keepCounting: false)
    #expect(timer.value(at: now) == 0)
    #expect(timer.displayString(at: now) == "0:00")
    #expect(!timer.isOvertime(at: now))
}

@Test func nilMeansKeepCounting() {
    #expect(countdown(elapsed: 383, of: 300).countsPastZero)
    #expect(countdown(elapsed: 383, of: 300, keepCounting: true).countsPastZero)
    #expect(!countdown(elapsed: 383, of: 300, keepCounting: false).countsPastZero)
}

@Test func overtimeOnlyOncePastZero() {
    #expect(!countdown(elapsed: 299, of: 300).isOvertime(at: now))
    #expect(!countdown(elapsed: 300, of: 300).isOvertime(at: now))
    #expect(countdown(elapsed: 301, of: 300).isOvertime(at: now))
    #expect(!TimerSnapshot(name: "Up", mode: .countUp, banked: 500).isOvertime(at: now),
            "a count-up with no limit is never over")
}

@Test func overtimeInkOutranksWarningLevels() {
    var timer = countdown(elapsed: 310, of: 300)
    #expect(timer.inkHex(at: now) == TimerWarning.overtimeHex)
    #expect(timer.urgency(at: now) == .overrun)
    timer.warnings = []
    #expect(timer.inkHex(at: now) == TimerWarning.overtimeHex, "red even with no warning levels")
    #expect(timer.urgency(at: now) == .overrun)
    #expect(countdown(elapsed: 280, of: 300).inkHex(at: now) == TimerWarning.amberHex)
}

@Test func stageTextTurnsRedWhenOverTime() {
    var object = SlideObject(id: "o", objectKind: .text, name: "Timer", text: "")
    object.textLink = TextLink(source: .timer)
    object.textStyle = TextStyle(colorHex: "#FFFFFFFF")
    let out = LinkedText.resolvedObjects([object], info: info(countdown(elapsed: 383, of: 300)), at: now)
    #expect(out[0].text == "-1:23")
    #expect(out[0].textStyle?.colorHex == TimerWarning.overtimeHex)
}

@Test func overtimeRedWinsEvenWithWarningColorsOff() {
    var object = SlideObject(id: "o", objectKind: .text, name: "Timer", text: "")
    object.textLink = TextLink(source: .timer, usesWarningColor: false)
    object.textStyle = TextStyle(colorHex: "#FFFFFFFF")
    let over = LinkedText.resolvedObjects([object], info: info(countdown(elapsed: 383, of: 300)), at: now)
    #expect(over[0].textStyle?.colorHex == TimerWarning.overtimeHex)
    let warning = LinkedText.resolvedObjects([object], info: info(countdown(elapsed: 290, of: 300)), at: now)
    #expect(warning[0].textStyle?.colorHex == "#FFFFFFFF", "the opt-out still covers amber levels")
}

@Test func heldAtZeroKeepsTheZeroWarningNotOvertime() {
    let timer = countdown(elapsed: 383, of: 300, keepCounting: false)
    #expect(timer.inkHex(at: now) == TimerWarning.redHex)
}
