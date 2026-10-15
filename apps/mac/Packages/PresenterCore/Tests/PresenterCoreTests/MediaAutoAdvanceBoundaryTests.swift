import Testing
@testable import PresenterCore

@Test func preFireIncludesTheExactLeadBoundary() {
    #expect(!MediaAutoAdvance.shouldPreFire(remainingWallClock: 2.5.nextUp, delay: -2.5))
    #expect(MediaAutoAdvance.shouldPreFire(remainingWallClock: 2.5, delay: -2.5))
    #expect(MediaAutoAdvance.shouldPreFire(remainingWallClock: 2.5.nextDown, delay: -2.5))
}
