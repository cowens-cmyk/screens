import Foundation

public struct PresentFocusScroll: Equatable, Sendable {

    public private(set) var honoredItemID: String?

    public init() {}

    public mutating func request(_ itemID: String?) -> String? {
        if let itemID, itemID != honoredItemID {
            honoredItemID = itemID
            return itemID
        } else {
            return nil
        }
    }

    /// The page got to this item by itself (the operator scrolled there, or
    /// it followed the live slide): the selection moves to it without a jump.
    public mutating func follow(_ itemID: String) {
        honoredItemID = itemID
    }

    public mutating func reset() {
        honoredItemID = nil
    }

    public private(set) var reselects = 0

    public mutating func reselect() {
        honoredItemID = nil
        reselects += 1
    }
}
