import Foundation
import Testing

@testable import PresenterCore

private func object(named name: String, in layout: ConfidenceLayout) -> SlideObject? {
    layout.objects.first { $0.name == name }
}

@Test func theMessageLayoutIsABigSermonTimerOverTheClock() throws {
    let layout = ConfidenceLayoutTemplate.sermon.make(name: "Stage — Message")
    let timer = try #require(object(named: "Sermon Timer", in: layout))
    let clock = try #require(object(named: "Clock", in: layout))
    #expect(timer.textLink?.source == .timer)
    #expect(timer.textLink?.timerId == SermonTimer.id, "the sermon timer, not whichever runs first")
    #expect(timer.textLink?.usesWarningColor == false, "green all the way down, red past zero")
    #expect(timer.textStyle?.colorHex == ConfidenceLayoutTemplate.messageGreen)
    #expect(timer.textStyle?.tabularFigures == true)
    #expect(clock.textLink?.source == .clock)
    #expect(clock.textStyle?.colorHex == ConfidenceLayoutTemplate.white)
    #expect((timer.y ?? 0) + (timer.height ?? 0) < (clock.y ?? 0), "the clock sits under the timer")
    #expect((timer.textStyle?.fontSize ?? 0) > (clock.textStyle?.fontSize ?? 0))
    let captions = layout.objects.filter { $0.name == "Caption" }.map(\.text)
    #expect(captions == ["MESSAGE", "TIME"])
}

@Test func anUntouchedOldMessageLayoutTakesTheNewDesign() throws {
    var saved = ConfidenceLayoutTemplate.legacySermon(name: "Stage — Message")
    saved.id = "screens.stage.message"
    let upgraded = try #require(ConfidenceLayoutTemplate.upgradedSermonObjects(for: saved))
    #expect(upgraded.contains { $0.textLink?.timerId == SermonTimer.id })
    var fresh = saved
    fresh.objects = upgraded
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: fresh) == nil, "once only")
}

@Test func anUntouchedOldMessageLayoutSurvivesTheRoundTrip() throws {
    // What the library hands back: encoded and decoded, as it was stored.
    let saved = ConfidenceLayoutTemplate.legacySermon(name: "Stage — Message")
    let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: stored) != nil)
}

@Test func aChangedMessageLayoutIsLeftAlone() {
    let base = ConfidenceLayoutTemplate.legacySermon(name: "Stage — Message")

    var moved = base
    moved.objects[1].x = (moved.objects[1].x ?? 0) + 10
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: moved) == nil)

    var recolored = base
    recolored.objects[1].textStyle?.colorHex = "#FF0000FF"
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: recolored) == nil)

    var added = base
    added.objects.append(ConfidenceLayoutTemplate.linked(
        "Extra", .clock, x: 0, y: 0, width: 10, height: 10, size: 10))
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: added) == nil)

    var resized = base
    resized.canvasWidth = 3840
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: resized) == nil)

    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(
        for: ConfidenceLayoutTemplate.worship.make(name: "Stage — Message")) == nil)
}

@Test func aRenamedButUntouchedMessageLayoutStillUpgrades() {
    let renamed = ConfidenceLayoutTemplate.legacySermon(name: "Pastor's Screen")
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: renamed) != nil)
}
