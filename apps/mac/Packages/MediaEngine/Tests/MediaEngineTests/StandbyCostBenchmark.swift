import AVFoundation
import Darwin
import Foundation
import Metal
import XCTest
@testable import MediaEngine

/// What a worship background costs to start cold against starting from a
/// player standing by, and what each player standing by holds in memory.
/// It answers whether every video in a day's plan could stand by on a big
/// Mac. A benchmark rather than a check: it writes full-HD movies and only
/// runs when MXU_MEDIA_BENCH=1, printing its numbers.
@MainActor
final class StandbyCostBenchmark: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MXU_MEDIA_BENCH"] == "1", "set MXU_MEDIA_BENCH=1")
        try XCTSkipIf(isVirtualMachine(), "timings only mean something on a real Mac")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StandbyCostBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func footprint(of pid: pid_t = getpid()) -> Int64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : 0
    }

    /// The decoders run in VTDecoderXPCService, outside this process: its
    /// footprint (all of them, as far as this user can see) is the rest of
    /// what a player standing by costs.
    private func decoderServiceFootprint() -> Int64 {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "VTDecoderXPCService"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return 0 }
        pgrep.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { pid_t($0) }.reduce(0) { $0 + footprint(of: $1) }
    }

    /// A five-second full-HD loop with motion in every frame, like a motion background.
    private func makeBackground(
        _ name: String, codec: MediaAuthoring.Codec, framesPerSecond: Int32 = 30
    ) async throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try await MediaAuthoring.writeMovie(
            to: url, codec: codec, size: CGSize(width: 1920, height: 1080),
            frameCount: Int(framesPerSecond) * 5, framesPerSecond: framesPerSecond
        ) { context, frame in
            let t = CGFloat(frame) / 150
            context.setFillColor(CGColor(srgbRed: 0.1 + 0.3 * t, green: 0.2, blue: 0.5 - 0.3 * t, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            for band in 0..<24 {
                context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05 + 0.02 * CGFloat(band % 5)))
                context.fill(CGRect(x: CGFloat((band * 97 + frame * 13) % 1920), y: CGFloat(band * 45), width: 160, height: 40))
            }
        }
        return url
    }

    /// Milliseconds from asking for the video to the engine having its first picture.
    private func firstPicture(_ engine: MediaEngine, id: String, start: () async throws -> Void) async throws -> Double {
        let begin = CACurrentMediaTime()
        try await start()
        let deadline = begin + 5
        while CACurrentMediaTime() < deadline {
            if engine.hasPicture(id: id) { return (CACurrentMediaTime() - begin) * 1000 }
            try await Task.sleep(for: .milliseconds(2))
        }
        return .infinity
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func testColdStartAgainstStandingByAndWhatEachPlayerHolds() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for codec in [MediaAuthoring.Codec.h264, .hevc] {
            var urls: [URL] = []
            for n in 0..<12 { urls.append(try await makeBackground("bg-\(codec)-\(n).mov", codec: codec)) }

            // Cold, as 0.35.0 starts every background: open, make a player, play.
            var cold: [Double] = []
            for (n, url) in urls.prefix(6).enumerated() {
                let engine = try MediaEngine(device: device)
                cold.append(try await firstPicture(engine, id: "cold\(n)") {
                    let media = try await engine.prepare(url: url)
                    engine.play(media, id: "cold\(n)", loop: true)
                })
                engine.stopAll()
            }

            // A player standing by, as 0.36.0 readies the next items' videos.
            var warm: [Double] = []
            for (n, url) in urls.suffix(6).enumerated() {
                let engine = try MediaEngine(device: device)
                await engine.standBy(playing: url, loop: true)
                warm.append(try await firstPicture(engine, id: "warm\(n)") {
                    let media = try await engine.prepare(url: url)
                    engine.play(media, id: "warm\(n)", loop: true)
                })
                engine.stopAll()
            }

            // Memory: twelve players standing by at once.
            let engine = try MediaEngine(device: device)
            try await Task.sleep(for: .milliseconds(500))
            let before = footprint()
            let decodersBefore = decoderServiceFootprint()
            for url in urls { await engine.standBy(playing: url, loop: true) }
            try await Task.sleep(for: .milliseconds(500))
            let perPlayer = Double(footprint() - before) / Double(urls.count) / 1_048_576
            let perDecoder = Double(decoderServiceFootprint() - decodersBefore) / Double(urls.count) / 1_048_576
            XCTAssertEqual(engine.standbyPlayerCount, urls.count)
            engine.releaseStandbyPlayers(keeping: [])
            engine.stopAll()

            print(String(
                format: "standby-bench %@ 1080p30: cold first picture median %.0f ms (max %.0f), standing by median %.0f ms (max %.0f), per player standing by %.1f MB here + %.1f MB in VTDecoderXPCService (those services held %.0f MB before)",
                "\(codec)", median(cold), cold.max() ?? 0, median(warm), warm.max() ?? 0, perPlayer, perDecoder,
                Double(decodersBefore) / 1_048_576))
        }
    }

    /// The evidence a bigger cap would need: twelve standing by (the cap on
    /// a 32 GB Mac) while four others play 1080p60, and a thirteenth started
    /// cold still gets its first picture. Prints how long that took.
    func testAThirteenthStartsWhileTwelveStandByAndFourPlay() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let engine = try MediaEngine(device: device)
        var waiting: [URL] = []
        for n in 0..<12 {
            waiting.append(try await makeBackground("waiting-\(n).mov", codec: n.isMultiple(of: 2) ? .h264 : .hevc))
        }
        var playing: [URL] = []
        for n in 0..<4 {
            playing.append(try await makeBackground("playing-\(n).mov", codec: .h264, framesPerSecond: 60))
        }
        let late = try await makeBackground("thirteenth.mov", codec: .h264)

        for url in waiting { await engine.standBy(playing: url, loop: true) }
        XCTAssertEqual(engine.standbyPlayerCount, 12)
        for (n, url) in playing.enumerated() {
            let id = "playing\(n)"
            _ = try await firstPicture(engine, id: id) {
                engine.play(try await engine.prepare(url: url), id: id, loop: true)
            }
        }
        // The four run for two seconds, their frames pulled as the outputs would.
        let until = CACurrentMediaTime() + 2
        while CACurrentMediaTime() < until {
            for n in 0..<4 { _ = engine.surface(for: "playing\(n)", hostTime: CACurrentMediaTime()) }
            try await Task.sleep(for: .milliseconds(16))
        }
        let ms = try await firstPicture(engine, id: "thirteenth") {
            engine.play(try await engine.prepare(url: late), id: "thirteenth", loop: true)
        }
        let running = (0..<4).filter { (engine.stats(for: "playing\($0)")?.framesDisplayed ?? 0) > 0 }.count
        print(String(
            format: "standby-bench load: 12 standing by, %d of 4 playing 1080p60, a 13th cold play's first picture in %.0f ms",
            running, ms))
        XCTAssertLessThan(ms, 1000, "the thirteenth got no picture within a second")
        XCTAssertEqual(engine.standbyPlayerCount, 12)
        engine.releaseStandbyPlayers(keeping: [])
        engine.stopAll()
    }
}
