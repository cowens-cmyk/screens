import Foundation
import os

/// Why the plan page re-ran its body, counted for the minute's perf.pulse.
/// The booth's log shows a whole-page pass every 30 seconds with nothing
/// touched; its stacks say what was evaluated but not what asked for it.
/// The page's body reads the library's list version and the plan, so a
/// pass with the list version unchanged came from something else it reads
/// (the plan, the live slide, the window): "list" against "other" says
/// which way to look next.
enum PlanPageCauses {
    private struct State {
        var lastListVersion: Int?
        var list = 0
        var other = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func note(listVersion: Int) {
        state.withLock { state in
            if state.lastListVersion != listVersion {
                state.lastListVersion = listVersion
                state.list += 1
            } else {
                state.other += 1
            }
        }
    }

    /// "plan passes list 3 other 1", and starts the next minute's count.
    static func drainPulse() -> String? {
        state.withLock { state in
            defer {
                state.list = 0
                state.other = 0
            }
            return state.list + state.other == 0 ? nil : "plan passes list \(state.list) other \(state.other)"
        }
    }
}
