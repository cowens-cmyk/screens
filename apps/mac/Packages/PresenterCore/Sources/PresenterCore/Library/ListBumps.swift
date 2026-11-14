import Foundation

/// How often the library's "lists changed" signal may reach the UI. Every
/// create or edit bumped it twice (the optimistic write, then the landed
/// batch), and every bump re-ran the plan page and every list; an import of
/// 300 files was 600 whole-page passes. The first bump after a quiet spell
/// goes out at once, so a single edit shows as before; bumps inside the
/// next `interval` fold into one more at its end, so the UI always ends on
/// the final state, never more than `interval` late.
public struct BumpThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Bump now.
        case now
        /// Bump once this much later (start a timer, then call trailingFired).
        case after(TimeInterval)
        /// A trailing bump is already on its way and will carry this one.
        case folded
    }

    public let interval: TimeInterval
    private var lastBump: TimeInterval?
    public private(set) var pending = false

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public mutating func ask(now: TimeInterval) -> Decision {
        if pending { return .folded }
        if let lastBump, now >= lastBump, now - lastBump < interval {
            pending = true
            return .after(interval - (now - lastBump))
        }
        lastBump = now
        return .now
    }

    /// The trailing bump went out.
    public mutating func trailingFired(now: TimeInterval) {
        pending = false
        lastBump = now
    }
}

/// Which decks' tiles have to redraw after the library moved: the decks
/// the screen is showing whose listed `updatedAt` (the thumbnails' cache
/// stamp) differs between what the tiles last read and now. A tile reads
/// only its own deck's stamp, so an imported picture or an edit to another
/// deck leaves it alone.
public enum DeckStamps {
    public static func changed(
        watched: some Sequence<String>, before: IndexSnapshot?, after: IndexSnapshot
    ) -> Set<String> {
        Set(watched.filter { before?.entry(id: $0)?.updatedAt != after.entry(id: $0)?.updatedAt })
    }
}
