import Foundation

/// Where a plan's message lives: the item the plan names as its message, or
/// failing that its first sermon presentation.
public enum PlanMessage {

    /// The plan's message item. `isSermon` says whether a presentation is a
    /// message (its category is Sermon), for plans made before the plan
    /// kept track of it.
    public static func itemIndex(in plan: Service, isSermon: (String) -> Bool) -> Int? {
        if let id = plan.messagePresentationId, !id.isEmpty,
           let index = plan.items.firstIndex(where: { $0.itemKind == .presentation && $0.refId == id }) {
            return index
        }
        if let index = plan.items.firstIndex(where: { $0.itemKind == .presentation && isSermon($0.refId) }) {
            return index
        }
        return plannedItemIndex(in: plan).flatMap { plan.items[$0].itemKind == .presentation ? $0 : nil }
    }

    /// The item Shepherd planned as the message: one of Shepherd's own
    /// items under the plan's Message header that isn't a song, the
    /// transition, the countdown or the walkout; the longest planned one
    /// when there are several. It is the message even when its slides were
    /// dropped into a plain presentation that was never filed as one.
    public static func plannedItemIndex(in plan: Service) -> Int? {
        let positions = ServicePosition.positions(in: plan.items)
        let candidates = plan.items.indices.filter { index in
            let item = plan.items[index]
            return positions[item.id] == .message
                && item.mxuSourceItemId != nil && item.mxuKind != "song" && item.itemKind != .header
                && item.isTransition != true && item.isCountdown != true && item.isWalkout != true
                && item.isPreService != true
        }
        return candidates.max { (plan.items[$0].duration ?? 0) < (plan.items[$1].duration ?? 0) }
            .flatMap { best in
                // The first of the longest, in plan order.
                candidates.first { (plan.items[$0].duration ?? 0) == (plan.items[best].duration ?? 0) }
            }
    }

    /// Makes a newly imported message the plan's message: it takes the place
    /// of the old one in the order, or goes at the end when there is none.
    /// The plan follows the series the message was built with.
    public static func place(
        _ presentationID: String, name: String, series: String?, in plan: inout Service,
        isSermon: (String) -> Bool
    ) {
        if let index = itemIndex(in: plan, isSermon: isSermon) {
            plan.items[index].refId = presentationID
        } else {
            plan.items.append(ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: name, refId: presentationID))
        }
        plan.messagePresentationId = presentationID
        if let series, !series.isEmpty { plan.sermonThemeId = series }
    }
}
