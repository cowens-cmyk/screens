import Foundation
import PresenterCore

/// The one pre-service slideshow every plan opens with (PreServiceSlides
/// decides which it is and how a plan gets it; this finds it in the library
/// and makes it when there's none).
extension AppModel {
    /// The shared pre-service slideshow, nil when the library has none. The
    /// website-events sync, the plans and the Assistant all use this.
    func preServiceSlideshowID() -> String? {
        let candidates = entries(of: .presentation).map {
            PreServiceSlides.Candidate(id: $0.id, name: $0.name, subkind: $0.subkind)
        }
        return PreServiceSlides.sharedID(
            serviceDayID: slideBuilding.serviceDay?.preServicePresentationId,
            inLibrary: { libraryEntry($0) != nil }, candidates: candidates)
    }

    /// Whether a presentation is a pre-service slideshow other than the
    /// shared one: named or foldered like Pre-Service. Two Macs can each
    /// make one before either sees the other's; plans on the other one are
    /// moved to the shared one, which every Mac picks the same way.
    func isOtherPreServiceSlideshow(_ id: String, shared: String?) -> Bool {
        guard id != shared, let entry = libraryEntry(id), entry.kind == .presentation else { return false }
        return ServiceDay.looksLikePreService(entry.name) || ServiceDay.looksLikePreService(entry.subkind)
    }

    /// The shared slideshow, made (empty, looping) when the library has
    /// none, on any Mac: one that doesn't run the service still shows plans
    /// that should open with it. Nil while the library is still opening,
    /// or when one is on the team drive but not on this Mac yet.
    @discardableResult
    func makePreServiceSlideshowIfNeeded() async -> String? {
        if let id = preServiceSlideshowID() { return id }
        guard isLibraryReady else { return nil }
        let onDrive = teamCloudItems.contains {
            $0.kind == .presentation && (ServiceDay.looksLikePreService($0.name) || ServiceDay.looksLikePreService($0.folder))
        }
        guard !onDrive, !PreServiceMaking.inFlight else { return nil }
        PreServiceMaking.inFlight = true
        defer { PreServiceMaking.inFlight = false }
        let deck = PreServiceSlides.newSlideshow()
        _ = try? await createInDrive(deck).value
        guard libraryEntry(deck.id) != nil else { return preServiceSlideshowID() }
        // The hopejc.org events go straight in rather than at the next read.
        if WebsiteEventSync.shared.writesHere { WebsiteEventSync.shared.syncNow() }
        return deck.id
    }

    /// The shared presentation for a slot (Announcements, Closing,
    /// Transition), nil when the library has none.
    func sharedPresentationID(_ slot: SharedPlanItems.Slot) -> String? {
        SharedPlanItems.sharedID(slot, candidates: entries(of: .presentation).map {
            SharedPlanItems.Candidate(id: $0.id, name: $0.name)
        })
    }

    /// The slots these plans need a shared presentation for that the
    /// library doesn't have yet: an unlinked Announcements or Closing item,
    /// or a plan with no Transition while the Service Day setup has none
    /// chosen.
    func sharedSlotsToMake(for plans: [Service]) -> [SharedPlanItems.Slot] {
        var wanted = Set(plans.flatMap(SharedPlanItems.slotsNeedingLink))
        if chosenTransitionID() == nil, plans.contains(where: SharedPlanItems.wantsTransition) {
            wanted.insert(.transition)
        }
        return SharedPlanItems.Slot.allCases.filter { wanted.contains($0) && sharedPresentationID($0) == nil }
    }

    /// Makes the shared presentations these plans need (empty), each once.
    /// Nothing is made while the library is still opening, or when one is
    /// on the team drive but not on this Mac yet, so two Macs don't each
    /// make one. Returns whether any was made.
    @discardableResult
    func makeSharedPresentationsIfNeeded(for plans: [Service]) async -> Bool {
        guard isLibraryReady else { return false }
        var made = false
        for slot in sharedSlotsToMake(for: plans) {
            let onDrive = teamCloudItems.contains {
                $0.kind == .presentation && SharedPlanItems.sharedID(slot, candidates: [.init(id: "", name: $0.name)]) != nil
            }
            guard !onDrive, !SharedItemsMaking.inFlight.contains(slot) else { continue }
            SharedItemsMaking.inFlight.insert(slot)
            defer { SharedItemsMaking.inFlight.remove(slot) }
            let deck = SharedPlanItems.newPresentation(slot)
            _ = try? await createInDrive(deck).value
            if libraryEntry(deck.id) != nil { made = true }
        }
        return made
    }

    /// Gives every upcoming plan and template the shared slideshow first,
    /// and every upcoming plan its countdown after it, writing only the
    /// plans that change. Announcements and Closing items with nothing
    /// linked are linked to their shared presentations.
    func ensurePlanOpeners(
        upcoming: [Service], templates: [Service], isCountdownLink: (ServiceItem) -> Bool
    ) {
        let shared = preServiceSlideshowID()
        // A let, so updateService's closure can capture it.
        let links: [SharedPlanItems.Slot: String] = Dictionary(uniqueKeysWithValues:
            SharedPlanItems.Slot.linkedByName.compactMap { slot in sharedPresentationID(slot).map { (slot, $0) } })
        for plan in upcoming + templates {
            let preService = PreServiceSlides.change(
                for: plan, sharedID: shared, isOtherSlideshow: { isOtherPreServiceSlideshow($0, shared: shared) })
            let countdown = ServiceCountdown.change(for: plan, isCountdownLink: isCountdownLink)
            let standing = standingLinks(for: plan)
            let needsStanding = standing.flatMap {
                StandingItems.ensuring(plan, transitionID: $0.transition, walkoutID: $0.walkout, messageItemID: $0.message)
            } != nil
            let needsShared = SharedPlanItems.linking(plan, to: links) != nil
            guard preService != nil || countdown != nil || needsStanding || needsShared else { continue }
            updateService(plan.id) { service in
                if let preService { PreServiceSlides.apply(preService, to: &service) }
                if let countdown { ServiceCountdown.apply(countdown, to: &service) }
                if needsShared, let linked = SharedPlanItems.linking(service, to: links) {
                    service = linked
                }
                // Worked out again on the plan as it stands now.
                if needsStanding, let standing, let updated = StandingItems.ensuring(
                    service, transitionID: standing.transition, walkoutID: standing.walkout,
                    messageItemID: standing.message) {
                    service = updated
                }
            }
        }
    }

    /// The Transition chosen in the Service Day setup, while it's in the
    /// library.
    func chosenTransitionID() -> String? {
        slideBuilding.serviceDay?.transitionPresentationId.flatMap { libraryEntry($0) != nil ? $0 : nil }
    }

    /// The Transition and Walkout presentations (each nil when there's none)
    /// and the plan's message item, for StandingItems; nil when neither.
    /// The Transition is the Service Day's choice, else the shared
    /// presentation named Transition, so every plan gets one before its
    /// message without anything to set up.
    func standingLinks(for plan: Service) -> (transition: String?, walkout: String?, message: String?)? {
        let day = slideBuilding.serviceDay
        let inLibrary = { (id: String?) -> String? in id.flatMap { self.libraryEntry($0) != nil ? $0 : nil } }
        let transition = chosenTransitionID() ?? sharedPresentationID(.transition)
        // The Walkout is the Service Day's choice, else the shared Closing
        // presentation: the same slide the service closes on, this time with
        // the Walkout lights and over the whole livestream.
        let walkout = inLibrary(day?.walkoutPresentationId) ?? sharedPresentationID(.closing)
        guard transition != nil || walkout != nil else { return nil }
        let message = StandingItems.messageItemID(in: plan, positions: ServiceLighting.positions(in: plan, model: self))
        return (transition, walkout, message)
    }

    /// The Service Day setup chose a different Transition or Walkout: every
    /// upcoming plan's item follows it.
    func relinkStandingItems() {
        let day = slideBuilding.serviceDay
        let today = Self.isoDate(.now)
        for plan in resident.services.values where plan.isTemplate != true && String(plan.serviceDate.prefix(10)) >= today {
            guard StandingItems.relinking(plan, transitionID: day?.transitionPresentationId,
                                          walkoutID: day?.walkoutPresentationId) != nil else { continue }
            updateService(plan.id) { service in
                if let relinked = StandingItems.relinking(
                    service, transitionID: day?.transitionPresentationId, walkoutID: day?.walkoutPresentationId) {
                    service = relinked
                }
            }
        }
    }

    /// The Service Day setup chose a different slideshow: the pre-service
    /// item in every upcoming plan and template follows it. Past plans are
    /// left as they were.
    func relinkPreServiceItems(to presentationID: String) {
        let today = Self.isoDate(.now)
        for plan in resident.services.values where plan.isTemplate == true || String(plan.serviceDate.prefix(10)) >= today {
            guard PreServiceSlides.relinking(plan, to: presentationID) != nil else { continue }
            updateService(plan.id) { service in
                if let relinked = PreServiceSlides.relinking(service, to: presentationID) { service = relinked }
            }
        }
    }
}

/// Keeps a second slideshow from being made while the first is on its way.
@MainActor
enum PreServiceMaking {
    static var inFlight = false
}

/// The same for the shared Announcements, Closing and Transition.
@MainActor
enum SharedItemsMaking {
    static var inFlight: Set<SharedPlanItems.Slot> = []
}
