import Foundation
import Observation
import Testing
@testable import PresenterCore

@MainActor
struct KeyedSignalsTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private func watching(_ signals: KeyedSignals<String>, _ key: String) -> Flag {
        let flag = Flag()
        withObservationTracking {
            signals.observe(key)
        } onChange: {
            flag.fired = true
        }
        return flag
    }

    /// Three hundred tiles waiting for their pictures: one landing re-runs
    /// the one tile that asked for it, not all three hundred.
    @Test func aKeyLandingWakesOnlyWhoWaitedForIt() {
        let signals = KeyedSignals<String>()
        let tiles = (0 ..< 300).map { watching(signals, "slide-\($0)") }
        signals.fire("slide-42")
        #expect(tiles.filter(\.fired).count == 1)
        #expect(tiles[42].fired)
    }

    @Test func aLandedKeyIsForgottenAndCanBeWaitedOnAgain() {
        let signals = KeyedSignals<String>()
        _ = watching(signals, "a")
        #expect(signals.count == 1)
        signals.fire("a")
        #expect(signals.count == 0, "nothing kept for keys no one is waiting on")
        let again = watching(signals, "a")
        signals.fire("a")
        #expect(again.fired)
        signals.fire("never-asked")
        #expect(signals.count == 0)
    }
}
