import Foundation

/// The plan list keeps the last four weeks of past plans. Older ones are
/// taken out of the library by the Mac that runs the service, each saved to
/// the Mac's Trash first, so one needed again can still be found.
///
/// A template, an undated plan, a plan within the four weeks, an upcoming
/// one and any plan listed in `keep` (open or on screen) are never taken.
public enum PlanCleanup {
    /// A plan whose service date is more than this many days back goes.
    public static let keepDays = 28

    /// The first service date (yyyy-MM-dd) still kept on `today`.
    public static func cutoff(today: Date, calendar: Calendar = .current) -> String {
        MessageCleanup.cutoff(today: today, keepDays: keepDays, calendar: calendar)
    }

    /// The plans to take out: dated before `cutoff`.
    public static func oldPlans(_ plans: [Service], cutoff: String, keep: Set<String> = []) -> [Service] {
        plans.filter { plan in
            let day = String(plan.serviceDate.prefix(10))
            return plan.isTemplate != true && day.count == 10 && day < cutoff && !keep.contains(plan.id)
        }
        .sorted { ($0.serviceDate, $0.id) < ($1.serviceDate, $1.id) }
    }

    /// The messages that go with them: a Sermon presentation a removed plan
    /// names as its message that no plan or template left behind names, and
    /// that isn't `protected` (the Service Day's own presentations). Without
    /// this, a message would outlive the only plan that could have it
    /// cleaned up.
    public static func messages(
        of removed: [Service], remaining: [Service], isSermon: (String) -> Bool, protected: Set<String> = []
    ) -> [String] {
        let stillNamed = Set(remaining.compactMap(\.messagePresentationId))
        var seen = Set<String>()
        return removed.compactMap(\.messagePresentationId).filter { id in
            !id.isEmpty && !stillNamed.contains(id) && !protected.contains(id) && isSermon(id) && seen.insert(id).inserted
        }
    }

    /// The file a removed plan is saved as in the Trash: "Screens plan —
    /// November 15, 2026 — Genesis 40-41.json", without characters a file
    /// name can't have.
    public static func trashFileName(for plan: Service) -> String {
        let name = plan.name.isEmpty ? plan.serviceDate : plan.name
        let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
        return "Screens plan — " + String(safe).trimmingCharacters(in: .whitespaces) + ".json"
    }
}
