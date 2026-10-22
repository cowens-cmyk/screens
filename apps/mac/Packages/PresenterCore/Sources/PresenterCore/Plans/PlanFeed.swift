import Foundation

/// A plan as the planner sends it: the neutral shape Shepherd plans are mapped
/// into before they become Screens service items.
public enum PlanFeed {
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var itemType: String
        public var description: String?
        public var keyName: String?
        public var length: Int?
        /// The section order the band plays ("Verse 1, Chorus, …").
        public var arrangementSequence: [String]?
        public var song: Song?
        public var arrangement: Arrangement?

        public init(
            id: String, title: String, itemType: String, description: String? = nil,
            keyName: String? = nil, length: Int? = nil, arrangementSequence: [String]? = nil,
            song: Song? = nil, arrangement: Arrangement? = nil
        ) {
            self.id = id
            self.title = title
            self.itemType = itemType
            self.description = description
            self.keyName = keyName
            self.length = length
            self.arrangementSequence = arrangementSequence
            self.song = song
            self.arrangement = arrangement
        }
    }

    public struct Song: Hashable, Sendable {
        public var id: String
        public var title: String
        public var author: String?
        public var copyright: String?
        public var ccliNumber: Int?

        public init(id: String, title: String, author: String? = nil, copyright: String? = nil, ccliNumber: Int? = nil) {
            self.id = id
            self.title = title
            self.author = author
            self.copyright = copyright
            self.ccliNumber = ccliNumber
        }
    }

    public struct Arrangement: Hashable, Sendable {
        public var id: String
        public var name: String
        public var bpm: Double?
        public var meter: String?

        public init(id: String, name: String, bpm: Double? = nil, meter: String? = nil) {
            self.id = id
            self.name = name
            self.bpm = bpm
            self.meter = meter
        }
    }
}

/// Maps a plan onto a Screens service.
///
/// The plan's order is the template: headers stay headers, songs link to a
/// library song, and every other item ("COUNTDOWN", "Announcements", the
/// sermon) links by the item-name rules the operator stamps once — so next
/// week's plan fills itself in. Re-syncing keeps local additions and anything
/// the operator linked by hand.
public enum PlanItemSync {

    /// Builds the synced items. `songRef` returns the library presentation for
    /// a song item; nil leaves the item unlinked.
    public static func items(
        for planItems: [PlanFeed.Item],
        serviceTypeName: String?,
        rules: ServiceLinkRules,
        existing: [ServiceItem],
        songRef: (PlanFeed.Item) -> (refId: String, arrangementId: String?)?
    ) -> [ServiceItem] {
        let previous = Dictionary(
            existing.compactMap { item in item.mxuSourceItemId.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first })

        var synced: [ServiceItem] = []
        for planItem in planItems {
            let old = previous[planItem.id]
            var item = ServiceItem(
                id: old?.id ?? UUID().uuidString,
                itemKind: .info, name: planItem.title, refId: "")
            item.mxuItemHexId = planItem.id
            item.mxuSourceItemId = planItem.id
            item.mxuKind = planItem.itemType
            item.mxuDescription = planItem.description
            item.duration = planItem.length
            item.colorHex = old?.colorHex
            item.outputPresetId = old?.outputPresetId
            item.hiddenInPresenter = old?.hiddenInPresenter

            switch planItem.itemType {
            case "header":
                item.itemKind = .header
            case "song":
                let song = planItem.song
                item.mxuSongTitle = song?.title ?? planItem.title
                item.mxuCcliNumber = song?.ccliNumber
                item.mxuSongAuthor = song?.author
                item.mxuSourceSongId = song?.id
                item.mxuSourceArrangementId = planItem.arrangement?.id
                item.mxuArrangementName = planItem.arrangement?.name
                item.mxuBpm = planItem.arrangement?.bpm
                item.mxuTimeSignature = planItem.arrangement?.meter
                let key = planItem.keyName
                item.mxuSongKey = key
                // Re-apply the key when the plan's key changes.
                item.mxuSongKeyApplied = old?.mxuSongKey == key ? old?.mxuSongKeyApplied : nil
                if let old, !old.refId.isEmpty, old.mxuSourceSongId == song?.id {
                    item.itemKind = old.itemKind
                    item.refId = old.refId
                    item.arrangementId = old.mxuSourceArrangementId == planItem.arrangement?.id
                        ? old.arrangementId : nil
                } else if let rule = ServiceLinkLogic.matchingRule(
                    name: planItem.title, serviceTypeName: serviceTypeName, in: rules) {
                    item.itemKind = rule.itemKind
                    item.refId = rule.refId
                } else if let linked = songRef(planItem) {
                    item.itemKind = .presentation
                    item.refId = linked.refId
                    item.arrangementId = linked.arrangementId
                }
                if item.arrangementId == nil, let old, old.refId == item.refId {
                    item.arrangementId = old.arrangementId
                }
            default:
                if let rule = ServiceLinkLogic.matchingRule(
                    name: planItem.title, serviceTypeName: serviceTypeName, in: rules) {
                    item.itemKind = rule.itemKind
                    item.refId = rule.refId
                } else if let old, !old.refId.isEmpty {
                    item.itemKind = old.itemKind
                    item.refId = old.refId
                }
            }
            synced.append(item)
        }
        return mergingLocal(existing: existing, synced: synced)
    }

    /// Items the operator added in Screens stay, right after the synced item
    /// they followed.
    static func mergingLocal(existing: [ServiceItem], synced: [ServiceItem]) -> [ServiceItem] {
        var result = synced
        var anchor: String?
        var pending: [(after: String?, item: ServiceItem)] = []
        for item in existing {
            if item.mxuSourceItemId == nil {
                pending.append((anchor, item))
            } else {
                anchor = item.mxuSourceItemId
            }
        }
        for (after, item) in pending.reversed() {
            let index = after.flatMap { id in result.firstIndex { $0.mxuSourceItemId == id } }
                .map { $0 + 1 } ?? 0
            result.insert(item, at: index)
        }
        return result
    }

    /// An arrangement following the plan's section order ("Verse 1, Chorus,
    /// Verse 2, Chorus, Bridge…"), matched to the song's sections by name.
    public static func arrangement(
        named name: String, sequence: [String], sections: [PresentationSection]
    ) -> Arrangement? {
        let byName = Dictionary(
            sections.map { (normalizeSection($0.name), $0.id) }, uniquingKeysWith: { first, _ in first })
        let ids = sequence.compactMap { byName[normalizeSection($0)] }
        guard !ids.isEmpty else { return nil }
        return Arrangement(id: UUID().uuidString, name: name.isEmpty ? "Shepherd" : name, sectionIds: ids)
    }

    static func normalizeSection(_ name: String) -> String {
        var text = name.lowercased().trimmingCharacters(in: .whitespaces)
        let short: [String: String] = [
            "v": "verse", "c": "chorus", "b": "bridge", "pc": "pre-chorus", "pre": "pre-chorus",
            "t": "tag", "i": "intro", "o": "outro", "e": "ending", "int": "interlude", "inst": "instrumental",
        ]
        if let match = text.range(of: #"^([a-z]+)\s*(\d*)$"#, options: .regularExpression) {
            let raw = String(text[match])
            let letters = raw.prefix { $0.isLetter }
            let digits = raw.drop { $0.isLetter }.trimmingCharacters(in: .whitespaces)
            if let full = short[String(letters)] {
                text = digits.isEmpty ? full : "\(full) \(digits)"
            }
        }
        text = text.replacingOccurrences(of: "prechorus", with: "pre-chorus")
            .replacingOccurrences(of: "pre chorus", with: "pre-chorus")
        // "Verse" alone matches "Verse 1".
        if text == "verse" { text = "verse 1" }
        return text
    }
}
