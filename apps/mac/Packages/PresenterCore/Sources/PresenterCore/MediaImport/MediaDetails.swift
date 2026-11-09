import Foundation

/// Pictures and videos added in the CMS's browser editor arrive without
/// what only the file can say: a browser can't read every video (ProRes
/// above all), so its length and size may be missing and whether the Mac
/// can play it isn't known. The first Mac the file lands on reads it and
/// fills them in; every Mac reads the same file and writes the same values,
/// so two doing it at once is harmless.
public enum MediaDetails {
    /// The status detail the browser editor gives what it adds.
    public static let addedInBrowser = "Added in the browser"

    /// What reading the file found.
    public struct Probe: Equatable, Sendable {
        public var status: MediaFileStatus
        public var detail: String
        public var duration: Double?
        public var width: Int?
        public var height: Int?

        public init(status: MediaFileStatus, detail: String, duration: Double?, width: Int?, height: Int?) {
            self.status = status
            self.detail = detail
            self.duration = duration
            self.width = width
            self.height = height
        }
    }

    /// Whether the item's file should be read: anything the browser added,
    /// and a video marked playable that has no length. One read once and
    /// found wanting is marked otherwise, so it isn't read again and again.
    public static func needsProbe(_ item: MediaItem) -> Bool {
        if item.statusDetail == addedInBrowser { return true }
        return item.mediaKind == .video && item.fileStatus == .ready && item.durationSeconds == nil && item.statusDetail.isEmpty
    }

    /// The item with what was found. A value the file couldn't give keeps
    /// what the browser said.
    public static func applying(_ probe: Probe, to item: MediaItem) -> MediaItem {
        var out = item
        out.fileStatus = probe.status
        out.statusDetail = probe.detail
        out.durationSeconds = probe.duration ?? item.durationSeconds
        out.pixelWidth = probe.width ?? item.pixelWidth
        out.pixelHeight = probe.height ?? item.pixelHeight
        // A video read for its length that gave none isn't asked again.
        if out.mediaKind == .video, out.durationSeconds == nil, out.fileStatus == .ready, out.statusDetail.isEmpty {
            out.statusDetail = "length unknown"
        }
        return out
    }
}
