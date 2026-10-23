import Foundation
import Testing
@testable import PresenterCore

/// Turning Follow on while the pastor's mic is listening for scripture.
struct LyricFollowMicTests {
    @Test func followNeverTakesTheSermonMicOnItsOwn() {
        #expect(LyricFollower.micStep(open: nil) == .startWorship)
        #expect(LyricFollower.micStep(open: .worship) == .none)
        #expect(LyricFollower.micStep(open: .sermon) == .sermonMicInUse, "scripture listening keeps going")
        #expect(LyricFollower.micStep(open: .sermon, operatorChose: true) == .startWorship)
        #expect(LyricFollower.micStep(open: .worship, operatorChose: true) == .none)
    }
}
