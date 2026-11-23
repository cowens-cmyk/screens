import Foundation

public enum DiagnosticsBundle {

    public struct Candidate: Equatable, Sendable {
        public var url: URL
        public var modified: Date
        public var byteSize: Int

        public init(url: URL, modified: Date, byteSize: Int) {
            self.url = url
            self.modified = modified
            self.byteSize = byteSize
        }
    }

    public static let reportWindowDays = 7
    public static let retentionDays = 14

    public static let byteCap = 25 * 1024 * 1024

    private static func cutoff(_ days: Int, before now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    public static func selection(
        from candidates: [Candidate], now: Date,
        windowDays: Int = reportWindowDays, byteCap: Int = byteCap
    ) -> [Candidate] {
        let since = cutoff(windowDays, before: now)
        var total = 0
        var chosen: [Candidate] = []
        for candidate in candidates.filter({ $0.modified >= since }).sorted(by: { $0.modified > $1.modified }) {
            if total + candidate.byteSize <= byteCap {
                total += candidate.byteSize
                chosen.append(candidate)
            }
        }
        return chosen
    }

    public static func expired(
        from candidates: [Candidate], now: Date, retentionDays: Int = retentionDays
    ) -> [Candidate] {
        let since = cutoff(retentionDays, before: now)
        return candidates.filter { $0.modified < since }
    }

    public static func isCrashReport(fileName: String) -> Bool {
        let name = fileName.lowercased()
        return name.hasPrefix("screens")
            && ["ips", "crash", "hang", "spin", "diag"].contains((name as NSString).pathExtension)
    }

    /// This app's crash reports since its last launch. `bundleID` leaves out
    /// reports of other apps named Screens: a staged perf build
    /// (com.example.mxuslides.perf) that crashed on the booth Mac had the
    /// next real launch ask what the operator was doing when it quit.
    /// Reports with no bundle id in their header (older formats) still count.
    public static func crashReports(
        in candidates: [Candidate], since previousLaunch: Date?, bundleID: String? = nil,
        reportBundleID: (URL) -> String? = Self.reportBundleID
    ) -> [Candidate] {
        candidates.filter { candidate in
            guard isCrashReport(fileName: candidate.url.lastPathComponent),
                  previousLaunch.map({ candidate.modified > $0 }) == true
            else { return false }
            guard let bundleID, let reported = reportBundleID(candidate.url) else { return true }
            return reported == bundleID
        }
    }

    /// The bundle id in a report's header: an .ips file's first line is a
    /// JSON object with a "bundleID" key.
    public static func reportBundleID(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? data[...]
        let header = (try? JSONSerialization.jsonObject(with: Data(firstLine))) as? [String: Any]
        return header?["bundleID"] as? String
    }

    public static func candidates(in folder: URL) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, let modified = values?.contentModificationDate {
                return Candidate(url: url, modified: modified, byteSize: values?.fileSize ?? 0)
            } else {
                return nil
            }
        }
    }
}
