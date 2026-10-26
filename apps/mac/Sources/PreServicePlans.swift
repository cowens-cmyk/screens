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

    /// The shared slideshow, made (empty, looping) when the library has
    /// none. Plans and presentations sync church-wide, so it's only made
    /// by hand or on the Mac with Run on this Mac on; otherwise two Macs
    /// could each make one. Nil while the library is still opening, or
    /// when one is on the team drive but not on this Mac yet.
    @discardableResult
    func makePreServiceSlideshowIfNeeded(byHand: Bool) async -> String? {
        if let id = preServiceSlideshowID() { return id }
        guard isLibraryReady, byHand || ServiceStation.runsService else { return nil }
        let onDrive = teamCloudItems.contains {
            $0.kind == .presentation && (ServiceDay.looksLikePreService($0.name) || ServiceDay.looksLikePreService($0.folder))
        }
        guard !onDrive, !PreServiceMaking.inFlight else { return nil }
        PreServiceMaking.inFlight = true
        defer { PreServiceMaking.inFlight = false }
        let deck = PreServiceSlides.newSlideshow()
        _ = try? await createInDrive(deck).value
        return libraryEntry(deck.id) != nil ? deck.id : preServiceSlideshowID()
    }

    /// Gives every upcoming plan and template the shared slideshow first,
    /// and every upcoming plan its countdown after it, writing only the
    /// plans that change.
    func ensurePlanOpeners(
        upcoming: [Service], templates: [Service], isCountdownLink: (ServiceItem) -> Bool
    ) {
        let shared = preServiceSlideshowID()
        for plan in upcoming + templates {
            let preService = PreServiceSlides.change(for: plan, sharedID: shared)
            let countdown = ServiceCountdown.change(for: plan, isCountdownLink: isCountdownLink)
            guard preService != nil || countdown != nil else { continue }
            updateService(plan.id) { service in
                if let preService { PreServiceSlides.apply(preService, to: &service) }
                if let countdown { ServiceCountdown.apply(countdown, to: &service) }
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
