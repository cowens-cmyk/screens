import Foundation
import Testing
@testable import PresenterCore

struct ShortLivedMemoTests {
    /// The plan page asks whether each tile's media is on this Mac on every
    /// pass: hundreds of times a second, each a stat of the media folder and
    /// of the file. Within the memo's lifetime the disk is asked once.
    @Test func asksOncePerKeyWithinItsLifetime() {
        var memo = ShortLivedMemo<String, Bool>(lifetime: 2)
        var asked = 0
        for pass in 0 ..< 300 {
            _ = memo.value(for: "hash-a", generation: 1, now: 100 + Double(pass) / 1000) {
                asked += 1
                return true
            }
        }
        #expect(asked == 1)
        _ = memo.value(for: "hash-b", generation: 1, now: 100.5) { asked += 1; return false }
        #expect(asked == 2, "each key once")
    }

    @Test func asksAgainAfterItsLifetimeOrANewGeneration() {
        var memo = ShortLivedMemo<String, Bool>(lifetime: 2)
        var answer = true
        #expect(memo.value(for: "a", generation: 1, now: 10) { answer })
        answer = false
        #expect(memo.value(for: "a", generation: 1, now: 11) { answer }, "remembered")
        #expect(!memo.value(for: "a", generation: 1, now: 12.5) { answer }, "a file that went is seen within the lifetime")
        answer = true
        #expect(memo.value(for: "a", generation: 2, now: 12.6) { answer }, "a new generation (a download landed) asks at once")
        #expect(!memo.value(for: "a", generation: 2, now: 1) { false }, "a clock that went backwards asks again")
    }
}
