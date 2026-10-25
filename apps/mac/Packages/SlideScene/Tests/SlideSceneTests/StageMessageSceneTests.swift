import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let sent = Date(timeIntervalSince1970: 2_000_000)
private let ends = sent.addingTimeInterval(30)

private let messageLayout = ConfidenceLayoutTemplate.sermon.make(name: "Stage — Message")
private let worshipLayout = ConfidenceLayoutTemplate.worship.make(name: "Stage — Worship")

private func sermon(left seconds: Double) -> TimerSnapshot {
    TimerSnapshot(
        id: SermonTimer.id, name: "Sermon", mode: .countdown, isRunning: true, runningSince: sent,
        banked: 2400 - seconds, durationSeconds: 2400)
}

private func info(message: String? = "Wrap up in 5", expiresAt: Date? = ends, timerLeft: Double = 1500) -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "Amazing grace", musicKey: "G"),
        next: .init(body: "How sweet the sound"),
        alert: message.map {
            CueAlert(id: "msg", message: $0, behavior: .persist, target: .confidence, firedAt: sent, expiresAt: expiresAt)
        },
        timers: [sermon(left: timerLeft)])
}

private func items(_ scene: RenderScene, _ layer: LayerKind) -> [RenderItem] {
    scene.layers.first { $0.kind == layer }?.items ?? []
}

private func texts(_ scene: RenderScene, _ layer: LayerKind) -> [(item: RenderItem, text: StyledText)] {
    items(scene, layer).compactMap { item in
        if case .text(let text) = item.content { return (item, text) }
        return nil
    }
}

private func item(_ scene: RenderScene, _ layer: LayerKind, showing string: String) -> (item: RenderItem, text: StyledText)? {
    texts(scene, layer).first { $0.text.string == string }
}

// MARK: Message mode

@Test func withoutAMessageTheMessageStageIsUnchanged() throws {
    let scene = ConfidenceSceneBuilder.scene(layout: messageLayout, info: info(message: nil), at: sent)
    #expect(items(scene, .alerts).isEmpty)
    let timer = try #require(item(scene, .slide, showing: "25:00"))
    #expect(timer.item.frame.minY < 1080 * 0.5, "the timer fills the top as designed")
    #expect(item(scene, .slide, showing: "MESSAGE") != nil)
}

@Test func aMessageFillsTheMessageStageAndTheTimesMoveToTheBottom() throws {
    let at = sent.addingTimeInterval(5)
    let scene = ConfidenceSceneBuilder.scene(layout: messageLayout, info: info(), at: at)

    let message = try #require(item(scene, .alerts, showing: "Wrap up in 5"))
    #expect(message.item.frame.height > 1080 * 0.5, "the message gets the main part of the screen")
    #expect(message.item.frame.width > 1920 * 0.8)
    #expect(message.text.fontSize >= 200, "very large, shrinking only to fit")
    #expect(message.text.autoShrink)
    #expect(message.text.color == .white)
    #expect(message.item.opacity == 1)

    let timer = try #require(item(scene, .slide, showing: "24:55"), "the sermon timer keeps running")
    #expect(timer.text.color == ColorHex.color("#30D158FF"))
    #expect(timer.item.frame.minY >= 1080 * 0.75, "in the strip along the bottom")
    #expect(!timer.item.frame.intersects(message.item.frame))

    let clock = try #require(texts(scene, .slide).first { $0.item.id.contains("-strip") && $0.item.id != timer.item.id })
    #expect(clock.text.color == .white)
    #expect(clock.item.frame.minY == timer.item.frame.minY, "side by side")
    #expect(!clock.item.frame.intersects(timer.item.frame))
    #expect(!clock.item.frame.intersects(message.item.frame))
    #expect(clock.item.frame.minX > timer.item.frame.minX, "timer first, then the clock")

    #expect(item(scene, .slide, showing: "MESSAGE") == nil, "the captions step aside")
}

@Test func theStripTimerStillTurnsRedPastZero() throws {
    let scene = ConfidenceSceneBuilder.scene(
        layout: messageLayout, info: info(timerLeft: -60), at: sent.addingTimeInterval(5))
    let timer = try #require(item(scene, .slide, showing: "-1:05"))
    #expect(timer.text.color == ColorHex.color(TimerWarning.overtimeHex))
    #expect(timer.item.frame.minY >= 1080 * 0.75)
}

@Test func theMessageStageFadesInAndOut() throws {
    let fade = StageMessageTiming.fadeSeconds
    let arriving = ConfidenceSceneBuilder.scene(
        layout: messageLayout, info: info(), at: sent.addingTimeInterval(fade / 2))
    let message = try #require(item(arriving, .alerts, showing: "Wrap up in 5"))
    #expect(message.item.opacity > 0 && message.item.opacity < 1)
    let caption = try #require(item(arriving, .slide, showing: "MESSAGE"), "the usual look is fading out under it")
    #expect(caption.item.opacity > 0 && caption.item.opacity < 1)

    let leaving = ConfidenceSceneBuilder.scene(
        layout: messageLayout, info: info(), at: ends.addingTimeInterval(-fade / 4))
    let fading = try #require(item(leaving, .alerts, showing: "Wrap up in 5"))
    #expect(fading.item.opacity < 0.5)
}

@Test func afterItsTimeTheStageIsExactlyAsBefore() {
    let at = ends.addingTimeInterval(0.5)
    let after = ConfidenceSceneBuilder.scene(layout: messageLayout, info: info(), at: at)
    let without = ConfidenceSceneBuilder.scene(layout: messageLayout, info: info(message: nil), at: at)
    #expect(after == without, "the controls clear it a moment later; the stage doesn't wait for them")
}

@Test func aMessageThatStaysUntilClearedStaysUp() {
    let scene = ConfidenceSceneBuilder.scene(
        layout: messageLayout, info: info(expiresAt: nil), at: sent.addingTimeInterval(3600))
    #expect(item(scene, .alerts, showing: "Wrap up in 5") != nil)
}

@Test func aFlashingMessagesOffBeatKeepsTheTimesInTheStrip() throws {
    var flashing = info()
    flashing.alertVisible = false
    let scene = ConfidenceSceneBuilder.scene(layout: messageLayout, info: flashing, at: sent.addingTimeInterval(5))
    #expect(item(scene, .alerts, showing: "Wrap up in 5") == nil)
    let timer = try #require(item(scene, .slide, showing: "24:55"))
    #expect(timer.item.frame.minY >= 1080 * 0.75, "no jumping back and forth with each blink")
}

// MARK: Worship mode

@Test func withoutAMessageTheWorshipStageShowsClockAndKey() {
    let scene = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(message: nil), at: sent)
    #expect(item(scene, .slide, showing: "Key: G") != nil)
    #expect(items(scene, .alerts).isEmpty)
}

@Test func aMessageReplacesTheClockAndKeyAndLeavesTheLyrics() throws {
    let at = sent.addingTimeInterval(5)
    let before = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(message: nil), at: at)
    let scene = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(), at: at)

    for lyric in ["Amazing grace", "How sweet the sound"] {
        let shown = try #require(item(scene, .slide, showing: lyric))
        let usual = try #require(item(before, .slide, showing: lyric))
        #expect(shown.item.frame == usual.item.frame, "\(lyric) stays put")
        #expect(shown.item.opacity == usual.item.opacity)
        #expect(shown.text == usual.text)
    }
    #expect(item(scene, .slide, showing: "Key: G") == nil, "the key gives its place to the message")
    let clockIDs = Set(worshipLayout.objects.filter { $0.textLink?.source == .clock }.map(\.id))
    #expect(!items(scene, .slide).contains { item in clockIDs.contains { item.id.contains($0) } })

    let message = try #require(item(scene, .alerts, showing: "Wrap up in 5"))
    #expect(message.text.color == .white)
    let band = try #require(items(scene, .alerts).first { $0.id.hasPrefix("stage-band-msg") && !$0.id.contains("text") })
    #expect(band.content == .shape(ShapeStyle(kind: .rectangle, fill: .solid(ConfidenceSceneBuilder.stageRed))))
    #expect(band.frame.minY == 960 && band.frame.maxY == 1080)
    for lyric in ["Amazing grace", "How sweet the sound"] {
        let shown = try #require(item(scene, .slide, showing: lyric))
        #expect(!shown.item.frame.intersects(band.frame), "the band never covers the lyrics")
    }
}

@Test func theWorshipBandFlashesWhiteAsItArrives() throws {
    let alertID = "msg"
    func bandFill(at date: Date) -> ItemContent? {
        let scene = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(), at: date)
        return items(scene, .alerts).first { $0.id == "stage-band-\(alertID)" }?.content
    }
    #expect(bandFill(at: sent.addingTimeInterval(0.05)) == .shape(ShapeStyle(kind: .rectangle, fill: .solid(.white))))
    let red = ItemContent.shape(ShapeStyle(kind: .rectangle, fill: .solid(ConfidenceSceneBuilder.stageRed)))
    #expect(bandFill(at: sent.addingTimeInterval(StageMessageTiming.bandFlashPeriod * 0.75)) == red)
    #expect(bandFill(at: sent.addingTimeInterval(10)) == red, "steady after the opening blinks")
}

@Test func afterItsTimeTheClockAndKeyComeBack() {
    let at = ends.addingTimeInterval(0.1)
    let after = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(), at: at)
    let without = ConfidenceSceneBuilder.scene(layout: worshipLayout, info: info(message: nil), at: at)
    #expect(after == without)
}

// MARK: Designer's box, mirror and video

@Test func aLayoutsOwnStageMessageBoxStillClearsOnTime() {
    var layout = worshipLayout
    layout.objects.append(ConfidenceLayoutTemplate.linked(
        "Message", .stageMessage, x: 60, y: 300, width: 1800, height: 200, size: 80))
    let during = ConfidenceSceneBuilder.scene(layout: layout, info: info(), at: sent.addingTimeInterval(5))
    #expect(item(during, .slide, showing: "Wrap up in 5") != nil)
    #expect(items(during, .alerts).isEmpty, "the designer's box, not ours")
    #expect(item(during, .slide, showing: "Key: G") != nil, "nothing else moves")

    let after = ConfidenceSceneBuilder.scene(layout: layout, info: info(), at: ends)
    #expect(item(after, .slide, showing: "Wrap up in 5") == nil)
}

@Test func overTheAudienceScreenTheBarIsLargerAndClearsOnTime() throws {
    let audience = { RenderScene(canvasSize: CGSize(width: 1920, height: 1080)) }
    let during = StageScenes.scene(
        override: nil, source: .mirror, info: info(), at: sent.addingTimeInterval(5), audience: audience)
    let bar = try #require(items(during, .alerts).first { $0.id.hasPrefix("alert-band-") })
    #expect(bar.frame.height > 150, "larger than the audience screen's bar")
    #expect(bar.frame.minY == 0)
    let text = try #require(item(during, .alerts, showing: "Wrap up in 5"))
    #expect(text.text.fontSize > 72)

    let after = StageScenes.scene(
        override: nil, source: .mirror, info: info(), at: ends, audience: audience)
    #expect(items(after, .alerts).isEmpty)
}

@Test func theAudienceScreensOwnBarKeepsItsSize() throws {
    let alert = CueAlert(message: "Child 42", behavior: .persist, target: .audience)
    let bar = try #require(AlertSceneBuilder.bannerItems(
        for: alert, canvasSize: CGSize(width: 1920, height: 1080)).first)
    #expect(bar.frame.height == 150)
}
