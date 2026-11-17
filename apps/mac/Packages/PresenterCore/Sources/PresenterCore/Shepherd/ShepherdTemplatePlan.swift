import Foundation

/// A Shepherd plan built on a Screens template: Wednesday Night (Hope
/// Students) at Hope.
///
/// Sunday plans follow Shepherd's order and get the Sunday openers (the
/// shared pre-service slideshow, the countdown video, Transition, Walkout).
/// A students night runs differently, and its Screens template already says
/// how: its headers, decks and colors. So the plan is a copy of the
/// template, and Shepherd gives it the date, name, service times and songs.
/// The template's own songs are placeholders: Shepherd's songs take their
/// place, each under the template header named like the Shepherd header it
/// is planned under ("6:55 PM - WORSHIP" goes under "Worship").
public enum ShepherdTemplatePlan {
    /// The Shepherd service type loaded this way unless Settings says
    /// otherwise.
    public static let defaultServiceType = "Wednesday Night"

    /// The template a service type's plans are built on: the chosen one
    /// while it is still a template, else one made from a plan of that type,
    /// else one named for it ("Wednesday Night") or for Hope Students. Among
    /// several, the first by name, so every Mac picks the same one.
    public static func template(for serviceType: String, chosenID: String?, in services: [Service]) -> Service? {
        let templates = services.filter { $0.isTemplate == true }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if let chosenID, !chosenID.isEmpty, let chosen = templates.first(where: { $0.id == chosenID }) { return chosen }
        let type = letters(serviceType)
        guard !type.isEmpty else { return nil }
        return templates.first { $0.mxuServiceTypeName.map(letters) == type }
            ?? templates.first { letters($0.name).contains(type) }
            ?? templates.first { letters($0.name).contains("students") }
    }

    /// A song from the Shepherd plan, with the header it is planned under.
    public struct Song: Equatable, Sendable {
        public var header: String?
        public var item: ServiceItem

        public init(header: String?, item: ServiceItem) {
            self.header = header
            self.item = item
        }
    }

    /// The header each song item of a Shepherd plan comes under, by item id.
    public static func headers(of plan: ShepherdClient.PlanDetail) -> [String: String] {
        var current: String?
        var out: [String: String] = [:]
        for item in plan.items.sorted(by: { $0.position < $1.position }) {
            if item.kind == "header" {
                current = item.title
            } else if let current {
                out[item.id] = current
            }
        }
        return out
    }

    /// `base` with `songs` laid in. `isOldSong` marks the items the songs
    /// replace: the template's placeholder songs in a new plan, the songs
    /// last synced in one already made. Those come out, and the headers they
    /// were under are where songs go when no header is named like theirs.
    ///
    /// Each run of songs under one Shepherd header goes at the end of the
    /// template header named like it, else the next header that held songs,
    /// else after the songs placed before it, else at the end of the plan.
    /// Everything else in `base` stays where it is.
    public static func laying(
        _ songs: [Song], over base: [ServiceItem], isOldSong: (ServiceItem) -> Bool
    ) -> [ServiceItem] {
        var slots: [String?] = []
        var header: String?
        for item in base {
            if item.itemKind == .header { header = item.id }
            if isOldSong(item), !slots.contains(header) { slots.append(header) }
        }
        var result = base.filter { !isOldSong($0) }

        var runs: [(header: String?, items: [ServiceItem])] = []
        for song in songs {
            if let last = runs.last, last.header == song.header {
                runs[runs.count - 1].items.append(song.item)
            } else {
                runs.append((song.header, [song.item]))
            }
        }

        var nextSlot = 0
        var afterPrevious: Int?
        for run in runs {
            let named = run.header.flatMap { wanted in
                result.first { $0.itemKind == .header && sameHeader($0.name, wanted) }?.id
            }
            let at: Int
            if let named {
                at = endOfGroup(named, in: result)
                if let index = slots.firstIndex(of: named), index >= nextSlot { nextSlot = index + 1 }
            } else if nextSlot < slots.count {
                at = endOfGroup(slots[nextSlot], in: result)
                nextSlot += 1
            } else {
                at = afterPrevious ?? result.count
            }
            result.insert(contentsOf: run.items, at: at)
            afterPrevious = at + run.items.count
        }
        return result
    }

    /// Where a header's group ends: before the next header, or the end of
    /// the plan. A nil header is the part before the first header.
    static func endOfGroup(_ headerID: String?, in items: [ServiceItem]) -> Int {
        let start = headerID.flatMap { id in items.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        return items[start...].firstIndex { $0.itemKind == .header } ?? items.count
    }

    /// "6:55 PM - WORSHIP" and "Worship"; "7:40 PM - CLOSING SONG" and
    /// "Closing Song". The time a Shepherd header starts with doesn't count.
    public static func sameHeader(_ a: String, _ b: String) -> Bool {
        let x = letters(withoutTime(a)), y = letters(withoutTime(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        return min(x.count, y.count) >= 4 && (x.contains(y) || y.contains(x))
    }

    private static func withoutTime(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\s*\d{1,2}(:\d{2})?\s*([ap]\.?m\.?)?\s*[-–—:|]*\s*"#, with: "",
            options: [.regularExpression, .caseInsensitive])
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
