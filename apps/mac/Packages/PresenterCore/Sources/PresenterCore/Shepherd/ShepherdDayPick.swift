import Foundation

/// One plan per day from Shepherd. Shepherd can hold more than one plan for a
/// Sunday: at Hope, a "Sunday Worship" plan made from a template sits beside
/// the "Sunday Morning Worship" plan the team actually builds, with the same
/// headers and placeholder songs but nobody scheduled and no real songs.
/// Screens keeps the one that is the church's service and leaves the rest.
///
/// The church's service type is the one whose plans have real songs (a song
/// from the library, not a placeholder titled "Song") on the most days. On a
/// day with more than one plan, the plan of that type wins; failing that, the
/// one with the most songs, then the earliest.
public enum ShepherdDayPick {
    public struct Pick: Equatable, Sendable {
        public var kept: [ShepherdClient.PlanSummary]
        public var dropped: [ShepherdClient.PlanSummary]
        /// The church's service type, when it could be told (some day had
        /// more than one plan, and some plan had songs).
        public var mainServiceTypeName: String?
    }

    /// `songs` is how many real songs each plan has, by plan id. Plans not in
    /// it count as none.
    public static func pick(_ plans: [ShepherdClient.PlanSummary], songs: [String: Int]) -> Pick {
        let main = mainServiceTypeID(plans, songs: songs)
        var kept: [ShepherdClient.PlanSummary] = []
        var dropped: [ShepherdClient.PlanSummary] = []
        let days = Dictionary(grouping: plans, by: ShepherdPlanSync.serviceDate(for:))
        for plan in plans {
            let day = ShepherdPlanSync.serviceDate(for: plan)
            let rivals = day.isEmpty ? [plan] : days[day] ?? [plan]
            if best(of: rivals, main: main, songs: songs).id == plan.id { kept.append(plan) } else { dropped.append(plan) }
        }
        let mainName = main.flatMap { id in plans.first { $0.serviceType.id == id }?.serviceType.name }
        return Pick(kept: kept, dropped: dropped, mainServiceTypeName: mainName)
    }

    static func mainServiceTypeID(_ plans: [ShepherdClient.PlanSummary], songs: [String: Int]) -> String? {
        var withSongs: [String: Set<String>] = [:]
        var count: [String: Int] = [:]
        for plan in plans {
            count[plan.serviceType.id, default: 0] += 1
            if (songs[plan.id] ?? 0) > 0 { withSongs[plan.serviceType.id, default: []].insert(ShepherdPlanSync.serviceDate(for: plan)) }
        }
        guard !withSongs.isEmpty else { return nil }
        return withSongs.keys.sorted().max { a, b in
            (withSongs[a]!.count, count[a] ?? 0) < (withSongs[b]!.count, count[b] ?? 0)
        }
    }

    private static func best(
        of plans: [ShepherdClient.PlanSummary], main: String?, songs: [String: Int]
    ) -> ShepherdClient.PlanSummary {
        plans.min { a, b in
            let mainA = a.serviceType.id == main, mainB = b.serviceType.id == main
            if mainA != mainB { return mainA }
            let songsA = songs[a.id] ?? 0, songsB = songs[b.id] ?? 0
            if songsA != songsB { return songsA > songsB }
            let startA = a.startsAt ?? .distantFuture, startB = b.startsAt ?? .distantFuture
            if startA != startB { return startA < startB }
            return a.id < b.id
        }!
    }

    /// Real songs in a plan: items with a song attached.
    public static func songCount(_ plan: ShepherdClient.PlanDetail) -> Int {
        plan.items.filter { $0.song != nil }.count
    }

    /// Plans already in the library that `pick` says shouldn't be, by service
    /// id: those made from a dropped Shepherd plan; within `window` (the days
    /// sync read from Shepherd), any made from a plan Shepherd no longer has
    /// or no longer lists; second copies of one Shepherd plan (two Macs that
    /// imported it at the same moment); and, for days `pick` didn't look at
    /// (past Sundays), a plan of another service type beside one of the
    /// church's. A plan whose sync is paused, a template, or one listed in
    /// `keep` (open or live on this Mac) is never taken. With nothing kept
    /// (Shepherd answered with no plans) nothing in the window is taken.
    public static func duplicates(
        in services: [Service], pick: Pick, keep: Set<String>, window: ClosedRange<String>? = nil
    ) -> [String] {
        let shepherd = services.filter {
            $0.origin == ShepherdPlanSync.origin && $0.mxuSyncPaused != true && $0.isTemplate != true
        }
        let dropped = Set(pick.dropped.map(\.id))
        let looked = Set((pick.kept + pick.dropped).map(ShepherdPlanSync.serviceDate(for:)))
        var out: [String] = []

        for service in shepherd where dropped.contains(service.mxuPlanHexId ?? "") { out.append(service.id) }
        let kept = Set(pick.kept.map(\.id))
        if let window, !kept.isEmpty {
            for service in shepherd where window.contains(service.serviceDate) && !kept.contains(service.mxuPlanHexId ?? "") {
                out.append(service.id)
            }
        }

        // Two copies of one plan: the one named for the plan stays (every Mac
        // names it the same), else the first by id.
        for (planID, copies) in Dictionary(grouping: shepherd.filter { $0.mxuPlanHexId != nil }, by: { $0.mxuPlanHexId! })
        where copies.count > 1 {
            let stay = copies.first { $0.id == serviceID(forPlan: planID) } ?? copies.min { $0.id < $1.id }!
            out += copies.filter { $0.id != stay.id }.map(\.id)
        }

        if let main = pick.mainServiceTypeName {
            for (day, same) in Dictionary(grouping: shepherd, by: \.serviceDate) where !day.isEmpty && !looked.contains(day) && same.count > 1 {
                guard same.contains(where: { $0.mxuServiceTypeName == main }) else { continue }
                out += same.filter { $0.mxuServiceTypeName != main }.map(\.id)
            }
        }
        var seen = Set<String>()
        return out.filter { !keep.contains($0) && seen.insert($0).inserted }
    }

    /// The service id a Shepherd plan is imported as. Every Mac uses the same
    /// one, so two Macs importing the same plan at once make one document.
    public static func serviceID(forPlan planID: String) -> String {
        "shepherd-" + planID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
