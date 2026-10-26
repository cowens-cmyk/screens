import Foundation
import Testing

@testable import PresenterCore

@Suite struct HangLogTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyStallsOverTheThresholdCount() {
        var log = HangLog(capacity: 4)
        let short = log.record(milliseconds: 40, at: base, context: "Present")
        let long = log.record(milliseconds: 100, at: base, context: "Present")
        #expect(!short)
        #expect(long)
        #expect(log.total == 1)
    }

    @Test func theRingKeepsTheNewestAndCountsAll() {
        var log = HangLog(capacity: 3)
        for index in 0..<5 {
            log.record(milliseconds: 100 + Double(index), at: base.addingTimeInterval(Double(index)), context: "\(index)")
        }
        #expect(log.total == 5)
        #expect(log.recent.map(\.context) == ["2", "3", "4"])
        #expect(log.longest(2).map(\.milliseconds) == [104, 103])
        #expect(log.count(since: base.addingTimeInterval(3)) == 2)
    }
}

@Suite struct PerformanceReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func report() -> PerformanceReport {
        var hangs = HangLog()
        hangs.record(milliseconds: 420, at: now.addingTimeInterval(-60), context: "Present · default")
        hangs.record(milliseconds: 130, at: now.addingTimeInterval(-7_200), context: "Edit · tracking")
        return PerformanceReport(
            generatedAt: now, appVersion: "0.18.2 (165)", system: "macOS 26.7", uptimeSeconds: 90_061,
            sampleSeconds: 2, processCPUPercent: 31.5,
            threads: [
                .init(name: "main", cpuPercent: 12.25),
                .init(name: "RenderEngine.RenderThread", cpuPercent: 4),
                .init(name: "unnamed 7", cpuPercent: 0),
            ],
            frames: [
                .init(kind: "output", label: "Output window on DELL U2720Q", rendered: 61, skipped: 3_539),
                .init(kind: "feed", label: "DeckLink UltraStudio 1920×1080@60", rendered: 61, skipped: 3_539),
                .init(kind: "feed", label: "NDI Livestream 1920×1080@30", rendered: 1_800, skipped: 0),
            ],
            hangs: hangs, memoryFootprintBytes: 1_610_612_736, memoryPeakBytes: 2_040_109_465,
            displays: [.init(name: "DELL U2720Q", pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60)])
    }

    @Test func listsWhatTheShowMacIsDoing() {
        let text = report().text(timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.contains("Version: 0.18.2 (165)"))
        #expect(text.contains("Uptime: 1d 1h 1m"))
        #expect(text.contains("Memory: 1536 MB footprint"))
        #expect(text.contains("Live outputs: 1 window(s), 1 NDI, 1 DeckLink"))
        #expect(text.contains("DELL U2720Q: 3840×2160 at 60 Hz"))
        #expect(text.contains("  12.2%  main") || text.contains("  12.3%  main"))
        #expect(text.contains("1 other thread(s) idle"))
        #expect(text.contains("feed · DeckLink UltraStudio 1920×1080@60: 61 drawn / 3539 skipped"))
        #expect(text.contains("2 since launch, 1 in the last hour"))
        #expect(text.contains("420 ms"))
    }

    @Test func busiestThreadsComeFirst() {
        let text = report().text()
        let main = text.range(of: "main")!.lowerBound
        let render = text.range(of: "RenderEngine.RenderThread")!.lowerBound
        #expect(main < render)
    }
}
