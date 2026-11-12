import Foundation

/// Plan items that every Sunday shows the same slides for, each linked to
/// one presentation the whole church shares, like the pre-service
/// slideshow: Shepherd's "Announcements" (between the songs) and "Closing"
/// (after the message). Linked, their slides can be added and deleted in
/// Screens and every plan, past templates and future Shepherd plans alike,
/// shows the same ones. Without it they came in from Shepherd as "Not
/// Linked", with nowhere to put a slide.
///
/// The Transition is one of these presentations too, but StandingItems
/// places it (right before the message) rather than a name in the plan;
/// this only finds or makes the presentation it links to when the Service
/// Day setup hasn't chosen one.
///
/// None of them is the pre-service slideshow: "Announcements Loop" and the
/// like stay the pre-service item (PreServiceSlides.looksLikePreServiceItem).
public enum SharedPlanItems {

    public enum Slot: String, CaseIterable, Sendable {
        case announcements
        case closing
        case transition

        /// The shared presentation's name, and the name it's found by.
        public var presentationName: String {
            switch self {
            case .announcements: PresentationTypes.announcements
            case .closing: "Closing"
            case .transition: StandingItems.transitionName
            }
        }

        /// The presentation type a new one is given.
        var category: String? {
            switch self {
            case .announcements: PresentationTypes.announcements
            case .closing, .transition: nil
            }
        }

        /// Plan items with these names (compacted) link to it. The
        /// Transition is placed by StandingItems instead.
        var itemNames: Set<String> {
            switch self {
            case .announcements:
                ["announcements", "announcement", "weeklyannouncements", "churchannouncements",
                 "announcementslides", "announcementsslides"]
            case .closing:
                ["closing", "closingslide", "closingslides", "closingremarks", "closingannouncements"]
            case .transition:
                []
            }
        }

        /// The slots linked by an item's name.
        public static let linkedByName: [Slot] = [.announcements, .closing]
    }

    /// The slot an item's name stands for: "Announcements", "Weekly
    /// Announcements", "Closing"; nil for anything else, including one that
    /// only mentions them ("Fall Festival announcement video").
    public static func slot(forItemNamed name: String) -> Slot? {
        let compacted = ServicePosition.compacted(name)
        return Slot.linkedByName.first { $0.itemNames.contains(compacted) }
    }

    /// A library presentation that might be a shared one.
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The presentation named for the slot (any case or spacing). Among
    /// several, the shortest name and then the id win, so every Mac looking
    /// at the same library picks the same one.
    public static func sharedID(_ slot: Slot, candidates: [Candidate]) -> String? {
        let wanted = ServicePosition.compacted(slot.presentationName)
        return candidates
            .filter { ServicePosition.compacted($0.name) == wanted }
            .min { ($0.name.count, $0.name, $0.id) < ($1.name.count, $1.name, $1.id) }?.id
    }

    /// The presentation made when the library has none: empty, so the
    /// church adds its own slides once.
    public static func newPresentation(_ slot: Slot, id: String = UUID().uuidString) -> Presentation {
        var deck = Presentation(id: id, name: slot.presentationName, presentationKind: .deck, themeId: "", slides: [])
        deck.category = slot.category
        return deck
    }

    /// The slots a plan (or template) has an unlinked item for, so the
    /// shared presentation is worth making.
    public static func slotsNeedingLink(_ service: Service) -> Set<Slot> {
        Set(service.items.compactMap { item in isUnlinked(item) ? slot(forItemNamed: item.name) : nil })
    }

    /// The plan with its unlinked Announcements and Closing items linked to
    /// the shared presentations in `links`; nil when nothing changes. An
    /// item already linked (by hand, or by a rule) is left alone. Templates
    /// are linked too, so plans made from them start linked.
    public static func linking(_ service: Service, to links: [Slot: String]) -> Service? {
        var plan = service
        for index in plan.items.indices where isUnlinked(plan.items[index]) {
            guard let slot = slot(forItemNamed: plan.items[index].name),
                  let link = links[slot], !link.isEmpty else { continue }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = link
        }
        return plan == service ? nil : plan
    }

    /// Whether a plan should get a Transition and none is there to link:
    /// not a template, no Transition yet, and it wasn't taken out.
    public static func wantsTransition(_ service: Service) -> Bool {
        service.isTemplate != true && service.transitionRemoved != true && StandingItems.transition(in: service) == nil
    }

    private static func isUnlinked(_ item: ServiceItem) -> Bool {
        item.itemKind != .header && item.refId.isEmpty && item.mxuSongTitle == nil
            && item.isPreService != true && item.isCountdown != true
            && item.isTransition != true && item.isWalkout != true
    }
}
