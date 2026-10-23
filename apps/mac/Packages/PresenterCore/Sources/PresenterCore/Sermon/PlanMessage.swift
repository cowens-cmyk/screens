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
        return plan.items.firstIndex { $0.itemKind == .presentation && isSermon($0.refId) }
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
