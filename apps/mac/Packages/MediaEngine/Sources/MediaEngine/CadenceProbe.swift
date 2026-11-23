import Foundation
import RenderEngine

/// How evenly each screen shows a playing video: for every render that draws
/// a video, which frame the screen was given (RenderConsumer names the
/// screen). A screen drawing a 30 fps video at 60 Hz should hold every frame
/// for two refreshes, at 30 Hz for one. Every ten seconds, for each screen
/// that drew a video, `onSummary` gets one line: renders and their rate,
/// frames shown, the share held for the wrong number of refreshes, frames
/// skipped, and the share of renders that fell within 2 ms of a frame's
/// edge (where a few milliseconds of timer jitter flips which frame shows).
/// With `traceFolder` set, every render is also written there, one line each.
public final class CadenceProbe: @unchecked Sendable {
    public static let shared = CadenceProbe()

    /// One line per screen, every `period` seconds.
    public let onSummary = Locked<(@Sendable (String) -> Void)?>(nil)
    /// Where every render is written when set (a .tsv per period).
    public let traceFolder = Locked<URL?>(nil)

    let period: Double

    private struct Key: Hashable {
        let consumer: String
        let player: ObjectIdentifier
    }

    struct Tally: Equatable {
        var renders = 0
        var frames = 0
        var unevenHolds = 0
        var skipped = 0
        var nearEdge = 0
        var intervalSum = 0.0
        var intervals = 0
        var frameDuration = 0.0
        var lastPTS: Double?
        var lastHost: Double?
        var hold = 0
        var heldSamples: [Int] = []

        /// The refreshes a frame should be held: the frame's length over the
        /// screen's own interval, when that is close to a whole number.
        var expectedHold: Int? {
            guard intervals > 0, frameDuration > 0 else { return nil }
            let ratio = frameDuration / (intervalSum / Double(intervals))
            let rounded = ratio.rounded()
            return rounded >= 1 && abs(ratio - rounded) < 0.15 ? Int(rounded) : nil
        }

        mutating func record(hostTime: Double, itemTime: Double, pts: Double, frameDuration: Double, tolerance: Double) {
            renders += 1
            self.frameDuration = frameDuration
            if let lastHost {
                let gap = hostTime - lastHost
                if gap > 0, gap < 0.2 { intervalSum += gap; intervals += 1 }
            }
            lastHost = hostTime
            // Time left before the next frame would be chosen at this time.
            let edge = pts + frameDuration - tolerance
            if abs(edge - itemTime) < 0.002 || abs(pts - tolerance - itemTime) < 0.002 { nearEdge += 1 }
            if let lastPTS, abs(pts - lastPTS) < frameDuration / 4 {
                hold += 1
                return
            }
            if let lastPTS {
                finishHold()
                let steps = ((pts - lastPTS) / frameDuration).rounded()
                if steps > 1, steps < 30 { skipped += Int(steps) - 1 }
            }
            frames += 1
            self.lastPTS = pts
            hold = 1
        }

        mutating func finishHold() {
            guard hold > 0 else { return }
            heldSamples.append(hold)
            if heldSamples.count > 4096 { heldSamples.removeFirst(heldSamples.count - 4096) }
        }

        /// Holds that weren't the expected length, the first and last left out
        /// (a video starting or stopping).
        var uneven: Int {
            guard let expected = expectedHold, heldSamples.count > 2 else { return 0 }
            return heldSamples.dropFirst().filter { $0 != expected }.count
        }
    }

    private let lock = NSLock()
    private var tallies: [Key: Tally] = [:]
    private var trace: [String] = []
    private var lastFlush: Double = 0

    public init(period: Double = 10) {
        self.period = period
    }

    /// A render chose the frame at `pts` for `itemTime` (at `hostTime`).
    func record(
        player: ObjectIdentifier, hostTime: Double, itemTime: Double, pts: Double,
        frameDuration: Double, tolerance: Double
    ) {
        guard let consumer = RenderConsumer.current, frameDuration > 0 else { return }
        let tracing = traceFolder.value != nil
        var lines: [String] = []
        var write: (URL, [String])?
        lock.lock()
        tallies[Key(consumer: consumer, player: player), default: Tally()].record(
            hostTime: hostTime, itemTime: itemTime, pts: pts, frameDuration: frameDuration, tolerance: tolerance)
        if tracing {
            trace.append(String(format: "%@\t%.5f\t%.5f\t%.5f", consumer, hostTime, itemTime, pts))
        }
        if lastFlush == 0 { lastFlush = hostTime }
        if hostTime - lastFlush >= period {
            lastFlush = hostTime
            lines = tallies.map { key, tally in Self.summary(key.consumer, tally) }.sorted()
            tallies.removeAll()
            if let folder = traceFolder.value, !trace.isEmpty {
                write = (folder, trace)
                trace.removeAll()
            }
        }
        lock.unlock()
        if !lines.isEmpty, let note = onSummary.value { lines.forEach(note) }
        if let (folder, rows) = write { Self.append(rows, to: folder) }
    }

    static func summary(_ consumer: String, _ tally: Tally) -> String {
        var tally = tally
        tally.finishHold()
        let rate = tally.intervals > 0 ? Double(tally.intervals) / tally.intervalSum : 0
        let holds = max(1, tally.heldSamples.count - 1)
        let expected = tally.expectedHold.map { "\($0)" } ?? "?"
        return String(
            format: "%@: %d renders at %.1f Hz, %d frames, uneven holds %d%% (of %d, each should be %@), skipped %d, near a frame edge %d%%",
            consumer, tally.renders, rate, tally.frames, Int((100 * Double(tally.uneven) / Double(holds)).rounded()),
            holds, expected, tally.skipped, Int((100 * Double(tally.nearEdge) / Double(max(1, tally.renders))).rounded()))
    }

    private static func append(_ rows: [String], to folder: URL) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let url = folder.appendingPathComponent("cadence-\(day).tsv")
        let data = Data((rows.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
