import Foundation

/// Which of a song's orders set_song_sequence writes. For the song's default
/// it updates the order with that name, or makes one. For one plan item it
/// must not change what other plan items play: an order with the name is
/// written only when it is already this item's own (not the song's default,
/// which every item left on the default plays); otherwise a new order is
/// made, named "Sequence 2" and so on when the name is taken.
public enum SongSequenceOrder {
    public struct Choice: Equatable, Sendable {
        public var id: String
        public var name: String
        public var isNew: Bool
    }

    /// `itemPlays`: the order the plan item plays now (nil for the song's
    /// default). Pass `forItem` false when the order becomes the default.
    public static func choose(
        name: String, in song: Presentation, forItem: Bool, itemPlays: String?,
        newID: () -> String = { UUID().uuidString }
    ) -> Choice {
        let orders = song.arrangements ?? []
        let named = orders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let named {
            if !forItem { return Choice(id: named.id, name: named.name, isNew: false) }
            if named.id != song.defaultArrangementId, named.id == itemPlays {
                return Choice(id: named.id, name: named.name, isNew: false)
            }
        }
        guard named != nil else { return Choice(id: newID(), name: name, isNew: true) }
        let taken = Set(orders.map { $0.name.lowercased() })
        var number = 2
        while taken.contains("\(name) \(number)".lowercased()) { number += 1 }
        return Choice(id: newID(), name: "\(name) \(number)", isNew: true)
    }
}
