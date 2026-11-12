import Foundation
import AVFoundation
import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

@MainActor
final class PlaybackIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        self.device = device
        try XCTSkipIf(isVirtualMachine(), "real-time playback only holds on a real Mac (VirtualMachine.swift)")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeOneSecondLoop() async throws -> URL {
        let url = tempDir.appendingPathComponent("loop.mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: CGSize(width: 320, height: 180), frameCount: 30
        ) { context, frame in

            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: CGFloat(frame) * 10, y: 0, width: 10, height: 180))
        }
        return url
    }

    func testLoopingPlaybackCrossesTheSeam() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeOneSecondLoop())
        engine.play(media, id: "loop", loop: true)

        let deadline = Date(timeIntervalSinceNow: 15)
        var sawSurface = false
        while Date() < deadline {
            if engine.surface(for: "loop", hostTime: CACurrentMediaTime()) != nil {
                sawSurface = true
            }
            if let stats = engine.stats(for: "loop"), stats.framesDisplayed >= 45 { break }
            try await Task.sleep(for: .milliseconds(16))
        }

        XCTAssertTrue(sawSurface, "playback never produced a frame")
        let stats = try XCTUnwrap(engine.stats(for: "loop"))
        XCTAssertGreaterThanOrEqual(
            stats.framesDisplayed, 45,
            "playback did not continue across the loop boundary (1s loop, \(stats.framesDisplayed) frames)"
        )
        engine.stopAll()
    }

    func testPrerolledItemFiresImmediately() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeOneSecondLoop())

        let ready = await engine.preroll(media, id: "next", loop: false)
        XCTAssertTrue(ready, "pre-roll must reach ready-to-play")
        XCTAssertFalse(try XCTUnwrap(engine.transport(id: "next")).isPlaying)
        defer { engine.stopAll() }

        engine.start(id: "next")
        XCTAssertTrue(try XCTUnwrap(engine.transport(id: "next")).isPlaying, "start must release the paused transport")
        let deadline = Date(timeIntervalSinceNow: 0.5)
        var framesDisplayed = 0
        while Date() < deadline {
            _ = engine.surface(for: "next", hostTime: CACurrentMediaTime())
            framesDisplayed = engine.stats(for: "next")?.framesDisplayed ?? 0
            if framesDisplayed > 0 { break }
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertGreaterThan(framesDisplayed, 0, "pre-rolled item did not deliver a first frame")
        engine.stopAll()
    }

    func testAPlayerStandingByIsTakenAndPlaysAtOnce() async throws {
        let engine = try MediaEngine(device: device)
        let url = try await makeOneSecondLoop()
        await engine.standBy(playing: url, loop: true)
        XCTAssertEqual(engine.standbyPlayerCount, 1)
        // Waiting, it isn't on any screen: nothing plays, nothing to show.
        XCTAssertTrue(engine.playingIDs.isEmpty)
        XCTAssertNil(engine.transport(id: "song"))
        await engine.standBy(playing: url, loop: true)
        XCTAssertEqual(engine.standbyPlayerCount, 1, "one per file and way of playing it")

        // Asked for another way (not looping), it isn't the one: a fresh
        // player is made and the one standing by stays.
        let media = try await engine.prepare(url: url)
        engine.play(media, id: "once", loop: false)
        XCTAssertEqual(engine.standbyPlayerCount, 1)

        engine.play(media, id: "song", loop: true)
        XCTAssertEqual(engine.standbyPlayerCount, 0, "taken")
        XCTAssertTrue(try XCTUnwrap(engine.transport(id: "song")).isPlaying)
        let deadline = Date(timeIntervalSinceNow: 0.5)
        var framesDisplayed = 0
        while Date() < deadline {
            _ = engine.surface(for: "song", hostTime: CACurrentMediaTime())
            framesDisplayed = engine.stats(for: "song")?.framesDisplayed ?? 0
            if framesDisplayed > 0 { break }
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertGreaterThan(framesDisplayed, 0, "the readied player did not deliver a first frame")

        // It keeps going like any other: across the loop, then stopped.
        let later = Date(timeIntervalSinceNow: 5)
        while Date() < later, (engine.stats(for: "song")?.framesDisplayed ?? 0) < 45 {
            _ = engine.surface(for: "song", hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThanOrEqual(engine.stats(for: "song")?.framesDisplayed ?? 0, 45)
        engine.stop(id: "song")
        XCTAssertNil(engine.transport(id: "song"))
        engine.stopAll()
    }

    func testPlayersStandingByAreLetGo() async throws {
        let engine = try MediaEngine(device: device)
        let url = try await makeOneSecondLoop()
        await engine.standBy(playing: url, loop: true)
        await engine.standBy(playing: url, loop: false)
        XCTAssertEqual(engine.standbyPlayerCount, 2)
        engine.releaseStandbyPlayers(keeping: [url])
        XCTAssertEqual(engine.standbyPlayerCount, 2)
        engine.releaseStandbyPlayers(keeping: [])
        XCTAssertEqual(engine.standbyPlayerCount, 0)
        // A file that isn't there readies nothing, and playing still works.
        await engine.standBy(playing: tempDir.appendingPathComponent("missing.mov"), loop: true)
        XCTAssertEqual(engine.standbyPlayerCount, 0)
    }

    func testSixtyFPSLoopIsSeamlessAcrossWraps() async throws {
        let url = tempDir.appendingPathComponent("loop60.mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .hevc, size: CGSize(width: 320, height: 180),
            frameCount: 120, framesPerSecond: 60
        ) { context, frame in
            context.setFillColor(CGColor(gray: CGFloat(frame % 2), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: url)
        engine.play(media, id: "sixty", loop: true)
        let vended = Locked<[Double]>([])
        try XCTUnwrap(engine.playerForTesting(id: "sixty")).onFrameVended.value = { t in
            vended.withLock { $0.append(t) }
        }

        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline, vended.value.count < 5 * 120 {
            _ = engine.surface(for: "sixty", hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(2))
        }
        let stats = try XCTUnwrap(engine.stats(for: "sixty"))
        engine.stopAll()

        var loops: [[Int]] = [[]]
        var previous = -Double.infinity
        for t in vended.value {
            if t < previous { loops.append([]) }
            previous = t
            loops[loops.count - 1].append(Int((t * 60).rounded()))
        }
        XCTAssertGreaterThanOrEqual(loops.count, 3, "did not observe enough loop wraps (\(loops.count))")
        for (i, loop) in loops.enumerated().dropFirst().dropLast() {
            XCTAssertEqual(loop, Array(0...119), "loop \(i) lost/duplicated frames (\(loop.count) vended)")
        }
        XCTAssertEqual(stats.framesDropped, 0, "stats charged drops on a seamless loop")
    }

    func testSurfacePullsAreIndependentOfMainThreadStalls() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeOneSecondLoop())
        engine.play(media, id: "hot", loop: true)

        let warmup = Date(timeIntervalSinceNow: 5)
        while (engine.stats(for: "hot")?.framesDisplayed ?? 0) == 0, Date() < warmup {
            _ = engine.surface(for: "hot", hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertGreaterThan(engine.stats(for: "hot")?.framesDisplayed ?? 0, 0, "no first frame")

        let puller = Task.detached(priority: .userInitiated) { () -> Double in
            var maxGap: Double = 0
            var last = CACurrentMediaTime()
            let end = last + 1.5
            while CACurrentMediaTime() < end {
                let now = CACurrentMediaTime()
                maxGap = max(maxGap, now - last)
                last = now
                _ = engine.surface(for: "hot", hostTime: now)
                usleep(16_000)
            }
            return maxGap
        }

        for _ in 0..<12 {
            usleep(60_000)
            await Task.yield()
        }

        let maxGap = await puller.value
        engine.stopAll()

        XCTAssertLessThan(maxGap, 0.05, "pulls serialized behind main-thread stalls (max gap \(maxGap)s)")
    }

    func testStopReleasesThePlayer() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeOneSecondLoop())
        engine.play(media, id: "x", loop: true)
        engine.stop(id: "x")
        XCTAssertNil(engine.surface(for: "x", hostTime: CACurrentMediaTime()))
        XCTAssertTrue(engine.playingIDs.isEmpty)
    }

    /// A portrait iPhone video: 320×180 frames stored with a 90° clockwise
    /// turn. The screens must get it upright, 180×320, the stored left side
    /// on top, looping or not.
    func testPortraitPhoneVideoPlaysUpright() async throws {
        let url = tempDir.appendingPathComponent("portrait.mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: CGSize(width: 320, height: 180), frameCount: 30,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        ) { context, _ in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
        }
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: url)
        XCTAssertEqual(media.naturalSize, CGSize(width: 180, height: 320))
        XCTAssertNotNil(media.videoComposition)
        defer { engine.stopAll() }

        for loop in [false, true] {
            let id = loop ? "looping" : "once"
            engine.play(media, id: id, loop: loop)
            let deadline = Date(timeIntervalSinceNow: 5)
            var luma: MTLTexture?
            while Date() < deadline, luma == nil {
                if case .ycbcrBiplanar(let texture, _, _, _)? = engine.surface(for: id, hostTime: CACurrentMediaTime()) {
                    luma = texture
                } else if case .bgra(let texture, _, _)? = engine.surface(for: id, hostTime: CACurrentMediaTime()) {
                    luma = texture
                }
                try await Task.sleep(for: .milliseconds(16))
            }
            let texture = try XCTUnwrap(luma, "no frame (loop: \(loop))")
            XCTAssertEqual(texture.width, 180, "loop: \(loop)")
            XCTAssertEqual(texture.height, 320, "loop: \(loop)")
            engine.stop(id: id)
        }
    }

    func testAnUprightVideoGetsNoComposition() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeOneSecondLoop())
        XCTAssertNil(media.videoComposition)
        XCTAssertEqual(media.naturalSize, CGSize(width: 320, height: 180))
        XCTAssertFalse(MediaEngine.turns(CGAffineTransform(translationX: 0, y: 10)))
        XCTAssertTrue(MediaEngine.turns(CGAffineTransform(rotationAngle: .pi)))
    }
}
