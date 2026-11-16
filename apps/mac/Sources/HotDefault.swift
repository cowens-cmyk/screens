import Foundation
import Observation
import SwiftUI

/// `@AppStorage`, but a view re-runs only when its own key's value changes.
///
/// `@AppStorage` re-runs every view that holds one on any write to
/// UserDefaults, whatever the key (SwiftUI's change report names all of a
/// view's `@AppStorage` properties as changed together). The app writes
/// defaults all the time: the stage mode when the next item goes live, the
/// timers, the scheduler, AppKit's own window and split-view state. Each
/// write re-ran the window's root (nine of them), every slide thumbnail on
/// the page (one each) and most panels, which is the hitch on arrowing into
/// the next song. Same declaration, same UserDefaults keys and values:
///
///     @HotDefault("slideGrid.legibleText") private var legibleText = false
@MainActor @propertyWrapper
struct HotDefault<Value: Equatable> {
    private let cell: DefaultsCell<Value>
    private let fallback: Value

    fileprivate init(
        key: String, fallback: Value,
        read: @escaping (Any) -> Value?, write: @escaping (Value) -> Any
    ) {
        cell = DefaultsCells.cell(key, read: read, write: write)
        self.fallback = fallback
    }

    var wrappedValue: Value {
        get { cell.value ?? fallback }
        nonmutating set { cell.set(newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { [cell, fallback] in cell.value ?? fallback },
            set: { [cell] in cell.set($0) })
    }
}

extension HotDefault where Value == Bool {
    init(wrappedValue: Bool, _ key: String) {
        self.init(key: key, fallback: wrappedValue, read: { $0 as? Bool }, write: { $0 })
    }
}

extension HotDefault where Value == String {
    init(wrappedValue: String, _ key: String) {
        self.init(key: key, fallback: wrappedValue, read: { $0 as? String }, write: { $0 })
    }
}

extension HotDefault where Value == Double {
    init(wrappedValue: Double, _ key: String) {
        self.init(
            key: key, fallback: wrappedValue, read: { ($0 as? NSNumber)?.doubleValue }, write: { $0 })
    }
}

extension HotDefault where Value == Int {
    init(wrappedValue: Int, _ key: String) {
        self.init(key: key, fallback: wrappedValue, read: { ($0 as? NSNumber)?.intValue }, write: { $0 })
    }
}

extension HotDefault where Value: RawRepresentable, Value.RawValue == String {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key, fallback: wrappedValue,
            read: { ($0 as? String).flatMap(Value.init(rawValue:)) }, write: { $0.rawValue })
    }
}

extension HotDefault where Value: RawRepresentable, Value.RawValue == Int {
    init(wrappedValue: Value, _ key: String) {
        self.init(
            key: key, fallback: wrappedValue,
            read: { ($0 as? NSNumber).flatMap { Value(rawValue: $0.intValue) } }, write: { $0.rawValue })
    }
}

/// One UserDefaults key's value, observed by the views that read it. Nil
/// while the key is unset, so each reader keeps its own default.
@MainActor @Observable
final class DefaultsCell<Value: Equatable> {
    private(set) var value: Value?
    @ObservationIgnored private let key: String
    @ObservationIgnored private let read: (Any) -> Value?
    @ObservationIgnored private let write: (Value) -> Any

    init(key: String, read: @escaping (Any) -> Value?, write: @escaping (Value) -> Any) {
        self.key = key
        self.read = read
        self.write = write
        value = UserDefaults.standard.object(forKey: key).flatMap(read)
    }

    func set(_ new: Value) {
        if value != new { value = new }
        UserDefaults.standard.set(write(new), forKey: key)
    }

    /// UserDefaults changed somewhere: notify only if this key did.
    func refresh() {
        let now = UserDefaults.standard.object(forKey: key).flatMap(read)
        if now != value { value = now }
    }
}

@MainActor
enum DefaultsCells {
    private static var cells: [String: AnyObject] = [:]
    private static var refreshers: [() -> Void] = []
    private static var observer: NSObjectProtocol?

    static func cell<Value: Equatable>(
        _ key: String, read: @escaping (Any) -> Value?, write: @escaping (Value) -> Any
    ) -> DefaultsCell<Value> {
        let id = key + "|" + String(reflecting: Value.self)
        if let cell = cells[id] as? DefaultsCell<Value> { return cell }
        let cell = DefaultsCell(key: key, read: read, write: write)
        cells[id] = cell
        refreshers.append { cell.refresh() }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: nil
            ) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { DefaultsCells.refreshAll() }
                } else {
                    Task { @MainActor in DefaultsCells.refreshAll() }
                }
            }
        }
        return cell
    }

    private static func refreshAll() {
        for refresh in refreshers { refresh() }
    }
}
