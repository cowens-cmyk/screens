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
    #expect(current.textStyle?.horizontalAlignment == .left, "the words are left-aligned")
    #expect(next.textStyle?.horizontalAlignment == .left)
    #expect(frame(next).minX == frame(current).minX, "the next lines start where the words do")

    #expect(current.textStyle?.colorHex == ConfidenceLayoutTemplate.worshipOrange, "orange words, as ProPresenter had them")
    #expect(current.textStyle?.fontName == "HelveticaNeue-Bold")
    #expect((current.textStyle?.minFontSize ?? 0) >= 60, "never shrinks to tiny text")
    #expect(current.textStyle?.verticalAlignment == .top, "the first line always starts in the same place")
    #expect(current.textStyle?.keepLinesWhole == true)
    #expect(current.textStyle?.balancedWrap == true)
    #expect(current.textStyle?.showChords == true)
    #expect(current.textStyle?.chordNotation == .numbers)

    #expect(next.textLink?.maxLines == 3, "just the next slide's first lines")
    #expect((next.textStyle?.fontSize ?? 0) < (current.textStyle?.fontSize ?? 0))
    #expect(next.textStyle?.colorHex == ConfidenceLayoutTemplate.worshipNextGray, "grey, dimmer than the words being sung")
    #expect(frame(next).minY >= frame(current).maxY)

    for bottom in [clock, key, song] {
        #expect(frame(bottom).minY >= 1080 * 2 / 3, "\(bottom.name) is along the bottom")
        #expect(bottom.textStyle?.colorHex == ConfidenceLayoutTemplate.white)
        #expect(frame(bottom).minY >= frame(next).maxY, "\(bottom.name) is under the next lines")
    }
    #expect(clock.textLink?.source == .clock)
    #expect(clock.textLink?.clockFormat == "h:mm:ssa", "the clock shows seconds and AM/PM")
    #expect(song.textLink?.source == .currentPresentation)
    #expect(key.textLink?.source == .songKey)
    #expect(frame(clock).maxX <= frame(song).minX && frame(song).maxX <= frame(key).minX, "clock, song, key, left to right")

    // Each of the bar's words sits in its own slate box.
    let boxes = layout.objects.filter { $0.objectKind == .shape && $0.groupColorFill == nil }
    #expect(boxes.count == 3)
    for text in [clock, song, key] {
        #expect(boxes.contains { frame($0).contains(frame(text)) }, "\(text.name) has its box")
        #expect(boxes.allSatisfy { $0.fill?.colorHex == ConfidenceLayoutTemplate.worshipSlate })
    }
}

@Test func theWorshipLayoutHasASectionBlockBesideTheWordsAndTheNextLines() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    let current = try #require(object(named: "Current Slide", in: layout))
    let next = try #require(object(named: "Next Slide", in: layout))
    let section = try #require(object(named: "Section", in: layout))
    let nextSection = try #require(object(named: "Next Section", in: layout))
    let block = try #require(layout.objects.first { $0.groupColorFill == .current })
    let nextBlock = try #require(layout.objects.first { $0.groupColorFill == .next })

    #expect(nextSection.textLink?.source == .nextGroup)
    for (label, box, words) in [(section, block, current), (nextSection, nextBlock, next)] {
        #expect(frame(box).maxX <= frame(words).minX, "\(box.name) sits left of the words")
        #expect(frame(box).minY <= frame(words).minY, "\(box.name) is beside its words")
        #expect(label.rotationDegrees == -90, "\(label.name) reads bottom to top")
        #expect(label.textStyle?.colorHex == ConfidenceLayoutTemplate.white)
        #expect(label.textStyle?.fontName == "HelveticaNeue-Bold")
        #expect(label.textStyle?.textTransform == .uppercase)
        // Turned about its centre, the label is centred in the block.
        #expect(frame(label).midX == frame(box).midX && frame(label).midY == frame(box).midY)
        #expect(frame(label).width <= frame(box).height && frame(label).height <= frame(box).width)
        // The block shows only while its label has a section name.
        let condition = try #require(box.visibilityConditions?.first)
        #expect(condition.conditionKind == .objectText)
        #expect(condition.state == .hasText)
        #expect(condition.objectId == label.id)
        let boxPlace = try #require(layout.objects.firstIndex { $0.id == box.id })
        let labelPlace = try #require(layout.objects.firstIndex { $0.id == label.id })
        #expect(boxPlace < labelPlace, "the name draws over its block")
    }
    #expect(frame(block).maxY <= frame(nextBlock).minY, "the blocks are stacked")
}

@Test func aStageMessageStillReplacesTheWorshipBottomBand() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    guard case .band(let band, let replaced) = StageMessagePlacement.style(for: layout) else {
        Issue.record("the Worship layout should use the bottom band")
        return
    }
    let ids = Set(layout.objects.filter { [.clock, .songKey].contains($0.textLink?.source) }.map(\.id))
    #expect(Set(replaced) == ids)
    #expect(band.minY == 945 && band.maxY == 1080 && band.width == 1920, "over the whole bottom bar")
}

@Test func anUntouchedOldWorshipLayoutTakesTheNewDesignOnce() throws {
    var saved = ConfidenceLayoutTemplate.legacyWorship(name: "Stage — Worship")
    saved.id = "screens.stage.worship"
    let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
    let upgraded = try #require(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: stored))
    #expect(upgraded.contains { $0.textLink?.source == .nextGroup })
    var fresh = saved
    fresh.objects = upgraded
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: fresh) == nil, "once only")
}

@Test func anUntouchedEarlierWorshipLayoutTakesTheNewOne() throws {
    for centered in [true, false] {
        var saved = ConfidenceLayoutTemplate.previousWorship(name: "Stage — Worship", centered: centered)
        saved.id = "screens.stage.worship"
        let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
        let upgraded = try #require(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: stored))
        let current = try #require(upgraded.first { $0.name == "Current Slide" })
        #expect(current.textStyle?.colorHex == ConfidenceLayoutTemplate.worshipOrange)
        #expect(upgraded.contains { $0.groupColorFill == .next })
        var fresh = saved
        fresh.objects = upgraded
        #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: fresh) == nil, "once only")

        var moved = saved
        moved.objects[1].x = (moved.objects[1].x ?? 0) + 10
        #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: moved) == nil, "a changed one is left alone")
    }
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

// MARK: Next slide chords

@Test func theWorshipLayoutShowsChordsOnTheNextLinesAsOnTheCurrentSlide() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    let current = try #require(object(named: "Current Slide", in: layout))
    let next = try #require(object(named: "Next Slide", in: layout))
    #expect(next.textStyle?.showChords == true)
    #expect(next.textStyle?.chordNotation == current.textStyle?.chordNotation)
    #expect(next.textStyle?.chordColorHex == current.textStyle?.chordColorHex)
}

@Test func anUntouchedWorshipLayoutWithoutNextChordsTakesTheNewOne() throws {
    var saved = ConfidenceLayoutTemplate.worship(name: "Stage — Worship", nextChords: false)
    saved.id = "screens.stage.worship"
    #expect(saved.objects.first { $0.name == "Next Slide" }?.textStyle?.showChords == nil)
    let stored = try JSONDecoder().decode(ConfidenceLayout.self, from: JSONEncoder().encode(saved))
    let upgraded = try #require(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: stored))
    #expect(upgraded.first { $0.name == "Next Slide" }?.textStyle?.showChords == true)
    var fresh = saved
    fresh.objects = upgraded
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: fresh) == nil, "once only")
}

@Test func aSavedLayoutWithChordsOnlyOnTheCurrentSlideGetsThemOnTheNextToo() throws {
    // A Worship layout someone has moved a box in: not untouched, so the
    // template upgrade leaves it, but the next lines still get their chords.
    var saved = ConfidenceLayoutTemplate.worship(name: "Stage — Worship", nextChords: false)
    let index = try #require(saved.objects.firstIndex { $0.name == "Next Slide" })
    saved.objects[index].y = (saved.objects[index].y ?? 0) + 6
    #expect(ConfidenceLayoutTemplate.upgradedWorshipObjects(for: saved) == nil)

    let objects = try #require(ConfidenceLayoutTemplate.showingNextSlideChords(for: saved))
    let current = try #require(objects.first { $0.name == "Current Slide" })
    let next = try #require(objects.first { $0.name == "Next Slide" })
    #expect(next.textStyle?.showChords == true)
    #expect(next.textStyle?.chordNotation == .numbers)
    #expect(next.textStyle?.chordColorHex == current.textStyle?.chordColorHex, "the template's grey stand-in gives way")
    #expect(next.y == saved.objects[index].y, "nothing else about the box changes")

    var done = saved
    done.objects = objects
    #expect(ConfidenceLayoutTemplate.showingNextSlideChords(for: done) == nil, "once only")

    // A custom layout with a plain next box takes the current slide's look.
    var custom = ConfidenceLayoutTemplate.classic.make(name: "Mine")
    let currentBox = try #require(custom.objects.firstIndex { $0.textLink?.source == .currentSlide })
    custom.objects[currentBox].textStyle?.showChords = true
    custom.objects[currentBox].textStyle?.chordNotation = .chords
    custom.objects[currentBox].textStyle?.chordColorHex = "#FFCC00FF"
    let bare = try #require(ConfidenceLayoutTemplate.showingNextSlideChords(for: custom))
    let customNext = try #require(bare.first { $0.textLink?.source == .nextSlide })
    #expect(customNext.textStyle?.showChords == true)
    #expect(customNext.textStyle?.chordNotation == .chords)
    #expect(customNext.textStyle?.chordColorHex == "#FFCC00FF")
}

@Test func nextSlideChordsAreLeftAloneWhereTheyWereChosenOrCannotApply() throws {
    // Nothing to follow: the current slide shows no chords.
    let classic = ConfidenceLayoutTemplate.classic.make(name: "Classic")
    #expect(ConfidenceLayoutTemplate.showingNextSlideChords(for: classic) == nil)

    // Switched off by hand (false, not unset) stays off.
    var off = ConfidenceLayoutTemplate.worship(name: "Stage — Worship", nextChords: false)
    let next = try #require(off.objects.firstIndex { $0.name == "Next Slide" })
    off.objects[next].textStyle?.showChords = false
    #expect(ConfidenceLayoutTemplate.showingNextSlideChords(for: off) == nil)

    // A box that reads one named object of the next slide has no chords.
    var named = ConfidenceLayoutTemplate.worship(name: "Stage — Worship", nextChords: false)
    named.objects[next].textLink?.sourceObjectName = "Title"
    #expect(ConfidenceLayoutTemplate.showingNextSlideChords(for: named) == nil)
}
