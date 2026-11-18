import Foundation

/// Where an item sits in the service, for the lights: Prism has a scene
/// per position (Walk-in, Song 1, Message…) and Screens sends that scene's
/// cue when the item goes live, so nobody drags a macro onto every song.
public enum ServicePosition: Hashable, Sendable {
    case walkIn, countdown, song(Int), announcements, message, closing, walkout, baptism, communion
    /// A position the church added to the cue table itself ("Prayer",
    /// "Offering"); a header with that name points its items at it.
    case custom(String)

    /// What `ServiceItem.lightingCue` stores to turn an item's cue off.
    public static let noneKey = "none"

    /// The stored form, in `ServiceItem.lightingCue` and `LightingCue.position`.
    public var key: String {
        switch self {
        case .walkIn: "walkIn"
        case .countdown: "countdown"
        case .song(let number): "song\(number)"
        case .announcements: "announcements"
        case .message: "message"
        case .closing: "closing"
        case .walkout: "walkout"
        case .baptism: "baptism"
        case .communion: "communion"
        case .custom(let name): "custom:\(name)"
        }
    }

    public init?(key: String) {
        switch key {
        case "walkIn": self = .walkIn
        case "countdown": self = .countdown
        case "announcements": self = .announcements
        case "message": self = .message
        case "closing": self = .closing
        case "walkout": self = .walkout
        case "baptism": self = .baptism
        case "communion": self = .communion
        default:
            if key.hasPrefix("custom:") {
                let name = String(key.dropFirst("custom:".count))
                guard !name.isEmpty else { return nil }
                self = .custom(name)
            } else if key.hasPrefix("song"), let number = Int(key.dropFirst("song".count)), number > 0 {
                self = .song(number)
            } else {
                return nil
            }
        }
    }

    public var title: String {
        switch self {
        case .walkIn: "Walk-in"
        case .countdown: "Countdown"
        case .song(let number): "Song \(number)"
        case .announcements: "Announcements"
        case .message: "Message"
        case .closing: "Closing"
        case .walkout: "Walkout"
        case .baptism: "Baptism"
        case .communion: "Communion"
        case .custom(let name): name
        }
    }

    /// The cue table's rows in service order, before any custom ones.
    public static func standard(songs: Int) -> [ServicePosition] {
        [.walkIn, .countdown] + (1...max(1, songs)).map(ServicePosition.song)
            + [.announcements, .message, .closing, .walkout, .baptism, .communion]
    }

    // MARK: Names

    /// What a header (or an item's own name) says about its position, if
    /// anything. "Worship" says nothing: songs number themselves.
    /// "Response" says nothing either — it usually holds the song after
    /// the message, which is a song scene, not the closing one.
    public static func named(_ name: String, customNames: [String] = []) -> ServicePosition? {
        let compact = compacted(name)
        guard !compact.isEmpty else { return nil }
        if let custom = customNames.first(where: { compacted($0) == compact }) {
            return .custom(custom)
        }
        let rules: [(ServicePosition, [String])] = [
            (.communion, ["communion", "lordssupper"]),
            (.baptism, ["baptism"]),
            (.walkout, ["walkout", "postservice"]),
            (.walkIn, ["walkin", "preservice"]),
            (.countdown, ["countdown"]),
            (.announcements, ["announcement"]),
            (.message, ["message", "sermon"]),
            (.closing, ["closing", "benediction"]),
        ]
        if let position = rules.first(where: { $0.1.contains { compact.contains($0) } })?.0 { return position }
        // "Close", the item after the closing song. Matched whole: "close"
        // is inside too many other words to look for it in the middle.
        return compact == "close" ? .closing : nil
    }

    /// Letters and digits only, lowercased: "Walk-In", "Walk in" and
    /// "WALKIN" all read the same.
    static func compacted(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    // MARK: Inference

    /// What the plan knows about an item's presentation, which isn't on the
    /// item itself.
    public struct ItemFacts: Sendable {
        /// The presentation's type (Worship, Sermon, Announcements…).
        public var category: String?
        /// The pre-service slideshow: Service Day's, or a looping deck
        /// named for walk-in.
        public var isPreService: Bool

        public init(category: String? = nil, isPreService: Bool = false) {
            self.category = category
            self.isPreService = isPreService
        }
    }

    /// Each plan item's position, by item id; an item with none is absent.
    ///
    /// In order: the item's own choice (`lightingCue`, "none" included);
    /// the countdown, the pre-service slideshow and the walkout; a song
    /// under a header named for the close (the next song scene); the
    /// nearest header above that names a position; the item's type (message, announcements,
    /// songs); and its own name. Songs count 1, 2, 3… down the plan, so a
    /// template's order gives Song 1…5 by itself. Hidden items are skipped
    /// and don't take a number.
    public static func positions(
        in items: [ServiceItem], messagePresentationId: String? = nil,
        customNames: [String] = [], facts: (ServiceItem) -> ItemFacts = { _ in ItemFacts() }
    ) -> [String: ServicePosition] {
        var result: [String: ServicePosition] = [:]
        var headerPosition: ServicePosition?
        // A header that is only named for the close ("CLOSING SONG"), not
        // pointed at the Closing scene by hand.
        var headerNamesClosing = false
        var songs = 0
        for item in items where !item.isHidden {
            if item.itemKind == .header {
                let chosen = override(item.lightingCue)
                headerPosition = chosen ?? named(item.name, customNames: customNames)
                headerNamesClosing = chosen == nil && headerPosition == .closing
                if let headerPosition { result[item.id] = headerPosition }
                continue
            }
            if let chosen = override(item.lightingCue) {
                if let chosen { result[item.id] = chosen }
                continue
            }
            let itemFacts = facts(item)
            if item.isCountdown == true {
                result[item.id] = .countdown
            } else if itemFacts.isPreService {
                result[item.id] = .walkIn
            } else if item.isWalkout == true {
                // Wherever it sits (it is added last, so usually under the
                // closing header): the Walkout scene, not that header's.
                result[item.id] = .walkout
            } else if headerNamesClosing, isSong(item, category: itemFacts.category) {
                // The closing song is still a song: it takes the next song
                // scene (Song 5 after four), and Closing waits for the item
                // that follows it.
                songs += 1
                result[item.id] = .song(songs)
            } else if let headerPosition {
                result[item.id] = headerPosition
            } else if itemFacts.category == PresentationTypes.sermon
                || (messagePresentationId?.isEmpty == false && item.refId == messagePresentationId) {
                result[item.id] = .message
            } else if itemFacts.category == PresentationTypes.announcements {
                result[item.id] = .announcements
            } else if isSong(item, category: itemFacts.category) {
                songs += 1
                result[item.id] = .song(songs)
            } else if let named = named(item.name, customNames: customNames) {
                result[item.id] = named
            }
        }
        return result
    }

    /// nil: no choice made. .some(nil): the item chose no cue at all.
    static func override(_ stored: String?) -> ServicePosition?? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored == noneKey { return .some(nil) }
        return ServicePosition(key: stored).map { .some($0) }
    }

    static func isSong(_ item: ServiceItem, category: String?) -> Bool {
        category == PresentationTypes.worship || item.mxuSongTitle != nil || item.mxuKind == "song"
    }

    /// The looping walk-in slideshow, even when it isn't Service Day's.
    public static func isPreServiceSlideshow(
        id: String, name: String, loops: Bool, preServicePresentationId: String?
    ) -> Bool {
        if let preServicePresentationId, !preServicePresentationId.isEmpty, id == preServicePresentationId {
            return true
        }
        let compact = compacted(name)
        return loops && (compact.contains("preservice") || compact.contains("walkin"))
    }
}

/// The church's cue table: a MIDI note per position.
public enum LightingCueTable {
    /// Middle C up, where Prism's own cues start.
    public static let firstNote = 60

    /// Walk-in 60, Countdown 61, Song 1–5 62–66, Announcements 67, Message
    /// 68, Closing 69, Walkout 70, Baptism 71, Communion 72. Added songs and
    /// cues take 73 up.
    public static let defaults: [LightingCue] = ServicePosition.standard(songs: 5).enumerated().map {
        LightingCue(position: $0.element.key, note: firstNote + $0.offset)
    }

    /// The saved table, or the defaults before anyone has edited it.
    public static func effective(_ stored: [LightingCue]?) -> [LightingCue] {
        guard let stored, !stored.isEmpty else { return defaults }
        return stored
    }

    /// The note a position sends, or nil when its row is off or missing.
    /// A song past the last song row uses the last one (Song 6 plays the
    /// Song 5 scene).
    public static func note(for position: ServicePosition, in table: [LightingCue]) -> Int? {
        if let row = table.first(where: { $0.position == position.key }) {
            return row.off == true ? nil : row.note
        }
        guard case .song(let number) = position else { return nil }
        let last = table
            .compactMap { row -> (Int, LightingCue)? in
                guard case .song(let n)? = ServicePosition(key: row.position), n < number else { return nil }
                return (n, row)
            }
            .max { $0.0 < $1.0 }?.1
        guard let last, last.off != true else { return nil }
        return last.note
    }

    /// The song rows the table has (at least the standard five).
    public static func songCount(in table: [LightingCue]) -> Int {
        let numbers = table.compactMap { row -> Int? in
            if case .song(let n)? = ServicePosition(key: row.position) { n } else { nil }
        }
        return max(numbers.max() ?? 0, 1)
    }

    /// The custom positions' names, in table order.
    public static func customNames(in table: [LightingCue]) -> [String] {
        table.compactMap { row in
            if case .custom(let name)? = ServicePosition(key: row.position) { name } else { nil }
        }
    }

    /// Why `note` can't be the note of `position`'s row, or nil when it
    /// can. 0 is kept out of the table, and a note another row has would
    /// fire both scenes.
    public static func noteProblem(_ note: Int, for position: String, in table: [LightingCue]) -> String? {
        if note < 1 || note > 127 { return "Notes go from 1 to 127." }
        if let other = table.first(where: { $0.position != position && $0.note == note }) {
            return "\(ServicePosition(key: other.position)?.title ?? other.position) already has \(note)."
        }
        return nil
    }

    /// The note an added song or cue gets: the lowest free one above the
    /// defaults, then any free one below them.
    public static func nextFreeNote(in table: [LightingCue]) -> Int {
        let used = Set(table.map(\.note))
        let above = firstNote + defaults.count
        let candidates = Array(above...127) + Array((1..<above).reversed())
        return candidates.first { !used.contains($0) } ?? 127
    }
}

/// Which plan item last went live on the screens, so its lighting cue and
/// macros go once when it goes up, not on every slide of it. Only a slide
/// or video landing reports here; a header click sends its cue around it,
/// so clicking a header never re-runs the live item's macros.
public struct LiveItemTracker: Equatable, Sendable {
    public private(set) var current: String?

    public init() {}

    /// The walk-in slideshow put up outside the plan counts as its own item.
    public static func preServiceKey(_ presentationID: String) -> String {
        "preService|" + presentationID
    }

    /// True when `key` is newly live: the caller sends its cue and macros.
    public mutating func wentLive(_ key: String) -> Bool {
        guard key != current else { return false }
        current = key
        return true
    }
}
