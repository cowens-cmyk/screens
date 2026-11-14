import Foundation
import Observation

/// A value per key, each observed on its own: a view that reads one key is
/// re-run when that key's value changes, and not when another key's does.
/// For state that a few of many views care about at a time, such as which
/// slide tile is live: read from one shared property, every tile on the
/// plan page re-ran on every fire; read from here, a fire re-runs the tile
/// that stopped being live and the one that became live.
@MainActor
public final class KeyedValues<Key: Hashable, Value: Equatable> {
    @Observable
    final class Cell {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// What a key holds when nothing is set for it.
    public let absent: Value

    private var cells: [Key: Cell] = [:]
    private var current: [Key: Value] = [:]

    public init(absent: Value) {
        self.absent = absent
    }

    /// The value for `key`, and makes the caller depend on that key alone.
    public func value(_ key: Key) -> Value {
        if let cell = cells[key] {
            return cell.value
        }
        let cell = Cell(current[key] ?? absent)
        cells[key] = cell
        return cell.value
    }

    /// The value for `key` without observing it.
    public func peek(_ key: Key) -> Value {
        current[key] ?? absent
    }

    /// Replaces every value: keys left out go back to `absent`. Only keys
    /// whose value changed are written, so only their readers re-run.
    public func set(_ values: [Key: Value]) {
        let next = values.filter { $0.value != absent }
        guard next != current else { return }
        let touched = Set(current.keys).union(next.keys)
        current = next
        for key in touched {
            let value = next[key] ?? absent
            if let cell = cells[key], cell.value != value {
                cell.value = value
            }
        }
    }

    /// How many keys have been read. Each keeps a small cell for as long as
    /// the app runs (a cell is never swapped out from under a view still
    /// watching it): a few thousand tiles' worth at most.
    public var cellCount: Int { cells.count }
}
