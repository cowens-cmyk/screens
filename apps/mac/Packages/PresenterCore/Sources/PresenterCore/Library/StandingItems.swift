import Foundation

/// Two items every Sunday has besides the plan's own: the Transition from
/// worship to the message (the sermon bumper, the Message lights, the
/// timer) right before the message, and the Walkout (the logo loop over the
/// whole stream while people leave) last. Each links to one standing
/// presentation chosen in the Service Day setup, like the pre-service
/// slideshow, so a plan imported from Shepherd fills them in by itself.
public enum StandingItems {
    public static let transitionName = "Transition"
    public static let walkoutName = "Walkout"
    /// How long the walkout plays before the pre-service slides come back.
    public static let defaultWalkoutReturnMinutes: Double = 8

    /// The plan's Closing Song, whatever song is in it: an item named for
    /// it ("Closing Song", "Closing"), or one the plan places at Closing (a
    /// song under a Closing header). Going up, it sets the Sermon timer back.
    public static func isClosingSong(_ item: ServiceItem, position: ServicePosition?) -> Bool {
        guard item.itemKind == .presentation || item.itemKind == .info else { return false }
        if case .closing = position { return true }
        if case .closing = ServicePosition.named(item.name) { return true }
        return false
    }

    public static func transition(in service: Service) -> ServiceItem? {
        service.items.first { $0.isTransition == true }
    }

    public static func walkout(in service: Service) -> ServiceItem? {
        service.items.first { $0.isWalkout == true }
    }

    /// Minutes the walkout plays before the pre-service slides, from the
    /// Service Day setup; anything under a minute counts as unset.
    public static func walkoutReturnMinutes(_ settings: ServiceDaySettings?) -> Double {
        guard let minutes = settings?.walkoutReturnMinutes, minutes >= 1 else { return defaultWalkoutReturnMinutes }
        return minutes
    }

    /// "Transition", "Worship to Message" and the like: an item that already
    /// is the transition, from Shepherd or added by hand.
    public static func looksLikeTransition(_ name: String) -> Bool {
        ["transition", "worshiptomessage", "messagetransition", "sermonbumper", "bumper"]
            .contains(ServicePosition.compacted(name))
    }

    /// "Walkout", "Walk Out", "Walkout Loop".
    public static func looksLikeWalkout(_ name: String) -> Bool {
        ["walkout", "walkoutloop", "walkoutvideo", "postservice"].contains(ServicePosition.compacted(name))
    }

    /// The plan's message item: the one the plan names, else the first item
    /// that `positions` (ServicePosition.positions) puts at the message —
    /// a sermon presentation, or an item under a MESSAGE header. The
    /// transition itself sits under that header and is never taken for it.
    public static func messageItemID(
        in service: Service, positions: [String: ServicePosition]
    ) -> String? {
        if let id = service.messagePresentationId, !id.isEmpty,
           let item = service.items.first(where: { $0.itemKind == .presentation && $0.refId == id }) {
            return item.id
        }
        return service.items.first { item in
            item.itemKind != .header && item.isTransition != true && item.isWalkout != true
                && item.isPreService != true && item.isCountdown != true && !item.isHidden
                && positions[item.id] == .message
        }?.id
    }

    /// The plan with its Transition and Walkout, nil when it needs nothing.
    ///
    /// `transitionID` and `walkoutID` are the Service Day's presentations,
    /// nil when none is chosen (or it isn't in the library); with none
    /// chosen the plan isn't given that item. A template is left alone. An
    /// item that plainly is one already (named so) is marked rather than a
    /// second added; an unlinked one is linked. A plan with no message gets
    /// no transition. The transition goes right before the message; the
    /// walkout goes last and is moved back to the end when a re-sync puts
    /// something after it. A plan whose item was taken out isn't given
    /// another.
    public static func ensuring(
        _ service: Service, transitionID: String?, walkoutID: String?, messageItemID: String?,
        makeID: () -> String = { UUID().uuidString }
    ) -> Service? {
        guard service.isTemplate != true else { return nil }
        var plan = service
        if let transitionID = nonEmpty(transitionID) {
            ensureTransition(in: &plan, link: transitionID, messageItemID: messageItemID, makeID: makeID)
        }
        if let walkoutID = nonEmpty(walkoutID) {
            ensureWalkout(in: &plan, link: walkoutID, makeID: makeID)
        }
        return plan == service ? nil : plan
    }

    private static func ensureTransition(
        in plan: inout Service, link: String, messageItemID: String?, makeID: () -> String
    ) {
        if let index = plan.items.firstIndex(where: { $0.isTransition == true }) {
            linkIfEmpty(&plan.items[index], to: link)
            return
        }
        if let index = plan.items.firstIndex(where: {
            $0.itemKind != .header && $0.isWalkout != true && looksLikeTransition($0.name)
        }) {
            plan.items[index].isTransition = true
            linkIfEmpty(&plan.items[index], to: link)
            return
        }
        guard plan.transitionRemoved != true, let messageItemID,
              let at = plan.items.firstIndex(where: { $0.id == messageItemID })
        else { return }
        var item = ServiceItem(id: makeID(), itemKind: .presentation, name: transitionName, refId: link)
        item.isTransition = true
        plan.items.insert(item, at: at)
    }

    private static func ensureWalkout(in plan: inout Service, link: String, makeID: () -> String) {
        var index = plan.items.firstIndex(where: { $0.isWalkout == true })
        if index == nil, let named = plan.items.firstIndex(where: {
            $0.itemKind != .header && $0.isTransition != true && looksLikeWalkout($0.name)
        }) {
            plan.items[named].isWalkout = true
            index = named
        }
        guard let index else {
            guard plan.walkoutRemoved != true, plan.items.contains(where: { $0.itemKind != .header }) else { return }
            var item = ServiceItem(id: makeID(), itemKind: .presentation, name: walkoutName, refId: link)
            item.isWalkout = true
            plan.items.append(item)
            return
        }
        linkIfEmpty(&plan.items[index], to: link)
        if index != plan.items.count - 1 {
            plan.items.append(plan.items.remove(at: index))
        }
    }

    private static func linkIfEmpty(_ item: inout ServiceItem, to link: String) {
        guard item.refId.isEmpty else { return }
        item.itemKind = .presentation
        item.refId = link
    }

    /// Points a plan's Transition (or Walkout) at the Service Day's new
    /// choice: nil when nothing changes.
    public static func relinking(_ service: Service, transitionID: String?, walkoutID: String?) -> Service? {
        var plan = service
        for index in plan.items.indices {
            let link = plan.items[index].isTransition == true ? nonEmpty(transitionID)
                : plan.items[index].isWalkout == true ? nonEmpty(walkoutID) : nil
            guard let link, plan.items[index].refId != link else { continue }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = link
        }
        return plan == service ? nil : plan
    }

    /// Remembers that a plan's Transition or Walkout was taken out, so it
    /// isn't put back. Call before the item is removed.
    public static func noteRemoval(itemID: String, from service: inout Service) {
        guard let item = service.items.first(where: { $0.id == itemID }) else { return }
        if item.isTransition == true { service.transitionRemoved = true }
        if item.isWalkout == true { service.walkoutRemoved = true }
    }

    private static func nonEmpty(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }
}
