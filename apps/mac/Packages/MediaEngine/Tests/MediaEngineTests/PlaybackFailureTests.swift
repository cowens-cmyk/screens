import AVFoundation
import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

/// A video that can't play is refused or reported, never left in the player
/// table looking like it's about to start. None of this needs real-time
/// decoding, so it runs in a virtual machine too.
final class PlaybackFailureTests: XCTestCase {
    private var tempDir: URL!
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        self.device = device
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Text with a movie's name: what a damaged or half-copied file looks
    /// like to AVFoundation.
    private func bogusMovie() throws -> URL {
        let url = tempDir.appendingPathComponent("Veil_Countdown_4K.mov")
        try Data(String(repeating: "not a movie ", count: 500).utf8).write(to: url)
        return url
    }

    /// Prepared media for a file that never went through `prepare`, so the
    /// player meets the problem itself.
    private func unprepared(_ url: URL) -> PreparedMedia {
        PreparedMedia(
            url: url, duration: 300, frameDuration: 1.0 / 30, naturalSize: CGSize(width: 3840, height: 2160),
            hasAlpha: false, codec: "hvc1", hardwareDecodes: true,
            asset: AVURLAsset(url: url), audioTrack: nil
        )
    }

    func testPrepareRefusesAFileThatIsNotAVideo() async throws {
        let engine = try MediaEngine(device: device)
        do {
            _ = try await engine.prepare(url: bogusMovie())
            XCTFail("prepare accepted a text file")
        } catch {
            XCTAssertFalse(MediaEngine.describe(error).isEmpty)
        }
    }

    func testPrepareRefusesAMissingFile() async throws {
        let engine = try MediaEngine(device: device)
        let url = tempDir.appendingPathComponent("gone.mov")
        do {
            _ = try await engine.prepare(url: url)
            XCTFail("prepare accepted a missing file")
        } catch {}
    }

    func testPrepareDescribesAVideoItCanPlay() async throws {
        let url = tempDir.appendingPathComponent("clip.mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: CGSize(width: 320, height: 180), frameCount: 15
        ) { context, _ in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: url)
        XCTAssertEqual(media.codec, "avc1")
        XCTAssertNil(media.audioTrack)
        XCTAssertTrue(media.summary.hasPrefix("320×180 avc1 30 fps"), media.summary)
    }

    func testAFailingItemReportsThroughThePlayer() async throws {
        let reported = expectation(description: "failure reported")
        let problems = Locked<[PlaybackProblem]>([])
        let player = MediaPlayer(
            media: unprepared(try bogusMovie()), loop: false, factory: try SurfaceFactory(device: device),
            onProblem: { _, problem in
                problems.withLock { $0.append(problem) }
                if case .failed = problem { reported.fulfill() }
            }
        )
        player.startWatching()
        player.play()
        await fulfillment(of: [reported], timeout: 10)
        guard case .failed(let reason) = problems.value.first else {
            return XCTFail("expected a failure, got \(problems.value)")
        }
        XCTAssertFalse(reason.isEmpty)
        // Reported once, though the item and the player both fail.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(problems.value.filter { if case .failed = $0 { true } else { false } }.count, 1)
        player.stop()
    }

    func testAFailingLoopReportsToo() async throws {
        let reported = expectation(description: "failure reported")
        let player = MediaPlayer(
            media: unprepared(try bogusMovie()), loop: true, factory: try SurfaceFactory(device: device),
            onProblem: { _, problem in
                if case .failed = problem { reported.fulfill() }
            }
        )
        player.startWatching()
        player.play()
        await fulfillment(of: [reported], timeout: 10)
        player.stop()
    }

    func testTheEngineTakesAFailedVideoOffItsID() async throws {
        let engine = try MediaEngine(device: device)
        let reported = expectation(description: "handler told")
        let heard = Locked<[String]>([])
        engine.setPlaybackProblemHandler { id, problem in
            guard case .failed = problem else { return }
            heard.withLock { $0.append(id) }
            reported.fulfill()
        }
        engine.play(unprepared(try bogusMovie()), id: "countdown", loop: false)
        await fulfillment(of: [reported], timeout: 10)

        XCTAssertEqual(heard.value, ["countdown"])
        XCTAssertNil(engine.transport(id: "countdown"), "a failed video must not keep a transport")
        XCTAssertEqual(engine.motion(for: "countdown"), .still, "the screens must stop waiting on its frames")
        XCTAssertFalse(engine.hasPicture(id: "countdown"))
        XCTAssertNil(engine.playbackDiagnostics(id: "countdown"))
    }

    /// A file gone from disk fails at once, on another thread; the report
    /// must still reach the handler and take the player off its id.
    func testAMissingFileIsTakenOffItsIDToo() async throws {
        let engine = try MediaEngine(device: device)
        let reported = expectation(description: "handler told")
        engine.setPlaybackProblemHandler { _, problem in
            if case .failed = problem { reported.fulfill() }
        }
        let gone = tempDir.appendingPathComponent("gone.mov")
        engine.play(unprepared(gone), id: "gone", loop: true)
        await fulfillment(of: [reported], timeout: 10)
        XCTAssertNil(engine.transport(id: "gone"))
        XCTAssertEqual(engine.motion(for: "gone"), .still)
    }

    func testAReplacedPlayersFailureIsIgnored() async throws {
        let engine = try MediaEngine(device: device)
        let heard = Locked<[String]>([])
        engine.setPlaybackProblemHandler { id, _ in heard.withLock { $0.append(id) } }
        engine.play(unprepared(try bogusMovie()), id: "slot", loop: false)
        // Replaced before AVFoundation has had a chance to open the file.
        engine.stop(id: "slot")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(heard.value, [])
    }

    /// The watching must not take down a video that plays: once through
    /// to its end, and looping.
    func testAGoodVideoReportsNothing() async throws {
        let url = tempDir.appendingPathComponent("good.mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: CGSize(width: 320, height: 180), frameCount: 15
        ) { context, frame in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: CGFloat(frame) / 15, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let engine = try MediaEngine(device: device)
        let heard = Locked<[PlaybackProblem]>([])
        engine.setPlaybackProblemHandler { _, problem in heard.withLock { $0.append(problem) } }
        let media = try await engine.prepare(url: url)
        engine.play(media, id: "once", loop: false)
        engine.play(media, id: "loop", loop: true)
        let deadline = Date(timeIntervalSinceNow: 1.5)
        while Date() < deadline {
            _ = engine.surface(for: "once", hostTime: CACurrentMediaTime())
            _ = engine.surface(for: "loop", hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(heard.value.filter { if case .failed = $0 { true } else { false } }, [])
        XCTAssertNotNil(engine.transport(id: "once"))
        XCTAssertNotNil(engine.transport(id: "loop"))
        XCTAssertNotNil(engine.playbackDiagnostics(id: "loop"))
        engine.stopAll()
    }

    func testDescribeCarriesTheUnderlyingCode() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12906)
        let error = NSError(
            domain: AVFoundationErrorDomain, code: -11821,
            userInfo: [NSLocalizedDescriptionKey: "Cannot Decode", NSUnderlyingErrorKey: underlying])
        let line = MediaEngine.describe(error)
        XCTAssertTrue(line.contains("Cannot Decode"), line)
        XCTAssertTrue(line.contains("-11821"), line)
        XCTAssertTrue(line.contains("-12906"), line)
        XCTAssertEqual(
            MediaEngine.describe(MediaEngineError.cannotDecode(URL(fileURLWithPath: "/x.mov"), codec: "hvc1")),
            "This Mac can't decode its video (hvc1)")
    }

    func testFourCC() {
        XCTAssertEqual(MediaEngine.fourCC(kCMVideoCodecType_HEVC), "hvc1")
        XCTAssertEqual(MediaEngine.fourCC(kCMVideoCodecType_H264), "avc1")
    }
}
