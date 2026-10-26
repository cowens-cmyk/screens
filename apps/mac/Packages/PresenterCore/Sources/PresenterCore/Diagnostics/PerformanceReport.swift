import Foundation

/// Main-thread hangs over 100 ms, kept in a small ring so it can stay on
/// all the time: the watchdog adds one entry per hang and nothing else.
public struct HangLog: Sendable, Equatable {
    public struct Hang: Sendable, Equatable {
        public var at: Date
        public var milliseconds: Double
        /// What was on screen: the app mode and the run loop mode.
        public var context: String

        public init(at: Date, milliseconds: Double, context: String) {
            self.at = at
            self.milliseconds = milliseconds
            self.context = context
        }
    }

    public static let thresholdMS = 100.0

    public let capacity: Int
    public private(set) var total = 0
    private var ring: [Hang] = []
    private var nextSlot = 0

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    /// Adds `milliseconds` when it is a hang; returns whether it was.
    @discardableResult
    public mutating func record(milliseconds: Double, at date: Date, context: String) -> Bool {
        guard milliseconds >= Self.thresholdMS else { return false }
        let hang = Hang(at: date, milliseconds: milliseconds, context: context)
        total += 1
        if ring.count < capacity {
            ring.append(hang)
        } else {
            ring[nextSlot] = hang
        }
        nextSlot = (nextSlot + 1) % capacity
        return true
    }

    /// The kept hangs, oldest first.
    public var recent: [Hang] {
        guard ring.count == capacity else { return ring }
        return Array(ring[nextSlot...] + ring[..<nextSlot])
    }

    public func longest(_ count: Int) -> [Hang] {
        Array(ring.sorted { $0.milliseconds > $1.milliseconds }.prefix(count))
    }

    public func count(since date: Date) -> Int {
        ring.filter { $0.at >= date }.count
    }
}

/// The text of Help › Save Performance Report…: what the app is doing, for
/// someone looking into a slow show Mac. It names screens, devices and
/// threads, never people, presentations or files.
public struct PerformanceReport: Sendable {
    public struct ThreadLine: Sendable, Equatable {
        public var name: String
        public var cpuPercent: Double

        public init(name: String, cpuPercent: Double) {
            self.name = name
            self.cpuPercent = cpuPercent
        }
    }

    public struct FrameLine: Sendable, Equatable {
        public var kind: String
        public var label: String
        public var rendered: Int
        public var skipped: Int

        public init(kind: String, label: String, rendered: Int, skipped: Int) {
            self.kind = kind
            self.label = label
            self.rendered = rendered
            self.skipped = skipped
        }
    }

    public struct Display: Sendable, Equatable {
        public var name: String
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var refreshHz: Int

        public init(name: String, pixelWidth: Int, pixelHeight: Int, refreshHz: Int) {
            self.name = name
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.refreshHz = refreshHz
        }
    }

    public var generatedAt: Date
    public var appVersion: String
    public var system: String
    public var uptimeSeconds: Double
    public var sampleSeconds: Double
    public var processCPUPercent: Double
    public var threads: [ThreadLine]
    public var frames: [FrameLine]
    public var hangs: HangLog
    public var memoryFootprintBytes: UInt64
    public var memoryPeakBytes: UInt64
    public var displays: [Display]

    public init(
        generatedAt: Date, appVersion: String, system: String, uptimeSeconds: Double,
        sampleSeconds: Double, processCPUPercent: Double, threads: [ThreadLine],
        frames: [FrameLine], hangs: HangLog, memoryFootprintBytes: UInt64,
        memoryPeakBytes: UInt64, displays: [Display]
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.system = system
        self.uptimeSeconds = uptimeSeconds
        self.sampleSeconds = sampleSeconds
        self.processCPUPercent = processCPUPercent
        self.threads = threads
        self.frames = frames
        self.hangs = hangs
        self.memoryFootprintBytes = memoryFootprintBytes
        self.memoryPeakBytes = memoryPeakBytes
        self.displays = displays
    }

    /// Outputs in windows, NDI and DeckLink feeds, from the frame lines.
    public var outputWindowCount: Int { frames.filter { $0.kind == "output" }.count }
    public var ndiCount: Int { frames.filter { $0.kind == "feed" && $0.label.hasPrefix("NDI") }.count }
    public var deckLinkCount: Int {
        frames.filter { $0.kind == "feed" && $0.label.hasPrefix("DeckLink") }.count
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(total % 60)s"
    }

    public static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    public func text(timeZone: TimeZone = .current) -> String {
        let stamp = Date.ISO8601FormatStyle(timeZone: timeZone)
        var lines: [String] = []
        lines.append("Screens performance report")
        lines.append("Generated: \(generatedAt.formatted(stamp))")
        lines.append("Version: \(appVersion)")
        lines.append("System: \(system)")
        lines.append("Uptime: \(Self.duration(uptimeSeconds))")
        lines.append(String(
            format: "Memory: %@ footprint, %@ peak",
            Self.megabytes(memoryFootprintBytes), Self.megabytes(memoryPeakBytes)))
        lines.append(
            "Live outputs: \(outputWindowCount) window(s), \(ndiCount) NDI, \(deckLinkCount) DeckLink")
        lines.append("")

        lines.append("Displays")
        if displays.isEmpty { lines.append("  (none)") }
        for display in displays {
            lines.append(
                "  \(display.name): \(display.pixelWidth)×\(display.pixelHeight) at \(display.refreshHz) Hz")
        }
        lines.append("")

        lines.append(String(
            format: "CPU over %.0f s: %.1f%% of one core in all", sampleSeconds, processCPUPercent))
        let busy = threads.filter { $0.cpuPercent >= 0.05 }.sorted { $0.cpuPercent > $1.cpuPercent }
        for thread in busy {
            lines.append(String(format: "  %6.1f%%  %@", thread.cpuPercent, thread.name))
        }
        let idle = threads.count - busy.count
        if idle > 0 { lines.append("  \(idle) other thread(s) idle") }
        lines.append("")

        lines.append("Frames in the last 60 s (drawn / skipped because nothing changed)")
        if frames.isEmpty { lines.append("  (no views or feeds drawing)") }
        for frame in frames.sorted(by: { ($0.kind, $0.label) < ($1.kind, $1.label) }) {
            lines.append("  \(frame.kind) · \(frame.label): \(frame.rendered) drawn / \(frame.skipped) skipped")
        }
        lines.append("")

        let hour = generatedAt.addingTimeInterval(-3_600)
        lines.append(
            "Main-thread hangs over \(Int(HangLog.thresholdMS)) ms: \(hangs.total) since launch, "
                + "\(hangs.count(since: hour)) in the last hour")
        let longest = hangs.longest(10)
        if !longest.isEmpty {
            lines.append("  Longest:")
            for hang in longest {
                lines.append(String(
                    format: "    %5.0f ms  %@  %@", hang.milliseconds,
                    hang.at.formatted(stamp), hang.context))
            }
        }
        let recent = hangs.recent.suffix(20)
        if !recent.isEmpty {
            lines.append("  Most recent:")
            for hang in recent.reversed() {
                lines.append(String(
                    format: "    %5.0f ms  %@  %@", hang.milliseconds,
                    hang.at.formatted(stamp), hang.context))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
