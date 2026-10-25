import CoreGraphics
import Foundation
import Testing

@testable import PresenterCore

private let sent = Date(timeIntervalSince1970: 1_000_000)

@Test func aStageMessageShowsForThirtySecondsUnlessSetOtherwise() {
    #expect(StageMessageDuration.standard == .thirty)
    #expect(StageMessageDuration(stored: nil) == .thirty)
    #expect(StageMessageDuration(stored: 42) == .thirty, "a value this build doesn't offer")
    #expect(StageMessageDuration(stored: 0) == .untilCleared)
    #expect(StageMessageDuration(stored: 60) == .sixty)
    #expect(StageMessageDuration.allCases.map(\.title) == ["15 seconds", "30 seconds", "60 seconds", "Until cleared"])

    #expect(StageMessageTiming.expiry(firedAt: sent, duration: .thirty) == sent.addingTimeInterval(30))
    #expect(StageMessageTiming.expiry(firedAt: sent, duration: .fifteen) == sent.addingTimeInterval(15))
    #expect(StageMessageTiming.expiry(firedAt: sent, duration: .untilCleared) == nil)
}

@Test func itExpiresAtItsTimeAndNotBefore() {
    let ends = sent.addingTimeInterval(30)
    #expect(!StageMessageTiming.hasExpired(ends, at: sent.addingTimeInterval(29.9)))
    #expect(StageMessageTiming.hasExpired(ends, at: ends))
    #expect(!StageMessageTiming.hasExpired(nil, at: sent.addingTimeInterval(86_400)), "until cleared")
    #expect(StageMessageTiming.secondsLeft(expiresAt: ends, at: sent.addingTimeInterval(5.5)) == 25)
    #expect(StageMessageTiming.secondsLeft(expiresAt: ends, at: ends.addingTimeInterval(3)) == 0)
    #expect(StageMessageTiming.secondsLeft(expiresAt: nil, at: sent) == nil)
}

@Test func theMessageFadesInAndOutAroundItsTime() {
    let ends = sent.addingTimeInterval(30)
    let fade = StageMessageTiming.fadeSeconds
    #expect(StageMessageTiming.presence(firedAt: sent, expiresAt: ends, at: sent) == 0)
    #expect(abs(StageMessageTiming.presence(firedAt: sent, expiresAt: ends, at: sent.addingTimeInterval(fade / 2)) - 0.5) < 1e-6, "Date arithmetic is not exact")
    #expect(StageMessageTiming.presence(firedAt: sent, expiresAt: ends, at: sent.addingTimeInterval(10)) == 1)
    #expect(abs(StageMessageTiming.presence(firedAt: sent, expiresAt: ends, at: ends.addingTimeInterval(-fade / 2)) - 0.5) < 1e-6, "Date arithmetic is not exact")
    #expect(StageMessageTiming.presence(firedAt: sent, expiresAt: ends, at: ends) == 0)
    #expect(StageMessageTiming.presence(firedAt: sent, expiresAt: nil, at: sent.addingTimeInterval(3600)) == 1)
}

@Test func theWorshipBandBlinksThreeTimesThenHolds() {
    let period = StageMessageTiming.bandFlashPeriod
    var lit = 0
    var wasLit = false
    for step in 0..<200 {
        let now = sent.addingTimeInterval(Double(step) * 0.02)
        let isLit = StageMessageTiming.bandIsLit(firedAt: sent, at: now)
        if isLit, !wasLit { lit += 1 }
        wasLit = isLit
    }
    #expect(lit == StageMessageTiming.bandFlashes)
    #expect(StageMessageTiming.bandIsLit(firedAt: sent, at: sent))
    #expect(!StageMessageTiming.bandIsLit(firedAt: sent, at: sent.addingTimeInterval(period * 0.75)))
    #expect(!StageMessageTiming.bandIsLit(firedAt: sent, at: sent.addingTimeInterval(period * 3 + 0.01)), "steady red after")
}

@Test func theMessageLayoutTakesOverWithItsTimesInReadingOrder() throws {
    let layout = ConfidenceLayoutTemplate.sermon.make(name: "Stage — Message")
    guard case .takeover(let ids) = StageMessagePlacement.style(for: layout) else {
        Issue.record("the Message layout should be taken over")
        return
    }
    let names = ids.compactMap { id in layout.objects.first { $0.id == id }?.name }
    #expect(names == ["Sermon Timer", "Clock"], "the timer first, then the clock")
}

@Test func theWorshipLayoutKeepsItsLyricsAndReplacesTheClockAndKeyBand() throws {
    let layout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")
    guard case .band(let band, let replaced) = StageMessagePlacement.style(for: layout) else {
        Issue.record("the Worship layout should use the bottom band")
        return
    }
    let names = Set(replaced.compactMap { id in layout.objects.first { $0.id == id }?.name })
    #expect(names == ["Clock", "Song Key"])
    for lyric in layout.objects where [.currentSlide, .nextSlide].contains(lyric.textLink?.source) {
        let frame = CGRect(x: lyric.x ?? 0, y: lyric.y ?? 0, width: lyric.width ?? 0, height: lyric.height ?? 0)
        #expect(!frame.intersects(band), "\(lyric.name) must stay readable")
    }
    #expect(band.minX == 0 && band.width == 1920, "across the screen")
    #expect(band.maxY == 1080, "down to the bottom edge")
    #expect(band.minY == 960, "where the clock and key were")
}

@Test func aLayoutWithItsOwnStageMessageBoxKeepsIt() {
    var layout = ConfidenceLayoutTemplate.worship.make(name: "Custom")
    layout.objects.append(ConfidenceLayoutTemplate.linked(
        "Message", .stageMessage, x: 60, y: 300, width: 1800, height: 200, size: 80))
    #expect(StageMessagePlacement.style(for: layout) == .linkedObject)
}

@Test func otherLayoutsFallBackToTheTopBar() {
    // Classic: lyrics, and its clock sits at the top, not in a bottom band.
    #expect(StageMessagePlacement.style(for: ConfidenceLayoutTemplate.classic.make(name: "Classic")) == .banner)
    #expect(StageMessagePlacement.style(for: ConfidenceLayoutTemplate.blank.make(name: "Blank")) == .banner)
}

@Test func aBandThatWouldCoverLyricsShrinksToTheClock() throws {
    var layout = ConfidenceLayoutTemplate.worship.make(name: "Tight")
    let clock = try #require(layout.objects.firstIndex { $0.name == "Clock" })
    let next = try #require(layout.objects.firstIndex { $0.name == "Next Slide" })
    // The next slide runs along the bottom on the right, beside the clock.
    layout.objects[next].x = 700
    layout.objects[next].y = 900
    layout.objects[next].width = 1200
    layout.objects[next].height = 160
    layout.objects.removeAll { $0.name == "Song Key" }
    guard case .band(let band, _) = StageMessagePlacement.style(for: layout) else {
        Issue.record("still a band")
        return
    }
    let clockFrame = CGRect(
        x: layout.objects[clock].x ?? 0, y: layout.objects[clock].y ?? 0,
        width: layout.objects[clock].width ?? 0, height: layout.objects[clock].height ?? 0)
    #expect(band == clockFrame)
}

@Test func takeoverPlacesNeverOverlap() {
    for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 3840, height: 1080)] {
        for count in 0...4 {
            let frames = StageMessagePlacement.takeoverFrames(canvas: canvas, slots: count)
            #expect(frames.slots.count == count)
            #expect(!frames.message.intersects(frames.strip))
            #expect(frames.message.height > frames.strip.height * 3, "the message gets the main part")
            for slot in frames.slots {
                #expect(frames.strip.insetBy(dx: -0.001, dy: -0.001).contains(slot))
                #expect(!slot.intersects(frames.message))
            }
            for (index, slot) in frames.slots.enumerated() {
                for other in frames.slots.dropFirst(index + 1) {
                    #expect(!slot.intersects(other))
                }
            }
            #expect(CGRect(origin: .zero, size: canvas).contains(frames.strip))
        }
    }
}

