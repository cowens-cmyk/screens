import Foundation

/// The choices behind importing an Anthem session file into a plan: which
/// plan its setlist is for, and the plan's items with the songs in
/// Anthem's order. The app reads the file, finds lyrics and gives each song
/// Anthem's section order (Match Anthem); these decide, so they can be
/// tested.
///
/// The song order is kept in the plan's `mxuSyncedOrder` (item keys,
/// `itemKey`), so Shepherd sync, which rebuilds a plan in Shepherd's order,
/// puts the songs back in Anthem's order after it (`applyOrder`). Only the
/// songs move, among the places songs already had: headers, the message and
/// everything else stay where the plan put them.
public enum AnthemSessionImport {

    /// What stays the same for an item across Shepherd syncs: Shepherd's item
    /// ID for a synced item, else the item's own.
    public static func itemKey(_ item: ServiceItem) -> String {
        item.mxuSourceItemId ?? item.id
    }

    /// The plan the setlist is for, in order of certainty: the Shepherd plan
    /// Anthem made it from; a plan on that plan's day (Shepherd's first); an
    /// upcoming plan whose songs follow the setlist (`follows`, Anthem's
    /// usual test); else the next plan, as Build Sunday picks it.
    public static func targetPlan(
        for info: AnthemSessionFile.SetlistInfo, plans: [Service], today: String,
        timeZone: TimeZone = .current, follows: (Service) -> Bool
    ) -> Service? {
        let candidates = plans.filter { $0.isTemplate != true }
        if let planID = info.shepherdPlanID,
           let plan = candidates.first(where: { $0.origin == ShepherdPlanSync.origin && $0.mxuPlanHexId == planID }) {
            return plan
        }
        let upcoming = candidates
            .filter { String($0.serviceDate.prefix(10)) >= today }
            .sorted { ($0.serviceDate, $0.name, $0.id) < ($1.serviceDate, $1.name, $1.id) }
        if let date = info.planDate {
            let day = isoDay(date, timeZone: timeZone)
            let sameDay = candidates
                .filter { String($0.serviceDate.prefix(10)) == day }
                .sorted { ($0.serviceDate, $0.name, $0.id) < ($1.serviceDate, $1.name, $1.id) }
            if let plan = sameDay.first(where: { $0.origin == ShepherdPlanSync.origin }) ?? sameDay.first {
                return plan
            }
        }
        if let plan = upcoming.first(where: follows) { return plan }
        return SundayPrep.nextPlan(plans, today: today)
    }

    public struct Arranged: Equatable, Sendable {
        /// The plan's items afterwards.
        public var items: [ServiceItem]
        /// Anthem's songs the plan didn't have, as songs still needing
        /// lyrics (the way Shepherd sync leaves a planned song).
        public var added: [ServiceItem]
        /// Plan songs now in another place.
        public var moved: Int
        /// Every Anthem song's `itemKey`, in Anthem's order: the plan's
        /// `mxuSyncedOrder`.
        public var songOrder: [String]
    }

    /// The plan's items with its songs in the setlist's order. `pairs` maps
    /// a setlist entry to the plan item that is that song
    /// (AnthemSongMatch's results). Paired songs trade places among the
    /// places they hold; an entry with no song in the plan is added after
    /// the song before it in the setlist (before the first song when it
    /// opens the set, at the end when the plan has none of the songs).
    public static func arrange(
        items: [ServiceItem], setlist: AnthemShow.Setlist, pairs: [String: String],
        newID: () -> String = { UUID().uuidString }
    ) -> Arranged {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let ordered = setlist.entries.compactMap { pairs[$0.entryId] }.filter { byID[$0] != nil && seen.insert($0).inserted }
        let slots = items.indices.filter { seen.contains(items[$0].id) }
        var result = items
        for (slot, id) in zip(slots, ordered) { result[slot] = byID[id]! }
        let moved = zip(items, result).filter { $0.id != $1.id }.count

        var added: [ServiceItem] = []
        var anchor: Int?
        for entry in setlist.entries {
            if let id = pairs[entry.entryId], let index = result.firstIndex(where: { $0.id == id }) {
                anchor = index
                continue
            }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var item = ServiceItem(id: newID(), itemKind: .info, name: title, refId: "")
            item.mxuSongTitle = title
            item.mxuCcliNumber = entry.ccliNumber
            item.mxuSongKey = entry.key
            let index = anchor.map { $0 + 1 } ?? slots.first ?? result.count
            result.insert(item, at: index)
            added.append(item)
            anchor = index
        }
        let anthemIDs = seen.union(added.map(\.id))
        let songOrder = result.filter { anthemIDs.contains($0.id) }.map(itemKey)
        return Arranged(items: result, added: added, moved: moved, songOrder: songOrder)
    }

    /// The items with those named in `order` (by `itemKey`) in that order,
    /// each taking one of the places they hold between them. Anything else,
    /// and a song the order doesn't name, stays where it is.
    public static func applyOrder(_ order: [String]?, to items: [ServiceItem]) -> [ServiceItem] {
        guard let order, !order.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, key) in order.enumerated() where rank[key] == nil { rank[key] = index }
        let slots = items.indices.filter { rank[itemKey(items[$0])] != nil }
        let sorted = slots.map { items[$0] }.enumerated()
            .sorted { (rank[itemKey($0.element)]!, $0.offset) < (rank[itemKey($1.element)]!, $1.offset) }
            .map(\.element)
        var result = items
        for (slot, item) in zip(slots, sorted) { result[slot] = item }
        return result
    }

    static func isoDay(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
