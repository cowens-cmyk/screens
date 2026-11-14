import Foundation
import PresenterCore

/// Every slide of a plan in the order the arrow key walks them, with where
/// each one is. ServiceControls rebuilt this list on every fire (every deck
/// arranged again, then two linear searches and a count); built once per
/// plan and deck version, a fire looks its place up instead.
public struct PlanSlideIndex: Sendable {
    public struct Entry: Sendable {
        public let itemID: String
        public let occurrence: Int
        public let slide: Slide
        public let presentation: Presentation
        public let arrangementId: String?
    }

    private struct Place: Hashable {
        let itemID: String
        let occurrence: Int
    }

    public let entries: [Entry]
    private let positions: [Place: Int]
    private let counts: [String: Int]

    /// One plan item that shows a presentation, in run order.
    public struct Item: Sendable {
        public let itemID: String
        public let arrangementId: String?
        public let presentation: Presentation

        public init(itemID: String, arrangementId: String?, presentation: Presentation) {
            self.itemID = itemID
            self.arrangementId = arrangementId
            self.presentation = presentation
        }
    }

    public init(items: [Item]) {
        var entries: [Entry] = []
        var positions: [Place: Int] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let slides = SlideSceneBuilder.arrangedSlides(for: item.presentation, arrangementId: item.arrangementId)
            for (occurrence, slide) in slides.enumerated() {
                let place = Place(itemID: item.itemID, occurrence: occurrence)
                // The first wins, as firstIndex did: an item listed twice
                // finds its first run.
                if positions[place] == nil { positions[place] = entries.count }
                entries.append(Entry(
                    itemID: item.itemID, occurrence: occurrence, slide: slide,
                    presentation: item.presentation, arrangementId: item.arrangementId))
            }
            counts[item.itemID, default: 0] += slides.count
        }
        self.entries = entries
        self.positions = positions
        self.counts = counts
    }

    /// Where a slide sits in the walk, nil when it isn't in the plan.
    public func position(itemID: String, occurrence: Int) -> Int? {
        positions[Place(itemID: itemID, occurrence: occurrence)]
    }

    /// How many slides an item has, every time it is listed.
    public func count(itemID: String) -> Int {
        counts[itemID] ?? 0
    }
}
