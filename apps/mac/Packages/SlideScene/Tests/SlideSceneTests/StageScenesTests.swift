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

private let worship = ConfidenceLayoutTemplate.worship.make(name: "Worship")
private let sermon = ConfidenceLayoutTemplate.sermon.make(name: "Message")

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

@Test func aPlayingVideoTakesOverEveryMode() {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 75))
    for (override, source) in [(nil, StageSource.layout(worship)), (nil, .mirror), (sermon, .layout(worship))] {
        let scene = StageScenes.scene(
            override: override, source: source, info: info, at: now, audience: { audienceWithVideo() })
        #expect(text(scene, id: "stage-video-countdown")?.string == "1:15")
        #expect(text(scene, id: "stage-video-name")?.string == "Announcements")
        #expect(items(in: scene, layer: .videos).map(\.content.mediaID) == ["clip"])
        #expect(items(in: scene, layer: .slide).allSatisfy { $0.id.hasPrefix("stage-video") },
                "the audience's slide layer is not carried over")
    }
}

@Test func theVideoIsScaledIntoThePreviewArea() {
    let scene = StageScenes.videoScene(
        audience: audienceWithVideo(), video: video(remaining: 30),
        canvasSize: CGSize(width: 1920, height: 1080), at: now)
    let frame = items(in: scene, layer: .videos)[0].frame
    let area = CGRect(x: 1920 * 0.03, y: 1080 * 0.03, width: 1920 * 0.94, height: 1080 * 0.64)
    #expect(area.insetBy(dx: -0.5, dy: -0.5).contains(frame))
    #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.001)
    #expect(abs(frame.height - area.height) < 0.001, "fills the area's height")
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
        override: nil, source: .layout(worship), info: ended, at: now, audience: { audienceWithVideo() })
    #expect(scene == ConfidenceSceneBuilder.scene(layout: worship, info: ended, at: now))
}

@Test func aPausedVideoKeepsTheStage() {
    let info = ConfidenceInfo(videoCountdown: video(remaining: 40, playing: false))
    let scene = StageScenes.scene(
        override: nil, source: .mirror, info: info, at: now.addingTimeInterval(100),
        audience: { audienceWithVideo() })
    #expect(text(scene, id: "stage-video-countdown")?.string == "0:40")
    #expect(text(scene, id: "stage-video-name")?.string == "Announcements · Paused")
}

@Test func theCountdownWarnsInTheLastTenSeconds() {
    #expect(StageScenes.countdownColor(remaining: 30) == .white)
    #expect(StageScenes.countdownColor(remaining: 10) == StageScenes.orange)
    #expect(StageScenes.countdownColor(remaining: 4.9) == StageScenes.red)
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
