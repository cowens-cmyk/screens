import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let now = Date(timeIntervalSince1970: 1_000_000)

private func items(in scene: RenderScene, layer: LayerKind) -> [RenderItem] {
    scene.layers.first { $0.kind == layer }?.items ?? []
}

private func text(_ scene: RenderScene, id: String) -> StyledText? {
    for layer in scene.layers {
        for item in layer.items where item.id == id {
            if case .text(let text) = item.content { return text }
        }
    }
    return nil
}

/// The drawn text of a layout object, and where it is.
private func drawn(
    _ name: String, of layout: ConfidenceLayout, in scene: RenderScene
) -> (text: StyledText, frame: CGRect, layer: LayerKind)? {
    guard let object = layout.objects.first(where: { $0.name == name }) else { return nil }
    let prefix = "confidence-\(layout.id)-\(object.id)"
    for layer in scene.layers {
        for item in layer.items where item.id.hasPrefix(prefix) {
            if case .text(let text) = item.content { return (text, item.frame, layer.kind) }
        }
    }
    return nil
}

private func audienceWithVideo() -> RenderScene {
    var scene = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    scene.addItem(RenderItem(
        id: "video-1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        content: .media(id: "clip", scaleMode: .fill, sourceRect: nil)
    ), to: .videos)
    scene.addItem(RenderItem(
        id: "lyric", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        content: .solid(.white)
    ), to: .slide)
    return scene
}

private func video(remaining: Double, playing: Bool = true) -> VideoCountdown {
    VideoCountdown(
        name: "Announcements", duration: 120, position: 120 - remaining,
        anchoredAt: now, isPlaying: playing)
}

/// The sermon timer, running, with `left` seconds to go at `now`.
private func sermonTimer(left: Double, running: Bool = true) -> TimerSnapshot {
    TimerSnapshot(
        id: SermonTimer.id, name: SermonTimer.name, mode: .countdown, isRunning: running,
        runningSince: running ? now : nil, banked: 2400 - left, durationSeconds: 2400)
}

private let worship = ConfidenceLayoutTemplate.worship.make(name: "Worship")
private let sermon = ConfidenceLayoutTemplate.sermon.make(name: "Message")
private let videoLayout = ConfidenceLayoutTemplate.video.make(name: "Video")
private let worshipPlan = StageVideoPlan(layout: videoLayout, isMessage: false)
private let messagePlan = StageVideoPlan(layout: videoLayout, isMessage: true)

private func videoBox(_ layout: ConfidenceLayout = videoLayout) -> CGRect {
    let box = layout.objects.first { $0.name == ConfidenceLayoutTemplate.videoBoxName }!
    return CGRect(x: box.x!, y: box.y!, width: box.width!, height: box.height!)
}

@Test func layoutModeRendersItsLayout() {
    let info = ConfidenceInfo(current: .init(body: "Amazing grace"))
    let scene = StageScenes.scene(
        override: nil, source: .layout(worship), info: info, at: now, audience: { .empty })
    #expect(scene == ConfidenceSceneBuilder.scene(layout: worship, info: info, at: now))
}

@Test func mirrorModeShowsTheAudienceScene() {
    let audience = audienceWithVideo()
    let scene = StageScenes.scene(
        override: nil, source: .mirror, info: ConfidenceInfo(), at: now, audience: { audience })
    #expect(scene == audience)
}

@Test func aPickedLayoutOverridesTheMode() {
    let info = ConfidenceInfo()
    let mirrored = StageScenes.scene(
        override: sermon, source: .mirror, info: info, at: now, audience: { audienceWithVideo() })
    #expect(mirrored == ConfidenceSceneBuilder.scene(layout: sermon, info: info, at: now))
}

@Test func aPlayingVideoBringsUpTheVideoLayoutInEveryMode() throws {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 75))
    for (override, source) in [(nil, StageSource.layout(worship)), (nil, .mirror), (sermon, .layout(worship))] {
        let scene = StageScenes.scene(
            override: override, source: source, video: worshipPlan, info: info, at: now,
            audience: { audienceWithVideo() })
        let remaining = try #require(drawn("Video Remaining", of: videoLayout, in: scene))
        #expect(remaining.text.string == "1:15")
        #expect(items(in: scene, layer: .videos).map(\.content.mediaID) == ["clip"])
        #expect(!items(in: scene, layer: .slide).contains { $0.id == "lyric" || $0.id == "stage-lyric" },
                "the audience's slide layer is not carried over")
    }
}

@Test func turnedOffTheStageKeepsItsLayoutThroughAVideo() {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 75))
    let scene = StageScenes.scene(
        override: nil, source: .layout(worship), video: nil, info: info, at: now,
        audience: { audienceWithVideo() })
    #expect(scene == ConfidenceSceneBuilder.scene(layout: worship, info: info, at: now))
}

@Test func theVideoFillsItsBoxAtItsOwnShape() {
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 30),
        info: ConfidenceInfo(videoCountdown: video(remaining: 30)), at: now)
    let frame = items(in: scene, layer: .videos)[0].frame
    let box = videoBox()
    #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(frame))
    #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.001)
    #expect(abs(frame.width - box.width) < 0.001, "a 16:9 box is filled edge to edge")
    #expect(frame.width > 1000, "large on the back screen")
}

@Test func whatIsDrawnBeforeTheBoxSitsUnderThePicture() throws {
    var layout = videoLayout
    var backdrop = ConfidenceLayoutTemplate.linked(
        "Backdrop Label", .currentGroup, x: 0, y: 0, width: 1920, height: 1080, size: 40)
    backdrop.text = ""
    layout.objects.insert(backdrop, at: 0)
    let info = ConfidenceInfo(videoCountdown: video(remaining: 30), currentGroupName: "Chorus")
    let scene = StageScenes.videoScene(
        plan: StageVideoPlan(layout: layout, isMessage: false), audience: audienceWithVideo(),
        video: video(remaining: 30), info: info, at: now)
    #expect(try #require(drawn("Backdrop Label", of: layout, in: scene)).layer == .stillGraphics)
    #expect(try #require(drawn("Clock", of: layout, in: scene)).layer == .slide)
}

@Test func theTimeLeftIsLargeAndGreenAboveTheVideo() throws {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 30))
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 30), info: info, at: now)
    let remaining = try #require(drawn("Video Remaining", of: videoLayout, in: scene))
    let picture = items(in: scene, layer: .videos)[0].frame
    #expect(remaining.frame.maxY <= picture.minY, "the time left is above the video")
    #expect(remaining.text.tabularFigures == true)

    // The Message layout's sermon timer, for its green and its font.
    let messageScene = ConfidenceSceneBuilder.scene(
        layout: sermon, info: ConfidenceInfo(timers: [sermonTimer(left: 1500)]), at: now)
    let messageTimer = try #require(drawn("Sermon Timer", of: sermon, in: messageScene))
    #expect(remaining.text.color == messageTimer.text.color, "the same green as the sermon timer")
    #expect(remaining.text.fontName == messageTimer.text.fontName)
    #expect(remaining.text.fontSize >= 200)
}

@Test func theTimeLeftStaysGreenToTheEnd() throws {
    let green = try #require(drawn(
        "Video Remaining", of: videoLayout,
        in: StageScenes.videoScene(
            plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 90),
            info: ConfidenceInfo(videoCountdown: video(remaining: 90)), at: now))).text.color
    for left in [30.0, 10, 4.2, 0.4] {
        let scene = StageScenes.videoScene(
            plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: left),
            info: ConfidenceInfo(videoCountdown: video(remaining: left)), at: now)
        let remaining = try #require(drawn("Video Remaining", of: videoLayout, in: scene))
        #expect(remaining.text.color == green, "no amber or red at \(left)s: red means the message is over")
    }
}

@Test func theTimeLeftRoundsUpAndIsTheCacheKey() throws {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 74.3))
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 74.3), info: info, at: now)
    #expect(try #require(drawn("Video Remaining", of: videoLayout, in: scene)).text.string == "1:15")
    #expect(StageScenes.displayedVideoSecond(in: info, at: now) == 75)
    #expect(StageScenes.displayedVideoSecond(in: info, at: now.addingTimeInterval(0.2)) == 75)
    #expect(StageScenes.displayedVideoSecond(in: info, at: now.addingTimeInterval(0.4)) == 74)
    #expect(StageScenes.displayedVideoSecond(in: info, at: now.addingTimeInterval(75)) == nil, "ended")
    // Within one displayed second (and one clock second) the scene is the same.
    let a = StageScenes.scene(
        override: nil, source: .layout(sermon), video: worshipPlan, info: info,
        at: now.addingTimeInterval(0.25), audience: { audienceWithVideo() })
    let b = StageScenes.scene(
        override: nil, source: .layout(sermon), video: worshipPlan, info: info,
        at: now.addingTimeInterval(0.05), audience: { audienceWithVideo() })
    if Calendar.current.component(.minute, from: now.addingTimeInterval(0.25))
        == Calendar.current.component(.minute, from: now.addingTimeInterval(0.05)) {
        #expect(a == b)
    }
}

@Test func aCountdownVideoShowsTheTimeUntilTheServiceStarts() throws {
    // A countdown video made to end as the service starts.
    let serviceStart = now.addingTimeInterval(4 * 60 + 12)
    let countdown = VideoCountdown(
        name: "Countdown", duration: 300, position: 300 - serviceStart.timeIntervalSince(now),
        anchoredAt: now, isPlaying: true)
    let info = ConfidenceInfo(videoCountdown: countdown)
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: countdown, info: info, at: now)
    #expect(try #require(drawn("Video Remaining", of: videoLayout, in: scene)).text.string == "4:12")
}

@Test func inWorshipTheVideoStageShowsTheClockButNotTheSermonTimer() throws {
    let info = ConfidenceInfo(timers: [sermonTimer(left: 2400, running: false)], videoCountdown: video(remaining: 60))
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 60), info: info, at: now)
    #expect(drawn("Sermon Timer", of: videoLayout, in: scene) == nil)
    let clock = try #require(drawn("Clock", of: videoLayout, in: scene))
    let picture = items(in: scene, layer: .videos)[0].frame
    #expect(clock.frame.minY >= picture.maxY, "small at the bottom")
    #expect(clock.text.fontSize < 150)
}

@Test func duringTheMessageTheSermonTimerAndClockMoveToTheBottomUnchanged() throws {
    let timers = [sermonTimer(left: 1234.4)]
    let at = now.addingTimeInterval(7.2)
    let before = ConfidenceSceneBuilder.scene(layout: sermon, info: ConfidenceInfo(timers: timers), at: at)
    let messageTimer = try #require(drawn("Sermon Timer", of: sermon, in: before))
    let messageClock = try #require(drawn("Clock", of: sermon, in: before))

    let playing = VideoCountdown(name: "Bumper", duration: 60, position: 0, anchoredAt: now, isPlaying: true)
    let info = ConfidenceInfo(timers: timers, videoCountdown: playing)
    let scene = StageScenes.scene(
        override: nil, source: .layout(sermon), video: messagePlan, info: info, at: at,
        audience: { audienceWithVideo() })
    let timer = try #require(drawn("Sermon Timer", of: videoLayout, in: scene))
    let clock = try #require(drawn("Clock", of: videoLayout, in: scene))
    #expect(timer.text.string == messageTimer.text.string, "the same time: it carries on, no reset")
    #expect(timer.text.string == "20:27")
    #expect(clock.text.string == messageClock.text.string)
    #expect(timer.text.color == messageTimer.text.color, "the same green")
    #expect(timer.text.fontName == messageTimer.text.fontName)
    #expect(clock.text.color == messageClock.text.color, "the same white")
    #expect(clock.text.fontName == messageClock.text.fontName)
    #expect(timer.text.fontSize < messageTimer.text.fontSize, "smaller than on the Message layout")

    let picture = items(in: scene, layer: .videos)[0].frame
    #expect(timer.frame.minY >= picture.maxY && clock.frame.minY >= picture.maxY, "along the bottom")
    #expect(timer.frame.maxX <= clock.frame.minX, "side by side")

    // A second later both have moved on by the same second.
    let later = StageScenes.scene(
        override: nil, source: .layout(sermon), video: messagePlan, info: info, at: at.addingTimeInterval(1),
        audience: { audienceWithVideo() })
    #expect(try #require(drawn("Sermon Timer", of: videoLayout, in: later)).text.string == "20:26")
}

@Test func overTimeTheSermonTimerStaysRedUnderTheVideo() throws {
    let info = ConfidenceInfo(timers: [sermonTimer(left: -65)], videoCountdown: video(remaining: 40))
    let scene = StageScenes.videoScene(
        plan: messagePlan, audience: audienceWithVideo(), video: video(remaining: 40), info: info, at: now)
    let timer = try #require(drawn("Sermon Timer", of: videoLayout, in: scene))
    #expect(timer.text.string == "-1:05")
    #expect(timer.text.color == ColorHex.color(TimerWarning.overtimeHex))
}

@Test func aRunningSermonTimerCountsAsTheMessageInAnyMode() throws {
    let info = ConfidenceInfo(timers: [sermonTimer(left: 900)], videoCountdown: video(remaining: 40))
    let scene = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 40), info: info, at: now)
    #expect(try #require(drawn("Sermon Timer", of: videoLayout, in: scene)).text.string == "15:00")
    #expect(StageScenes.isDuringMessage(plan: worshipPlan, info: info))
    #expect(StageScenes.isDuringMessage(plan: messagePlan, info: ConfidenceInfo()))
    #expect(!StageScenes.isDuringMessage(plan: worshipPlan, info: ConfidenceInfo()))
}

@Test func whenTheVideoEndsTheMessageLayoutComesBack() {
    let timers = [sermonTimer(left: 1500)]
    let playing = VideoCountdown(name: "Bumper", duration: 30, position: 0, anchoredAt: now, isPlaying: true)
    let info = ConfidenceInfo(timers: timers, videoCountdown: playing)
    let ended = now.addingTimeInterval(30)
    let scene = StageScenes.scene(
        override: nil, source: .layout(sermon), video: messagePlan, info: info, at: ended,
        audience: { audienceWithVideo() })
    #expect(scene == ConfidenceSceneBuilder.scene(layout: sermon, info: info, at: ended))
    let cleared = ConfidenceInfo(timers: timers)
    #expect(StageScenes.scene(
        override: nil, source: .layout(sermon), video: messagePlan, info: cleared, at: now,
        audience: { audienceWithVideo() }) == ConfidenceSceneBuilder.scene(layout: sermon, info: cleared, at: now))
}

@Test func theStageReturnsWhenTheVideoEndsOrIsCleared() {
    let ended = ConfidenceInfo(videoCountdown: video(remaining: 0))
    #expect(StageScenes.activeVideo(in: ended, at: now) == nil)
    let playing = ConfidenceInfo(videoCountdown: video(remaining: 3))
    #expect(StageScenes.activeVideo(in: playing, at: now) != nil)
    #expect(StageScenes.activeVideo(in: playing, at: now.addingTimeInterval(3.1)) == nil,
            "runs out on its own between transport updates")
    #expect(StageScenes.activeVideo(in: ConfidenceInfo(), at: now) == nil)
    let scene = StageScenes.scene(
        override: nil, source: .layout(worship), video: worshipPlan, info: ended, at: now,
        audience: { audienceWithVideo() })
    #expect(scene == ConfidenceSceneBuilder.scene(layout: worship, info: ended, at: now))
}

@Test func aPausedVideoKeepsTheStageAndSaysSo() throws {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 40, playing: false))
    let scene = StageScenes.scene(
        override: nil, source: .mirror, video: worshipPlan, info: info, at: now.addingTimeInterval(100),
        audience: { audienceWithVideo() })
    #expect(try #require(drawn("Video Remaining", of: videoLayout, in: scene)).text.string == "0:40")
    #expect(text(scene, id: "stage-video-paused")?.string == "Paused")
    let playing = StageScenes.videoScene(
        plan: worshipPlan, audience: audienceWithVideo(), video: video(remaining: 40),
        info: ConfidenceInfo(videoCountdown: video(remaining: 40)), at: now)
    #expect(text(playing, id: "stage-video-paused") == nil)
}

@Test func aVideoPlayingOnceOnTheBackgroundLayerShowsItsOwnPicture() {
    var audience = RenderScene(canvasSize: CGSize(width: 1920, height: 1080))
    audience.addItem(RenderItem(
        id: "loop", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        content: .media(id: "announcements", scaleMode: .fill, sourceRect: nil)
    ), to: .loopingVideos)
    var countdown = video(remaining: 40)
    countdown.layer = .loopingVideos
    let scene = StageScenes.scene(
        override: nil, source: .layout(worship), video: worshipPlan,
        info: ConfidenceInfo(videoCountdown: countdown), at: now, audience: { audience })
    #expect(items(in: scene, layer: .videos).map(\.content.mediaID) == ["announcements"])
}

@Test func aVideoLayoutWithoutItsBoxStillShowsTheVideo() {
    var layout = videoLayout
    layout.objects.removeAll { $0.name == ConfidenceLayoutTemplate.videoBoxName }
    let scene = StageScenes.videoScene(
        plan: StageVideoPlan(layout: layout, isMessage: false), audience: audienceWithVideo(),
        video: video(remaining: 30), info: ConfidenceInfo(videoCountdown: video(remaining: 30)), at: now)
    let frame = items(in: scene, layer: .videos)[0].frame
    #expect(StageScenes.defaultVideoArea(in: CGSize(width: 1920, height: 1080))
        .insetBy(dx: -0.5, dy: -0.5).contains(frame))
}

@Test func theCountdownTextRoundsUp() {
    #expect(StageScenes.countdownText(remaining: 9.2) == "0:10")
    #expect(StageScenes.countdownText(remaining: 0.2) == "0:01")
    #expect(StageScenes.countdownText(remaining: 0) == "0:00")
    #expect(StageScenes.countdownText(remaining: 605) == "10:05")
}

@Test func stageMessagesShowOverAMirror() {
    var info = ConfidenceInfo()
    info.alert = CueAlert(message: "Wrap up", behavior: .persist, target: .confidence)
    let scene = StageScenes.scene(
        override: nil, source: .mirror, info: info, at: now, audience: { audienceWithVideo() })
    #expect(!items(in: scene, layer: .alerts).isEmpty)
}

@Test func stageMessagesShowAcrossTheTopOfTheVideoStage() throws {
    var info = ConfidenceInfo(timers: [sermonTimer(left: 600)], videoCountdown: video(remaining: 50))
    info.alert = CueAlert(message: "Wrap up", behavior: .persist, target: .confidence, firedAt: now)
    let at = now.addingTimeInterval(2)
    let scene = StageScenes.videoScene(
        plan: messagePlan, audience: audienceWithVideo(), video: video(remaining: 50), info: info, at: at)
    let band = try #require(items(in: scene, layer: .alerts).first)
    #expect(band.frame.minY == 0, "the bar across the top")
    #expect(items(in: scene, layer: .videos).count == 1, "the video keeps playing under it")
    #expect(drawn("Sermon Timer", of: videoLayout, in: scene) != nil, "not the Message takeover")

    // A Video layout with its own Stage Message box shows it there instead.
    var layout = videoLayout
    layout.objects.append(ConfidenceLayoutTemplate.linked(
        "Stage Message", .stageMessage, x: 60, y: 300, width: 300, height: 200, size: 40))
    let own = StageScenes.videoScene(
        plan: StageVideoPlan(layout: layout, isMessage: true), audience: audienceWithVideo(),
        video: video(remaining: 50), info: info, at: at)
    #expect(items(in: own, layer: .alerts).isEmpty)
    #expect(try #require(drawn("Stage Message", of: layout, in: own)).text.string == "Wrap up")
}
