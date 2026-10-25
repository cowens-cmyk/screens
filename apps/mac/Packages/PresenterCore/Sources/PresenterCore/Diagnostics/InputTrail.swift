import Foundation

public struct InputTrail: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let what: String
        public let at: TimeInterval
    }

    public static let capacity = 4

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func record(_ what: String, at time: TimeInterval) {
        if entries.last?.what == what {
            entries[entries.count - 1] = Entry(what: what, at: time)
        } else {
            entries.append(Entry(what: what, at: time))
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
        }
    }

    public func summary(at now: TimeInterval) -> String {
        if entries.isEmpty {
            "no input yet"
        } else {
            entries.reversed()
                .map { "\($0.what) \(String(format: "%.2f", max(0, now - $0.at))) s ago" }
                .joined(separator: " · ")
        }
    }

    public func age(of prefix: String, at now: TimeInterval) -> TimeInterval? {
        entries.last { $0.what.hasPrefix(prefix) }.map { now - $0.at }
    }

    public static func keyName(
        keyCode: UInt16, characters: String?,
        command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false
    ) -> String {
        let named: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "page up", 121: "page down", 115: "home", 119: "end",
            36: "return", 76: "enter", 49: "space", 48: "tab", 53: "esc",
            51: "delete", 117: "forward delete",
        ]
        let key = named[keyCode]
            ?? characters.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            ?? "code \(keyCode)"
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        return modifiers + key
    }
}

public enum PresentJumpRule {

    public static let viewportShare: CGFloat = 0.75

    public static let scrollWindow: TimeInterval = 0.5

    public static let focusWindow: TimeInterval = 1.0

    public static func isUnprompted(
        delta: CGFloat, viewport: CGFloat,
        sinceScroll: TimeInterval?, sinceFocus: TimeInterval?
    ) -> Bool {
        viewport > 0
            && abs(delta) >= viewport * viewportShare
            && (sinceScroll ?? .infinity) > scrollWindow
            && (sinceFocus ?? .infinity) > focusWindow
    }

    public static func isReflow(delta: CGFloat, offset: CGFloat, viewport: CGFloat) -> Bool {
        viewport > 0 && offset > 0 && abs(delta) >= viewport * viewportShare
    }
}

/// When the whole-plan page moves on its own, and when the plan list follows it.
public enum PresentFollowRule {

    /// After the operator scrolls the page it stays put this long, whatever
    /// goes live (the remote, Anthem, a slide's own timing).
    public static let scrollPause: TimeInterval = 3

    /// A slide clicked on the page this recently went live under the
    /// pointer; it's in view.
    public static let clickWindow: TimeInterval = 0.5

    /// How recent a scroll has to be for the page settling to count as the
    /// operator's: anything older moved it some other way.
    public static let settleWindow: TimeInterval = 1.5

    /// A slide put up by a key after the scroll (an arrow, the clicker) ends
    /// the pause. Typing elsewhere, a stage message, doesn't.
    public static func paused(sinceScroll: TimeInterval?, sinceKey: TimeInterval?) -> Bool {
        if let sinceScroll, sinceScroll < scrollPause {
            (sinceKey ?? .infinity) > sinceScroll
        } else {
            false
        }
    }

    /// The page scrolls to keep the new live slide in view.
    public static func reveals(
        sinceScroll: TimeInterval?, sinceKey: TimeInterval?, sinceClick: TimeInterval?
    ) -> Bool {
        !paused(sinceScroll: sinceScroll, sinceKey: sinceKey) && (sinceClick ?? .infinity) > clickWindow
    }

    /// The plan list highlights the live slide's item: a clicked one always,
    /// otherwise only while the page isn't held where the operator scrolled it.
    public static func selectsLive(
        sinceScroll: TimeInterval?, sinceKey: TimeInterval?, sinceClick: TimeInterval?
    ) -> Bool {
        (sinceClick ?? .infinity) <= clickWindow || !paused(sinceScroll: sinceScroll, sinceKey: sinceKey)
    }

    /// The page stopped where the operator's own scroll left it, not where a
    /// jump the app made (a plan-list click, following the live slide) did.
    public static func operatorScrolled(sinceScroll: TimeInterval?, sinceFocus: TimeInterval?) -> Bool {
        if let sinceScroll, sinceScroll < settleWindow {
            sinceScroll < (sinceFocus ?? .infinity)
        } else {
            false
        }
    }
}

/// Whether a slide going live may move the whole-plan page and the plan
/// list at all. Once the operator picks another item in the plan list, the
/// item that was live is let go: more of its slides going live, a
/// pre-service loop advancing every few seconds, leave the operator where
/// they are. The next item to go live is followed again, and so is the live
/// item once the operator picks it. A scroll has its own, shorter pause
/// (PresentFollowRule).
public struct PresentLiveHold: Equatable, Sendable {

    /// The live item the operator moved away from.
    public private(set) var letGo: String?

    public init() {}

    /// The operator picked an item (nil: the selection was cleared).
    public mutating func selected(_ itemID: String?, live: String?) {
        letGo = if let itemID, let live, itemID != live { live } else { nil }
    }

    /// A slide of `live` went up. The page follows it unless it's still the
    /// item the operator moved away from.
    public mutating func follows(live: String) -> Bool {
        if live == letGo {
            return false
        } else {
            letGo = nil
            return true
        }
    }
}

public enum PresentLanding {
    public struct Card: Equatable, Sendable {
        public let id: String
        public let top: CGFloat
        public let height: CGFloat

        public init(id: String, top: CGFloat, height: CGFloat) {
            self.id = id
            self.top = top
            self.height = height
        }
    }

    public static func cardAtTop(_ cards: [Card]) -> Card? {
        cards.first { $0.top <= 1 && $0.top + $0.height > 1 }
            ?? cards.filter { $0.top > 1 }.min { $0.top < $1.top }
    }

    /// The item the whole-plan page is showing: the one at the top, or the
    /// first below it. Header bands are passed over for the item under them.
    public static func itemAtTop(_ cards: [Card], skipping skipped: Set<String> = []) -> String? {
        cardAtTop(cards.filter { !skipped.contains($0.id) })?.id
    }

    /// The item the operator is looking at: the one crossing a line a third
    /// of the way down the page, so an item with only its last row showing
    /// at the top has already given way to the one filling the view. A
    /// header band on the line gives way to the item under it.
    public static func itemAtLine(_ cards: [Card], line: CGFloat, skipping skipped: Set<String> = []) -> String? {
        let items = cards.filter { !skipped.contains($0.id) }
        return (items.first { $0.top <= line && $0.top + $0.height > line }
            ?? items.filter { $0.top > line }.min { $0.top < $1.top }
            ?? items.filter { $0.top + $0.height <= line }.max { $0.top < $1.top })?.id
    }

    public struct Grid: Equatable, Sendable {
        public let id: String
        public let top: CGFloat
        public let rowPitch: CGFloat
        public let across: Int
        public let count: Int

        public init(id: String, top: CGFloat, rowPitch: CGFloat, across: Int, count: Int) {
            self.id = id
            self.top = top
            self.rowPitch = rowPitch
            self.across = across
            self.count = count
        }
    }

    public struct Anchor: Equatable, Sendable {
        public let id: String
        public let fraction: CGFloat
        public let slide: Int?
        public let intoRow: CGFloat

        public init(id: String, fraction: CGFloat, slide: Int? = nil, intoRow: CGFloat = 0) {
            self.id = id
            self.fraction = fraction
            self.slide = slide
            self.intoRow = intoRow
        }
    }

    public static func anchor(_ cards: [Card], grids: [Grid] = []) -> Anchor? {
        cardAtTop(cards).map { card in
            let fraction = card.height > 0 ? min(max(-card.top / card.height, 0), 1) : 0
            let grid = grids.first { $0.id == card.id }
            if let grid, grid.top <= 0, grid.rowPitch > 0, grid.across > 0, grid.count > 0 {
                let rows = (grid.count + grid.across - 1) / grid.across
                let row = min(Int(-grid.top / grid.rowPitch), rows - 1)
                let intoRow = min((-grid.top - CGFloat(row) * grid.rowPitch) / grid.rowPitch, 1)
                return Anchor(id: card.id, fraction: fraction, slide: row * grid.across, intoRow: intoRow)
            } else {
                return Anchor(id: card.id, fraction: fraction)
            }
        }
    }

    public static func correction(for anchor: Anchor, in cards: [Card], grids: [Grid] = []) -> CGFloat? {
        let grid = grids.first { $0.id == anchor.id }
        if let slide = anchor.slide, let grid, grid.across > 0, grid.rowPitch > 0 {
            let row = CGFloat(min(slide, max(grid.count - 1, 0)) / grid.across)
            return grid.top + row * grid.rowPitch + anchor.intoRow * grid.rowPitch
        } else {
            return cards.first { $0.id == anchor.id }.map { $0.top + anchor.fraction * $0.height }
        }
    }

    public static func rowTop(slide: Int, in grid: Grid) -> CGFloat {
        let row = min(max(slide, 0), max(grid.count - 1, 0)) / max(grid.across, 1)
        return grid.top + CGFloat(row) * grid.rowPitch
    }

    public static func reveal(
        rowTop: CGFloat, rowPitch: CGFloat, viewport: CGFloat, topInset: CGFloat, margin: CGFloat = 12
    ) -> CGFloat? {
        let top = topInset + margin
        let room = viewport - top
        let bandTop = top + room / 4
        let bandBottom = top + room * 3 / 4
        if rowTop < bandTop {
            return rowTop - bandTop
        } else if rowTop + rowPitch > bandBottom {

            return min(rowTop + rowPitch - bandBottom, rowTop - bandTop)
        } else {
            return nil
        }
    }
}

public enum PresentHold {

    public static func correction(heldTop: CGFloat, nowTop: CGFloat) -> CGFloat? {
        let delta = nowTop - heldTop
        return abs(delta) >= 1 ? delta : nil
    }

    public static let burst = 6
    public static let window: TimeInterval = 1

    public static func mayCorrect(recent: [TimeInterval], now: TimeInterval) -> Bool {
        recent.filter { now - $0 < window }.count < burst
    }

    public static func recording(_ time: TimeInterval, in recent: [TimeInterval]) -> [TimeInterval] {
        (recent.filter { time - $0 < window } + [time]).suffix(burst)
    }

    public static func changes(
        before: [String: CGFloat], after: [String: CGFloat], names: [String: String], limit: Int = 3
    ) -> String {
        let moved = after.compactMap { id, height -> (String, CGFloat)? in
            before[id].flatMap { old in abs(height - old) >= 1 ? (id, height - old) : nil }
        }
        let top = moved.sorted { abs($0.1) > abs($1.1) }.prefix(limit)
        return top.isEmpty
            ? "no card changed height"
            : top.map { "\"\(names[$0.0] ?? $0.0)\" \($0.1 > 0 ? "+" : "")\(Int($0.1))" }.joined(separator: ", ")
    }
}
