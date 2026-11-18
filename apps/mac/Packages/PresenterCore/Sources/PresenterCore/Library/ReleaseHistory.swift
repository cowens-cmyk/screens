import Foundation

/// Screens' published releases, for going back to an earlier one when a new
/// release misbehaves (Screens › Install Earlier Version…).
public enum ReleaseHistory {
    public struct Listing: Equatable, Sendable {
        public var tag: String
        public var draft: Bool
        public var prerelease: Bool
        public var hasDMG: Bool

        public init(tag: String, draft: Bool = false, prerelease: Bool = false, hasDMG: Bool = true) {
            self.tag = tag
            self.draft = draft
            self.prerelease = prerelease
            self.hasDMG = hasDMG
        }

        /// "v0.44.0" → "0.44.0".
        public var version: String {
            tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }
    }

    /// The releases older than `current` that can be installed, newest
    /// first: published (not drafts or pre-releases), with a DMG, each
    /// version once.
    public static func earlier(_ releases: [Listing], than current: String, limit: Int = .max) -> [Listing] {
        var seen = Set<String>()
        return releases
            .filter { !$0.draft && !$0.prerelease && $0.hasDMG }
            .filter { $0.version.compare(current, options: .numeric) == .orderedAscending }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            .filter { seen.insert($0.version).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
