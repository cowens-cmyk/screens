import Metal
import XCTest
@testable import RenderEngine

final class FrameGateTests: XCTestCase {

    private final class Source: MediaTextureSource, @unchecked Sendable {
        var motions: [String: MediaMotion] = [:]
        var generation: UInt64 = 0
        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { nil }
        func motion(for mediaID: String) -> MediaMotion { motions[mediaID] ?? .still }
        var contentGeneration: UInt64 { generation }
    }

    private func textScene(_ string: String) -> RenderScene {
        var scene = RenderScene()
        scene.addItem(
            RenderItem(
                id: "lyric", frame: CGRect(x: 100, y: 100, width: 1720, height: 400),
                content: .text(StyledText(string: string, fontSize: 80))),
            to: .slide)
        return scene
    }

    private func mediaScene(_ id: String) -> RenderScene {
        var scene = RenderScene()
        scene.addItem(
            RenderItem(
                id: "bg", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .media(id: id, scaleMode: .fill, sourceRect: nil)),
            to: .loopingVideos)
        return scene
    }

    private struct Run {
        var rendered = 0
        var reasons: [FrameGate<RenderScene>.Reason] = []
    }

    /// Drives the gate the way a display link does: one call per refresh.
    private func drive(
        ticks: Int, rate: Double = 60, start: Double = 1000,
        gate: inout FrameGate<RenderScene>, media: Source? = nil,
        scene: (Int, Double) -> RenderScene
    ) -> Run {
        var run = Run()
        for tick in 0..<ticks {
            let now = start + Double(tick) / rate
            let current = scene(tick, now)
            let motion = SceneMotion.of(current, at: now, media: media)
            if case .render(let reason) = gate.decide(key: current, motion: motion, now: now) {
                run.rendered += 1
                run.reasons.append(reason)
            }
        }
        return run
    }

    func testAStillSlideDrawsOnceThenHolds() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10)
        let slide = textScene("Amazing grace")
        let run = drive(ticks: 120, gate: &gate) { _, _ in slide }
        XCTAssertEqual(run.rendered, 1)
        XCTAssertEqual(run.reasons, [.first])
    }

    func testAChangeDrawsOnTheSameRefresh() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10)
        let first = textScene("Verse 1")
        let second = textScene("Verse 2")
        var drawnAt: [Int] = []
        for tick in 0..<60 {
            let scene = tick < 30 ? first : second
            if gate.decide(key: scene, motion: .still, now: Double(tick) / 60).renders {
                drawnAt.append(tick)
            }
        }
        XCTAssertEqual(drawnAt, [0, 30], "the cue shows on the refresh it was taken, no later")
    }

    func testAPlayingVideoDrawsEveryRefresh() {
        var gate = FrameGate<RenderScene>()
        let source = Source()
        source.motions["clip"] = .moving
        let scene = mediaScene("clip")
        let run = drive(ticks: 120, gate: &gate, media: source) { _, _ in scene }
        XCTAssertEqual(run.rendered, 120)
    }

    func testAStillImageDrawsOnceAndAgainWhenItLoads() {
        let source = Source()
        let scene = mediaScene("photo")
        XCTAssertFalse(SceneMotion.of(scene, at: 0, media: source).isMoving)

        var gate = FrameGate<SceneKey>(refreshInterval: 10)
        var rendered = 0
        for tick in 0..<120 {
            if tick == 50 { source.generation += 1 }
            let now = Double(tick) / 60
            let key = SceneKey(scene: scene, generation: source.generation)
            let motion = SceneMotion.of(scene, at: now, media: source)
            if gate.decide(key: key, motion: motion, now: now).renders { rendered += 1 }
        }
        XCTAssertEqual(rendered, 2, "a still that arrives after the scene draws when it lands")
    }

    private struct SceneKey: Equatable {
        var scene: RenderScene
        var generation: UInt64
    }

    func testABuildRunsEveryFrameAndDrawsTheFrameItLands() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10)
        var scene = textScene("Welcome")
        let start = 1000.0
        scene.layers[scene.layers.firstIndex { $0.kind == .slide }!].items[0].animationSteps = [
            SceneAnimationStep(id: "in", kind: .enter, animation: .fade, group: .auto, duration: 0.5)
        ]
        scene.layers[scene.layers.firstIndex { $0.kind == .slide }!].items[0].animationContext =
            AnimationContext(anchorHostTime: start)
        let run = drive(ticks: 120, start: start, gate: &gate) { _, _ in scene }
        // 0.5 s at 60 Hz runs for 30 refreshes, plus the one where it lands.
        XCTAssertEqual(run.rendered, 31)
        XCTAssertEqual(run.reasons.last, .settling)
    }

    func testABuildWaitingOnItsOffsetWakesWhenItStarts() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10)
        var scene = textScene("Later")
        let start = 1000.0
        let index = scene.layers.firstIndex { $0.kind == .slide }!
        // A cut in a second after the slide: no motion before, none after.
        scene.layers[index].items[0].animationSteps = [
            SceneAnimationStep(
                id: "in", kind: .enter, animation: .fade, group: .auto, startOffset: 1, duration: 0)
        ]
        scene.layers[index].items[0].animationContext = AnimationContext(anchorHostTime: start)
        let run = drive(ticks: 120, start: start, gate: &gate) { _, _ in scene }
        XCTAssertEqual(run.reasons, [.first, .wake])
    }

    func testAClickBuildDoesNotWakeOnItsOwn() {
        var scene = textScene("Point two")
        let index = scene.layers.firstIndex { $0.kind == .slide }!
        scene.layers[index].items[0].animationSteps = [
            SceneAnimationStep(id: "in", kind: .enter, animation: .fade, group: .click(0), duration: 0.4)
        ]
        scene.layers[index].items[0].animationContext = AnimationContext(anchorHostTime: 0)
        XCTAssertEqual(SceneMotion.of(scene, at: 5, media: nil), .still)
    }

    func testTickersScrollsAndTimeEffectsMove() {
        var ticker = textScene("News")
        let index = ticker.layers.firstIndex { $0.kind == .slide }!
        if case .text(var text) = ticker.layers[index].items[0].content {
            text.tickerSpeed = 120
            ticker.layers[index].items[0].content = .text(text)
        }
        XCTAssertTrue(SceneMotion.of(ticker, at: 0, media: nil).isMoving)

        var warped = textScene("Warp")
        warped.layers[index].items[0].effects = [SceneEffect(kind: .warp(amount: 4, scale: 40, speed: 1))]
        XCTAssertTrue(SceneMotion.of(warped, at: 0, media: nil).isMoving)

        var blurred = textScene("Blur")
        blurred.layers[index].items[0].effects = [SceneEffect(kind: .blur(radius: 4))]
        XCTAssertFalse(SceneMotion.of(blurred, at: 0, media: nil).isMoving)

        var hidden = mediaScene("clip")
        hidden.setLayerHidden(true, kind: .loopingVideos)
        XCTAssertFalse(SceneMotion.of(hidden, at: 0, media: nil).isMoving, "a hidden layer never draws")
        XCTAssertTrue(
            SceneMotion.of(mediaScene("clip"), at: 0, media: nil).isMoving,
            "media with no source to ask keeps drawing")
    }

    func testADelayedOutputDrawsUntilTheChangeLeavesItsQueue() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10, trailingFrames: 3)
        let first = textScene("A")
        let second = textScene("B")
        var drawn = 0
        for tick in 0..<60 {
            let scene = tick < 30 ? first : second
            if gate.decide(key: scene, motion: .still, now: Double(tick) / 60).renders { drawn += 1 }
        }
        XCTAssertEqual(drawn, 8, "each change draws itself and three frames behind it")
    }

    func testAStillFrameIsRedrawnOnTheSafetyInterval() {
        var gate = FrameGate<RenderScene>(refreshInterval: 1)
        let slide = textScene("Hold")
        let run = drive(ticks: 181, gate: &gate) { _, _ in slide }
        XCTAssertEqual(run.reasons, [.first, .refresh, .refresh, .refresh])
    }

    func testInvalidateDrawsTheNextRefresh() {
        var gate = FrameGate<RenderScene>(refreshInterval: 10)
        let slide = textScene("Same")
        XCTAssertTrue(gate.decide(key: slide, motion: .still, now: 0).renders)
        XCTAssertFalse(gate.decide(key: slide, motion: .still, now: 0.016).renders)
        gate.invalidate()
        XCTAssertEqual(gate.decide(key: slide, motion: .still, now: 0.033), .render(.invalidated))
        XCTAssertFalse(gate.decide(key: slide, motion: .still, now: 0.05).renders)
    }

    func testTallyCountsTheLastMinute() {
        var tally = FrameTally()
        for tick in 0..<(90 * 60) {
            tally.record(rendered: tick % 60 == 0, at: 500 + Double(tick) / 60)
        }
        let totals = tally.totals(at: 500 + 89.99)
        XCTAssertEqual(totals.rendered, 60)
        XCTAssertEqual(totals.skipped, 60 * 59)
    }

    func testActivityListsLiveHandlesOnly() {
        let activity = FrameActivity()
        var handle: FrameActivity.Handle? = activity.register(kind: "output", label: "Audience")
        let kept = activity.register(kind: "preview", label: "Stage")
        handle?.record(rendered: true, at: 10)
        kept.record(rendered: false, at: 10)
        XCTAssertEqual(activity.snapshot(at: 10.5).count, 2)
        handle = nil
        let left = activity.snapshot(at: 10.5)
        XCTAssertEqual(left.map(\.label), ["Stage"])
        XCTAssertEqual(left.first?.skipped, 1)
    }

    /// The real compositor behind the gate: a still slide over two seconds of
    /// refreshes draws once, a playing video draws on every refresh.
    @MainActor
    func testCompositorDrawsAStillSceneOnceAndAVideoEveryTick() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let compositor = try Compositor(device: device)
        let source = Source()
        source.motions["clip"] = .moving
        compositor.mediaSource = source
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: 640, height: 360, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        func count(_ scene: RenderScene, ticks: Int) -> (renders: Int, seconds: Double) {
            var gate = FrameGate<RenderScene>(refreshInterval: 10)
            var renders = 0
            let started = CACurrentMediaTime()
            for tick in 0..<ticks {
                let now = 2000 + Double(tick) / 60
                let motion = SceneMotion.of(scene, at: now, media: compositor.mediaSource)
                guard gate.decide(key: scene, motion: motion, now: now).renders else { continue }
                compositor.render(scene: scene, into: target, at: now)
                renders += 1
            }
            return (renders, CACurrentMediaTime() - started)
        }
        let ticks = 120
        let still = count(textScene("Holy, holy, holy"), ticks: ticks)
        let video = count(mediaScene("clip"), ticks: ticks)
        XCTAssertEqual(still.renders, 1)
        XCTAssertEqual(video.renders, ticks)
        print(String(
            format: "FrameGate benchmark: still %d/%d renders in %.1f ms, video %d/%d in %.1f ms",
            still.renders, ticks, still.seconds * 1000, video.renders, ticks, video.seconds * 1000))
    }
}
