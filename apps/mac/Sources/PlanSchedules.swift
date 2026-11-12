import Foundation
import PresenterCore

/// The app's side of PlanSchedule: the library's plans, and what a linked
/// id is, for finding the day's plan and item a schedule plays.
extension AppModel {
    /// Every plan and template by id.
    var plansByID: [String: Service] {
        Dictionary(resident.services.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What a plan item linked to this id would be: a presentation or a
    /// video. Nil when the library has no such thing.
    func serviceItemKind(forRef id: String) -> ServiceItemKind? {
        switch libraryEntry(id)?.kind {
        case .presentation: .presentation
        case .media: .media
        default: nil
        }
    }

    /// What a plan-item action plays on a day, or why it can't.
    func resolvePlanItem(
        _ action: SlideAction, on date: Date = Date(), upcomingIfNone: Bool = false
    ) -> PlanSchedule.Resolution {
        PlanSchedule.resolve(
            action, on: ScheduleMath.localDayString(date, calendar: .current), plans: plansByID,
            currentID: currentServiceID, upcomingIfNone: upcomingIfNone,
            kindOf: { [self] in serviceItemKind(forRef: $0) })
    }
}
