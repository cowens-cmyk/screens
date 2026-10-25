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

    /// The index in `places` that `delta` steps from the live slide lands
    /// on. With nothing live here (or the live slide gone), forward starts
    /// at the first slide and back at the last. Nil past either end, or when
    /// the plan has no slides at all.
    public static func step(_ delta: Int, from live: Place?, in places: [Place]) -> Int? {
        guard !places.isEmpty, delta != 0 else { return nil }
        let next: Int
        if let live, let current = places.firstIndex(of: live) {
            next = current + delta
        } else {
            next = delta > 0 ? 0 : places.count - 1
        }
        return places.indices.contains(next) ? next : nil
    }
}
