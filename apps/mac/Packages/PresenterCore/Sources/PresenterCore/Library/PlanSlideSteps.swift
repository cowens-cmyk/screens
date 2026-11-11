import Foundation

/// The plan's slides in firing order, one place per slide, for the arrow
/// keys on the Present page. A presentation with no slides has no places,
/// so a step goes straight past it to the next item that has some.
public enum PlanSlideSteps {
    public struct Place: Equatable, Sendable {
        public let itemID: String
        public let occurrence: Int

        public init(itemID: String, occurrence: Int) {
            self.itemID = itemID
            self.occurrence = occurrence
        }
    }

    /// Every slide of every presentation item, in plan order. `slideCount`
    /// is an item's arranged slide count, or nil while its presentation
    /// hasn't loaded; both leave the item out.
    public static func places(
        _ items: [ServiceItem], slideCount: (ServiceItem) -> Int?
    ) -> [Place] {
        items.filter { $0.itemKind == .presentation }.flatMap { item in
            (0 ..< max(slideCount(item) ?? 0, 0)).map { Place(itemID: item.id, occurrence: $0) }
        }
    }

    /// Where a step starts from, as ServiceControls sees the screens.
    public enum Start: Equatable, Sendable {
        /// A slide is live. When it isn't one of the plan's places (its
        /// deck lost slides while it was up) but its item is in the plan,
        /// the step starts from that item.
        case slide(Place)
        /// No plan slide is live, but this plan item's video or picture is
        /// up, or its video just ended by itself.
        case item(String)
        /// Nothing is on the slide layer and nothing from the plan is up:
        /// the plan hasn't started yet.
        case clear
        /// A slide from outside the plan is up (a deck fired from the
        /// library, or the walk-in restarted from Service Day).
        case elsewhere
    }

    /// The index in `places` that `delta` steps from `start` lands on.
    /// `order` is every item of the plan in run order, media items
    /// included, so a step from a video goes to the slides of the items
    /// around it: forward lands on the next item's first slide, back on
    /// the previous item's last. Only a clear screen starts at an end
    /// (forward at the first slide, back at the last). A slide from outside
    /// the plan steps nowhere, rather than pulling the walk-in back up over
    /// it. Nil past either end, or when the plan has no slides at all.
    public static func step(_ delta: Int, from start: Start, order: [String], in places: [Place]) -> Int? {
        guard !places.isEmpty, delta != 0 else { return nil }
        let next: Int
        switch start {
        case .slide(let live):
            if let current = places.firstIndex(of: live) {
                next = current + delta
            } else {
                return step(delta, from: .item(live.itemID), order: order, in: places)
            }
        case .item(let itemID):
            guard let anchor = order.firstIndex(of: itemID) else { return nil }
            let rank = { (place: Place) in order.firstIndex(of: place.itemID) }
            let found = delta > 0
                ? places.firstIndex { rank($0).map { $0 > anchor } ?? false }
                : places.lastIndex { rank($0).map { $0 < anchor } ?? false }
            guard let found else { return nil }
            next = found
        case .clear:
            next = delta > 0 ? 0 : places.count - 1
        case .elsewhere:
            return nil
        }
        return places.indices.contains(next) ? next : nil
    }
}
