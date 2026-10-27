import Foundation

/// Every plan opens with the pre-service slideshow, ahead of its countdown.
/// There is one slideshow for the whole church, and each plan's item links
/// to it rather than holding slides of its own, so a slide added from any
/// plan (or by the website-events sync) shows in every plan at once.
public enum PreServiceSlides {
    public static let itemName = "Pre-Service"
    public static let presentationName = "Pre-Service"

    // MARK: The shared slideshow

    /// A library presentation that might be the slideshow.
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let name: String
        /// The presentation's folder or type, as the library lists it.
        public let subkind: String

        public init(id: String, name: String, subkind: String = "") {
            self.id = id
            self.name = name
            self.subkind = subkind
        }
    }

    /// The slideshow every plan shows: the Service Day setup's while it's in
    /// the library, else the presentation named like Pre-Service. Among
    /// several, the plain "Pre-Service" comes first, then a name over a
    /// folder, then the shortest name, then the id, so every Mac looking at
    /// the same library picks the same one.
    public static func sharedID(
        serviceDayID: String?, inLibrary: (String) -> Bool, candidates: [Candidate]
    ) -> String? {
        if let serviceDayID, !serviceDayID.isEmpty, inLibrary(serviceDayID) { return serviceDayID }
        return candidates
            .filter { ServiceDay.looksLikePreService($0.name) || ServiceDay.looksLikePreService($0.subkind) }
            .min { a, b in rank(a) < rank(b) }?.id
    }

    private static func rank(_ candidate: Candidate) -> (Int, Int, Int, String, String) {
        let letters = candidate.name.lowercased().filter(\.isLetter)
        return (letters == "preservice" ? 0 : 1, ServiceDay.looksLikePreService(candidate.name) ? 0 : 1,
                candidate.name.count, candidate.name, candidate.id)
    }

    /// The slideshow made when the library has none: empty, ten seconds a
    /// slide, starting over at the end.
    public static func newSlideshow(id: String = UUID().uuidString) -> Presentation {
        var deck = Presentation(id: id, name: presentationName, presentationKind: .deck, themeId: "", slides: [])
        deck.autoAdvance = AutoAdvance(delaySeconds: ServiceDay.slideSeconds, loopToStart: true)
        return deck
    }

    // MARK: Plans

    /// The plan's pre-service item, if it has one.
    public static func item(in service: Service) -> ServiceItem? {
        service.items.first { $0.isPreService == true }
    }

    /// Whether an item is the shared slideshow as the plan shows it, for
    /// the "Shared" badge: marked, and linked to a presentation.
    public static func isShared(_ item: ServiceItem) -> Bool {
        item.isPreService == true && item.itemKind == .presentation && !item.refId.isEmpty
    }

    /// What a plan item is called when it stands for the pre-service slides:
    /// "Pre-Service", "Preservice", "PRE SERVICE", "Pre-Service Loop",
    /// "Announcements Loop". Kept to these so an item that only mentions
    /// pre-service isn't taken for it.
    public static func looksLikePreServiceItem(_ name: String) -> Bool {
        itemNames.contains(name.lowercased().filter(\.isLetter))
    }

    private static let itemNames: Set<String> = [
        "preservice", "preserviceloop", "preserviceslides", "preserviceslideshow",
        "preserviceannouncements", "announcementsloop", "announcementloop",
    ]

    /// How a plan gets the slideshow.
    public enum Change: Equatable, Sendable {
        /// An item the plan already has is the slideshow: one linked to it,
        /// or Shepherd's "Pre-Service". `link` is the slideshow to link an
        /// unlinked one to.
        case mark(itemID: String, link: String?)
        /// A new item first in the plan, linked to the slideshow.
        case insert(ServiceItem)
        /// The plan's item links to another pre-service slideshow (two Macs
        /// each made one before either saw the other's): it moves to the
        /// shared one.
        case relink(itemID: String, to: String)
    }

    /// What gives a plan the slideshow; nil when it needs nothing.
    ///
    /// Templates get it too, so plans made from them already have it. An
    /// item named as the pre-service slides is taken for it rather than a
    /// second added; one of those linked to something else is left as it
    /// is. A plan whose slideshow was taken out isn't given another, and
    /// with no slideshow in the library there's nothing to add.
    /// `isOtherSlideshow` says whether a presentation is another pre-service
    /// slideshow, which the plan's item is moved off.
    public static func change(
        for service: Service, sharedID: String?, isOtherSlideshow: (String) -> Bool = { _ in false },
        makeID: () -> String = { UUID().uuidString }
    ) -> Change? {
        let shared = sharedID.flatMap { $0.isEmpty ? nil : $0 }
        if let existing = item(in: service) {
            guard let shared, existing.refId != shared else { return nil }
            // Marked before there was a slideshow to link it to.
            if existing.refId.isEmpty { return .mark(itemID: existing.id, link: shared) }
            return isOtherSlideshow(existing.refId) ? .relink(itemID: existing.id, to: shared) : nil
        }
        if let shared, let linked = service.items.first(where: { $0.itemKind == .presentation && $0.refId == shared }) {
            return .mark(itemID: linked.id, link: nil)
        }
        if let named = service.items.first(where: { $0.itemKind != .header && looksLikePreServiceItem($0.name) }) {
            guard named.refId.isEmpty else { return nil }
            return .mark(itemID: named.id, link: shared)
        }
        guard service.preServiceRemoved != true, let shared else { return nil }
        var item = ServiceItem(id: makeID(), itemKind: .presentation, name: itemName, refId: shared)
        item.isPreService = true
        return .insert(item)
    }

    /// Applies a change to the plan as it stands now: false when there's
    /// nothing left to do (it has the slideshow by now, or the item is gone).
    @discardableResult
    public static func apply(_ change: Change, to service: inout Service) -> Bool {
        switch change {
        case .mark(let itemID, let link):
            guard let index = service.items.firstIndex(where: { $0.id == itemID }),
                  item(in: service).map({ $0.id == itemID }) ?? true
            else { return false }
            var marked = service.items[index]
            marked.isPreService = true
            if let link, marked.refId.isEmpty {
                marked.itemKind = .presentation
                marked.refId = link
            }
            guard marked != service.items[index] else { return false }
            service.items[index] = marked
        case .relink(let itemID, let shared):
            guard let index = service.items.firstIndex(where: { $0.id == itemID && $0.isPreService == true }),
                  service.items[index].refId != shared
            else { return false }
            service.items[index].itemKind = .presentation
            service.items[index].refId = shared
        case .insert(let item):
            // Worked out again, so an item added since (here or on another
            // Mac) isn't joined by a second.
            guard case .insert = self.change(for: service, sharedID: item.refId, makeID: { item.id }) else { return false }
            service.items.insert(item, at: 0)
        }
        return true
    }

    /// The plan with the slideshow (see `change(for:sharedID:)`), nil when
    /// it needs nothing.
    public static func ensuring(
        _ service: Service, sharedID: String?, isOtherSlideshow: (String) -> Bool = { _ in false }
    ) -> Service? {
        guard let change = change(for: service, sharedID: sharedID, isOtherSlideshow: isOtherSlideshow) else { return nil }
        var plan = service
        return apply(change, to: &plan) ? plan : nil
    }

    /// Takes an item out of the plan. Taking out the pre-service slideshow
    /// (or the countdown) is remembered, so the plan isn't given another.
    public static func remove(itemID: String, from service: inout Service) {
        if service.items.contains(where: { $0.id == itemID && $0.isPreService == true }) {
            service.preServiceRemoved = true
        }
        ServiceCountdown.remove(itemID: itemID, from: &service)
    }

    /// Points every plan's pre-service item at a new slideshow, when the
    /// Service Day setup is given a different one: nil when the plan has
    /// nothing to change.
    public static func relinking(_ service: Service, to sharedID: String) -> Service? {
        guard !sharedID.isEmpty else { return nil }
        var plan = service
        var changed = false
        for index in plan.items.indices where plan.items[index].isPreService == true {
            guard plan.items[index].refId != sharedID else { continue }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = sharedID
            changed = true
        }
        return changed ? plan : nil
    }
}

/// Plans made from a template, and templates made from a plan.
public enum PlanTemplate {
    /// The template's items for a new plan, each with a new id. The message
    /// gets a presentation of its own in each plan, so those items are
    /// listed for the caller to give one; the pre-service slideshow is never
    /// among them, since every plan shares it.
    public static func planItems(
        from template: Service, isMessage: (ServiceItem) -> Bool,
        makeID: () -> String = { UUID().uuidString }
    ) -> (items: [ServiceItem], messageItemIDs: [String]) {
        var messages: [String] = []
        let items = template.items.map { item in
            var copy = item
            copy.id = makeID()
            if item.isPreService != true,
               (!item.refId.isEmpty && item.refId == template.messagePresentationId) || isMessage(item) {
                messages.append(copy.id)
            }
            return copy
        }
        return (items, messages)
    }
}
