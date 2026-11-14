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

    private func footprint() -> Int64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : 0
    }

    /// A five-second full-HD loop with motion in every frame, like a motion background.
    private func makeBackground(_ name: String, codec: MediaAuthoring.Codec) async throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try await MediaAuthoring.writeMovie(
            to: url, codec: codec, size: CGSize(width: 1920, height: 1080), frameCount: 150
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
            for url in urls { await engine.standBy(playing: url, loop: true) }
            try await Task.sleep(for: .milliseconds(500))
            let perPlayer = Double(footprint() - before) / Double(urls.count) / 1_048_576
            XCTAssertEqual(engine.standbyPlayerCount, urls.count)
            engine.releaseStandbyPlayers(keeping: [])
            engine.stopAll()

            print(String(
                format: "standby-bench %@ 1080p30: cold first picture median %.0f ms (max %.0f), standing by median %.0f ms (max %.0f), %.1f MB per player standing by",
                "\(codec)", median(cold), cold.max() ?? 0, median(warm), warm.max() ?? 0, perPlayer))
        }
    }
}
