import Foundation

/// Each Sunday gets a message presentation of its own ("Genesis 40-41"),
/// so the library would fill up with last year's messages. They're kept
/// together in a **Messages** folder of their own, and one whose last
/// service was 30 days ago or more is taken out of the library.
///
/// Only a plan's message is ever touched: a presentation some plan names as
/// its message (`messagePresentationId`) whose type is Sermon. Songs are
/// Worship and never named as a message, so they can't be caught. A message
/// a template uses, one any plan within the 30 days or upcoming uses, and
/// the Service Day's own presentations (pre-service, Transition, Walkout)
/// are kept, whatever they're called.
public enum MessageCleanup {
    /// The library folder messages are kept in.
    public static let folder = "Messages"
    /// A message whose newest service is this many days back or more goes.
    public static let keepDays = 30

    public struct Sweep: Equatable, Sendable {
        /// Messages to move into the Messages folder.
        public var toFile: [String] = []
        /// Messages to take out of the library.
        public var toRemove: [String] = []

        public init(toFile: [String] = [], toRemove: [String] = []) {
            self.toFile = toFile
            self.toRemove = toRemove
        }
    }

    /// Every presentation some plan (not a template) names as its message.
    /// The caller looks these up to say which are Sermon presentations.
    public static func messageIDs(in plans: [Service]) -> Set<String> {
        Set(plans.compactMap { plan in
            guard plan.isTemplate != true, let id = plan.messagePresentationId, !id.isEmpty else { return nil }
            return id
        })
    }

    /// The last day (yyyy-MM-dd) a message can have been used and still be
    /// taken out on `today`: `keepDays` before it.
    public static func cutoff(today: Date, keepDays: Int = keepDays, calendar: Calendar = .current) -> String {
        let day = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: today)) ?? today
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What to file and what to take out.
    ///
    /// - Parameters:
    ///   - plans: every plan and template in the library.
    ///   - isSermon: whether a presentation is of the Sermon type; one that
    ///     can't be read counts as not, so it's left alone.
    ///   - folderOf: the presentation's library folder, nil for none.
    ///   - protected: presentations kept whatever (the Service Day's).
    ///   - cutoff: from `cutoff(today:)`; a message last used on or before
    ///     it goes.
    public static func sweep(
        plans: [Service], isSermon: (String) -> Bool, folderOf: (String) -> String?,
        protected: Set<String>, cutoff: String
    ) -> Sweep {
        let messages = messageIDs(in: plans)
        var lastUsed: [String: String] = [:]
        var pinned = protected
        for plan in plans {
            var ids = Set(plan.items.compactMap { item -> String? in
                item.itemKind == .presentation && !item.refId.isEmpty ? item.refId : nil
            })
            if let id = plan.messagePresentationId, !id.isEmpty { ids.insert(id) }
            let date = String(plan.serviceDate.prefix(10))
            // A template's message, or a plan with no date, is never old.
            guard plan.isTemplate != true, date.count == 10 else {
                pinned.formUnion(ids)
                continue
            }
            for id in ids where lastUsed[id].map({ date > $0 }) ?? true {
                lastUsed[id] = date
            }
        }

        var sweep = Sweep()
        for id in messages.sorted() where !pinned.contains(id) && isSermon(id) {
            guard let last = lastUsed[id] else { continue }
            if last <= cutoff {
                sweep.toRemove.append(id)
            } else if !isInFolder(folderOf(id)) {
                sweep.toFile.append(id)
            }
        }
        return sweep
    }

    /// In Messages, or a folder inside it.
    public static func isInFolder(_ path: String?) -> Bool {
        guard let path else { return false }
        return path == folder || path.hasPrefix(folder + "/")
    }
}
