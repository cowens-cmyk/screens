import Foundation
import Observation

/// One observable signal per key, so a view that waits for something about
/// one key (a thumbnail being drawn) is re-run when that key changes and not
/// when any of the others does. A single counter for everything made every
/// tile on the plan page re-run each time any one tile's picture landed.
@MainActor
public final class KeyedSignals<Key: Hashable> {
    @Observable
    final class Signal {
        var version = 0
    }

    private var signals: [Key: Signal] = [:]

    public init() {}

    /// How many keys are being waited on.
    public var count: Int { signals.count }

    /// The keys being waited on.
    public var keys: [Key] { Array(signals.keys) }

    /// Re-runs everything waiting, for a change that touches every key.
    public func fireAll() {
        for key in keys { fire(key) }
    }

    /// Makes the calling view (or observation) depend on `key`.
    public func observe(_ key: Key) {
        if let signal = signals[key] {
            _ = signal.version
        } else {
            let signal = Signal()
            signals[key] = signal
            _ = signal.version
        }
    }

    /// Re-runs what observed `key`, then forgets it: a key is waited on
    /// until its answer lands, and whoever asks again afterwards gets the
    /// answer rather than waiting.
    public func fire(_ key: Key) {
        if let signal = signals.removeValue(forKey: key) {
            signal.version &+= 1
        }
    }
}
