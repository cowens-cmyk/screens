import Foundation
import Testing

@testable import PresenterCore

private func object(named name: String, in layout: ConfidenceLayout) -> SlideObject? {
    layout.objects.first { $0.name == name }
}

private func frame(_ object: SlideObject) -> CGRect {
    CGRect(x: object.x ?? 0, y: object.y ?? 0, width: object.width ?? 0, height: object.height ?? 0)
}

// MARK: Worship

@Test func theWorshipLayoutPutsTheWordsFirst() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    let section = try #require(object(named: "Section", in: layout))
    let current = try #require(object(named: "Current Slide", in: layout))
    let next = try #require(object(named: "Next Slide", in: layout))
    let clock = try #require(object(named: "Clock", in: layout))
    let key = try #require(object(named: "Song Key", in: layout))
    let song = try #require(object(named: "Song", in: layout))

    #expect(section.textLink?.source == .currentGroup)
    #expect(section.textStyle?.textTransform == .uppercase)
    #expect(frame(section).maxX <= frame(current).minX, "the section name sits left of the words")
    #expect(frame(section).minY < frame(current).minY + 120, "beside the first line")
    #expect(section.textStyle?.horizontalAlignment == .left)
    #expect(current.textStyle?.horizontalAlignment == .left, "the words are left-aligned")
    #expect(next.textStyle?.horizontalAlignment == .left)
    #expect(frame(next).minX == frame(current).minX, "the next lines start where the words do")
    #expect((section.textStyle?.fontSize ?? 0) < (current.textStyle?.fontSize ?? 0) / 2)

    #expect(current.textStyle?.colorHex == ConfidenceLayoutTemplate.white, "white words, the most contrast")
    #expect(current.textStyle?.fontName == "HelveticaNeue-Bold")
    #expect((current.textStyle?.minFontSize ?? 0) >= 60, "never shrinks to tiny text")
    #expect(current.textStyle?.verticalAlignment == .top, "the first line always starts in the same place")
    #expect(current.textStyle?.keepLinesWhole == true)
    #expect(current.textStyle?.showChords == true)
    #expect(current.textStyle?.chordColorHex == ConfidenceLayoutTemplate.worshipAccent)

    #expect(next.textLink?.maxLines == 2, "just the next slide's first lines")
    #expect((next.textStyle?.fontSize ?? 0) < (current.textStyle?.fontSize ?? 0) * 0.7)
    #expect(next.textStyle?.colorHex != current.textStyle?.colorHex, "dimmer than the words being sung")
    #expect(frame(next).minY >= frame(current).maxY)

    for bottom in [clock, key, song] {
        #expect(frame(bottom).minY >= 1080 * 2 / 3, "\(bottom.name) is along the bottom")
    }
    #expect(song.textLink?.source == .currentPresentation)
    #expect(key.textStyle?.colorHex == ConfidenceLayoutTemplate.worshipAccent, "one accent colour")
}

@Test func theNextLabelOnlyShowsWhenThereIsANextSlide() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    let next = try #require(object(named: "Next Slide", in: layout))
    let label = try #require(layout.objects.first { $0.text == "NEXT" })
    let condition = try #require(label.visibilityConditions?.first)
    #expect(condition.conditionKind == .objectText)
    #expect(condition.state == .hasText)
    #expect(condition.objectId == next.id)
}

@Test func aStageMessageStillReplacesTheWorshipBottomBand() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    guard case .band(let band, let replaced) = StageMessagePlacement.style(for: layout) else {
        Issue.record("the Worship layout should use the bottom band")
        return
    }
    let ids = Set(layout.objects.filter { [.clock, .songKey].contains($0.textLink?.source) }.map(\.id))
    #expect(Set(replaced) == ids)
    #expect(band.minY == 960 && band.maxY == 1080 && band.width == 1920)
}

@Test func anUntouchedOldWorshipLayoutTakesTheNewDesignOnce() throws {
    var saved = ConfidenceLayoutTemplate.legacyWorship(name: "Stage — Worship")
    saved.id = "screens.stage.worship"
    let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
    let upgraded = try #require(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: stored))
    #expect(upgraded.contains { $0.textLink?.source == .currentGroup })
    var fresh = saved
    fresh.objects = upgraded
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: fresh) == nil, "once only")
}

@Test func anUntouchedCenteredWorshipLayoutTakesTheLeftAlignedOne() throws {
    var saved = ConfidenceLayoutTemplate.worship(name: "Stage — Worship", centered: true)
    saved.id = "screens.stage.worship"
    let upgraded = try #require(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: saved))
    let current = try #require(upgraded.first { $0.name == "Current Slide" })
    #expect(current.textStyle?.horizontalAlignment == .left)
    var fresh = saved
    fresh.objects = upgraded
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: fresh) == nil, "once only")

    var moved = saved
    moved.objects[1].x = (moved.objects[1].x ?? 0) + 10
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: moved) == nil, "a changed one is left alone")
}

@Test func aChangedWorshipLayoutIsLeftAlone() {
    let base = ConfidenceLayoutTemplate.legacyWorship(name: "Stage — Worship")
    var recolored = base
    recolored.objects[0].textStyle?.colorHex = "#FF0000FF"
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: recolored) == nil)
    var moved = base
    moved.objects[2].y = (moved.objects[2].y ?? 0) + 4
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: moved) == nil)
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(
        for: ConfidenceLayoutTemplate.sermon.make(name: "Stage — Worship")) == nil)
    #expect(ConfidenceLayoutTemplate.upgradedSermonObjects(for: base) == nil,
            "the old Worship layout is not mistaken for the old Message one")
}

// MARK: Video

@Test func theVideoLayoutShowsTheTimeLeftAboveTheVideoInTheMessageGreen() throws {
    let layout = ConfidenceLayoutTemplate.video.make(name: "Stage — Video")
    let message = ConfidenceLayoutTemplate.sermon.make(name: "Stage — Message")
    let remaining = try #require(object(named: "Video Remaining", in: layout))
    let box = try #require(object(named: ConfidenceLayoutTemplate.videoBoxName, in: layout))
    let messageTimer = try #require(object(named: "Sermon Timer", in: message))
    let messageClock = try #require(object(named: "Clock", in: message))

    #expect(remaining.textLink?.source == .videoCountdown)
    #expect(remaining.textLink?.showsVideoName == false)
    #expect(remaining.textLink?.usesWarningColor == false, "green to the end")
    #expect(remaining.textStyle?.colorHex == messageTimer.textStyle?.colorHex)
    #expect(remaining.textStyle?.fontName == messageTimer.textStyle?.fontName)
    #expect(frame(remaining).maxY <= frame(box).minY, "above the video")
    #expect(box.objectKind == .shape)
    #expect(abs(frame(box).width / frame(box).height - 16.0 / 9.0) < 0.01)

    let timer = try #require(object(named: "Sermon Timer", in: layout))
    let clock = try #require(object(named: "Clock", in: layout))
    #expect(timer.textLink?.timerId == SermonTimer.id)
    #expect(timer.textLink?.usesWarningColor == messageTimer.textLink?.usesWarningColor)
    #expect(timer.textStyle?.colorHex == messageTimer.textStyle?.colorHex)
    #expect(timer.textStyle?.fontName == messageTimer.textStyle?.fontName)
    #expect(clock.textStyle?.colorHex == messageClock.textStyle?.colorHex)
    #expect(clock.textStyle?.fontName == messageClock.textStyle?.fontName)
    #expect(clock.textLink?.clockFormat == messageClock.textLink?.clockFormat)
    for strip in [timer, clock] {
        #expect(frame(strip).minY >= frame(box).maxY, "\(strip.name) is under the video")
        #expect((strip.textStyle?.fontSize ?? 0) < (messageTimer.textStyle?.fontSize ?? 0) / 2, "smaller")
    }
}

@Test func theVideoLayoutIsOfferedAsATemplate() {
    #expect(ConfidenceLayoutTemplate.video.title == "Video")
    #expect(ConfidenceLayoutTemplate.allCases.contains(.video))
}
