import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let start = Date(timeIntervalSince1970: 1_800_000_000.4)
private let sermon = ConfidenceLayoutTemplate.sermon.make(name: "Message")

/// A sermon timer started a third of a second off the wall-clock second, so
/// its digits and the clock's tick at different moments.
private func runningInfo() -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "Grace upon grace"),
        timers: [TimerSnapshot(
            id: SermonTimer.id, name: "Sermon", mode: .countdown, isRunning: true,
            runningSince: start.addingTimeInterval(-0.33), durationSeconds: 35 * 60)])
}

/// The stage window, its virtual screen and its DeckLink feed each asking
/// at 60 Hz for three seconds: 540 asks. Before the cache each one built
/// the layout; with it the scene is built when the clock or the timer
/// shows a new value, and every answer is the scene a fresh build gives.
@Test func threeConsumersShareOneBuildPerShownChange() {
    let cache = StageSceneCache()
    let info = runningInfo()
    var asks = 0
    for tick in 0..<(3 * 60) {
        let date = start.addingTimeInterval(Double(tick) / 60)
        for _ in 0..<3 {
            let scene = StageScenes.scene(
                override: nil, source: .layout(sermon), info: info, at: date,
                cache: cache, slot: "stage-1", audience: { .empty })
            asks += 1
            #expect(scene == ConfidenceSceneBuilder.scene(layout: sermon, info: info, at: date))
        }
    }
    #expect(asks == 540)
    // Per second: the clock's second, the timer's second (a third of a second
    // apart) and the wall-clock bucket that lands with the clock.
    #expect(cache.builds <= 7, "built \(cache.builds) times for \(asks) asks")
    print("StageSceneCache: \(cache.builds) builds for \(asks) asks over 3 s (was \(asks))")
}

@Test func aChangedInfoBuildsAtOnce() {
    let cache = StageSceneCache()
    var info = runningInfo()
    let first = cache.scene(slot: "s", layout: sermon, info: info, at: start)
    info.timers[0].durationSeconds = 20 * 60
    let second = cache.scene(slot: "s", layout: sermon, info: info, at: start)
    #expect(first != second)
    #expect(second == ConfidenceSceneBuilder.scene(layout: sermon, info: info, at: start))
    #expect(cache.builds == 2)
}

@Test func slotsAreKeptApart() {
    let cache = StageSceneCache()
    let worship = ConfidenceLayoutTemplate.worship.make(name: "Worship")
    let info = runningInfo()
    let a = cache.scene(slot: "a", layout: sermon, info: info, at: start)
    let b = cache.scene(slot: "b", layout: worship, info: info, at: start)
    #expect(a == ConfidenceSceneBuilder.scene(layout: sermon, info: info, at: start))
    #expect(b == ConfidenceSceneBuilder.scene(layout: worship, info: info, at: start))
    _ = cache.scene(slot: "a", layout: sermon, info: info, at: start)
    #expect(cache.builds == 2)
}

/// While a video holds the stage, the Video layout is built when its time
/// left, the clock or the timer turns over, and matches a fresh build.
@Test func theVideoLayoutIsSharedToo() {
    let cache = StageSceneCache()
    let plan = StageVideoPlan(layout: ConfidenceLayoutTemplate.video.make(name: "Video"), isMessage: true)
    var info = runningInfo()
    info.videoCountdown = VideoCountdown(
        name: "Announcements", duration: 120, position: 30, anchoredAt: start.addingTimeInterval(-0.6),
        isPlaying: true)
    var audience = RenderScene()
    audience.addItem(
        RenderItem(
            id: "clip", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            content: .media(id: "clip", scaleMode: .fill, sourceRect: nil)),
        to: .videos)
    for tick in 0..<(2 * 60) {
        let date = start.addingTimeInterval(Double(tick) / 60)
        for _ in 0..<3 {
            let scene = StageScenes.scene(
                override: nil, source: .layout(sermon), video: plan, info: info, at: date,
                cache: cache, slot: "stage-1", audience: { audience })
            let video = StageScenes.activeVideo(in: info, at: date)!
            #expect(scene == StageScenes.videoScene(
                plan: plan, audience: audience, video: video, info: info, at: date))
        }
    }
    #expect(cache.builds <= 8, "built \(cache.builds) times for 360 asks")
}
