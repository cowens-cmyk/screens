import Foundation
import Testing
@testable import PresenterCore

struct ListBumpsTests {
    /// Drives a throttle the way AppModel does: asks, a timer for each
    /// `after`, the timer's trailing bump. Returns the times bumps went out.
    private func run(asks: [TimeInterval], interval: TimeInterval) -> [TimeInterval] {
        var throttle = BumpThrottle(interval: interval)
        var bumps: [TimeInterval] = []
        var timer: TimeInterval?
        for now in asks {
            if let due = timer, due <= now {
                throttle.trailingFired(now: due)
                bumps.append(due)
                timer = nil
            }
            switch throttle.ask(now: now) {
            case .now: bumps.append(now)
            case .after(let delay): timer = now + delay
            case .folded: break
            }
        }
        if let due = timer {
            throttle.trailingFired(now: due)
            bumps.append(due)
        }
        #expect(!throttle.pending)
        return bumps
    }

    /// 300 imported files, a create (two bumps) every 10 ms: the UI hears a
    /// bounded number of times, and once more after the last.
    @Test func aBurstOf300CreatesIsABoundedNumberOfBumpsEndingAfterTheLast() {
        let asks = (0 ..< 300).flatMap { n in [Double(n) * 0.01, Double(n) * 0.01 + 0.002] }
        let bumps = run(asks: asks, interval: 0.25)
        #expect(bumps.count <= 14, "\(bumps.count) bumps for 600 asks over 3 s")
        #expect(bumps.last! >= asks.last!, "the last bump comes after the last change, so nothing is left stale")
        #expect(bumps.last! - asks.last! <= 0.25)
        #expect(bumps.first == 0, "the first goes out at once")
    }

    @Test func aSingleEditIsHeardAtOnceAndItsLandingWithinTheInterval() {
        let bumps = run(asks: [10, 10.012], interval: 0.25)
        #expect(bumps.count == 2)
        #expect(bumps.first == 10)
        #expect(abs(bumps[1] - 10.25) < 0.0001)
    }

    @Test func editsFarApartAreEachHeardAtOnce() {
        #expect(run(asks: [1, 2, 3], interval: 0.25) == [1, 2, 3])
    }

    private func entry(_ id: String, _ updated: TimeInterval, _ kind: DocumentKind = .presentation) -> LibraryIndex.Entry {
        LibraryIndex.Entry(id: id, kind: kind, subkind: "", name: id, updatedAt: Date(timeIntervalSince1970: updated), lastUsedAt: nil)
    }

    /// An edit to deck A redraws A's tiles, not B's; a picture imported
    /// redraws neither.
    @Test func onlyTheEditedDecksTilesAreTold() {
        let before = IndexSnapshot(entries: [entry("A", 1), entry("B", 1)], areas: [:], generation: 1)
        let edited = IndexSnapshot(entries: [entry("A", 2), entry("B", 1)], areas: [:], generation: 2)
        #expect(DeckStamps.changed(watched: ["A", "B"], before: before, after: edited) == ["A"])
        let imported = IndexSnapshot(
            entries: [entry("A", 2), entry("B", 1), entry("pic", 5, .media)], areas: [:], generation: 3)
        #expect(DeckStamps.changed(watched: ["A", "B"], before: edited, after: imported).isEmpty)
        #expect(DeckStamps.changed(watched: ["A"], before: nil, after: imported) == ["A"], "first read: tell it")
        let removed = IndexSnapshot(entries: [entry("B", 1)], areas: [:], generation: 4)
        #expect(DeckStamps.changed(watched: ["A", "B"], before: imported, after: removed) == ["A"])
    }
}
