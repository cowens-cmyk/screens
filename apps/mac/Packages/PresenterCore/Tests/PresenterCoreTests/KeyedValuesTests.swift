import Foundation
import Observation
import Testing
@testable import PresenterCore

@MainActor
struct KeyedValuesTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private struct Mark: Equatable {
        var live = false
        var next = false
    }

    private func reading(_ values: KeyedValues<Int, Mark>, _ key: Int) -> Flag {
        let flag = Flag()
        withObservationTracking {
            _ = values.value(key)
        } onChange: {
            flag.fired = true
        }
        return flag
    }

    /// A plan page of 300 tiles; slide 10 live, 11 next. Firing 11 re-runs
    /// three tiles (10 stops being live, 11 becomes live, 12 becomes next),
    /// not 300.
    @Test func aFireWakesOnlyTheTilesWhoseAnswerChanged() {
        let marks = KeyedValues<Int, Mark>(absent: Mark())
        marks.set([10: Mark(live: true), 11: Mark(next: true)])
        let tiles = (0 ..< 300).map { reading(marks, $0) }
        marks.set([11: Mark(live: true), 12: Mark(next: true)])
        #expect(Set(tiles.indices.filter { tiles[$0].fired }) == [10, 11, 12])
        #expect(marks.peek(11) == Mark(live: true))
        #expect(marks.peek(10) == Mark())
    }

    @Test func settingTheSameMarksWakesNoOne() {
        let marks = KeyedValues<Int, Mark>(absent: Mark())
        marks.set([3: Mark(live: true)])
        let tiles = (0 ..< 10).map { reading(marks, $0) }
        marks.set([3: Mark(live: true), 4: Mark()])
        #expect(tiles.allSatisfy { !$0.fired }, "an absent value written out is still no change")
    }

    @Test func aKeyReadBeforeItWasSetSeesItsValue() {
        let marks = KeyedValues<String, Mark>(absent: Mark())
        let early = reading2(marks, "a")
        marks.set(["a": Mark(next: true)])
        #expect(early.fired)
        #expect(marks.value("a") == Mark(next: true))
        #expect(marks.value("never") == Mark())
    }

    private func reading2(_ values: KeyedValues<String, Mark>, _ key: String) -> Flag {
        let flag = Flag()
        withObservationTracking {
            _ = values.value(key)
        } onChange: {
            flag.fired = true
        }
        return flag
    }
}
