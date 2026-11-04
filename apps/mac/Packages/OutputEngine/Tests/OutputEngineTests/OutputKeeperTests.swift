import XCTest
@testable import OutputEngine

final class OutputKeeperTests: XCTestCase {
    private func sendingKeeper(at now: TimeInterval = 0) -> OutputKeeper {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: now)
        keeper.opened(at: now + 0.5)
        keeper.frameAccepted(at: now + 0.6)
        return keeper
    }

    /// Runs ticks every second from `start` until a step other than .none
    /// comes back, or `limit` seconds pass.
    private func tickUntilStep(
        _ keeper: inout OutputKeeper, from start: TimeInterval, limit: TimeInterval = 60,
        offered: TimeInterval? = nil, accepted: TimeInterval? = nil
    ) -> (step: OutputKeeper.Step, at: TimeInterval)? {
        var now = start
        while now <= start + limit {
            let step = keeper.tick(at: now, lastOffered: offered, lastAccepted: accepted)
            if step != .none { return (step, now) }
            now += 1
        }
        return nil
    }

    func testBeginOpensAtOnceAndAFirstFrameMeansSending() {
        var keeper = OutputKeeper()
        XCTAssertEqual(keeper.begin(at: 10), .open)
        XCTAssertEqual(keeper.phase, .opening(since: 10))
        keeper.opened(at: 11)
        XCTAssertFalse(keeper.isSending, "an answered open is not yet sending")
        keeper.frameAccepted(at: 11.2)
        XCTAssertTrue(keeper.isSending)
        XCTAssertTrue(keeper.hasSent)
        XCTAssertNil(keeper.problem)
    }

    func testAFrameReportLosingTheRaceToTheTickStillConfirms() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        keeper.opened(at: 1)
        XCTAssertEqual(keeper.tick(at: 2, lastOffered: 1.5, lastAccepted: 1.5), .none)
        XCTAssertTrue(keeper.isSending)
    }

    func testAFrameFromBeforeTheOpenAnsweredDoesNotConfirm() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        keeper.opened(at: 1)
        _ = keeper.tick(at: 2, lastOffered: 0.5, lastAccepted: 0.5)
        XCTAssertFalse(keeper.isSending)
    }

    // The launch bug: an open error used to leave the port failed for good
    // unless it was one of two "transient" messages.
    func testEveryOpenErrorIsRetriedUntilItSends() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        let step = keeper.openFailed("no playback modes", at: 0.2)
        XCTAssertEqual(step, .abandon(reason: "no playback modes", killHelper: false))
        XCTAssertEqual(keeper.problem, "no playback modes")
        XCTAssertTrue(keeper.isRunning)

        var now: TimeInterval = 0.2
        for attempt in 1...8 {
            guard let (step, at) = tickUntilStep(&keeper, from: now) else {
                return XCTFail("attempt \(attempt) never retried")
            }
            XCTAssertEqual(step, .open)
            now = at
            _ = keeper.openFailed("no playback modes", at: now + 0.1)
        }
        guard let (step, at) = tickUntilStep(&keeper, from: now) else {
            return XCTFail("stopped retrying")
        }
        XCTAssertEqual(step, .open)
        keeper.opened(at: at + 0.2)
        keeper.frameAccepted(at: at + 0.3)
        XCTAssertTrue(keeper.isSending)
        XCTAssertNil(keeper.problem)
    }

    func testRetriesBackOffAndCap() {
        let keeper = OutputKeeper()
        XCTAssertEqual(keeper.retryDelay(afterFailures: 1), 1)
        XCTAssertEqual(keeper.retryDelay(afterFailures: 2), 2)
        XCTAssertEqual(keeper.retryDelay(afterFailures: 3), 4)
        XCTAssertEqual(keeper.retryDelay(afterFailures: 4), 8)
        XCTAssertEqual(keeper.retryDelay(afterFailures: 5), 10)
        XCTAssertEqual(keeper.retryDelay(afterFailures: 500), 10)
    }

    func testAnOpenThatNeverAnswersKillsTheHelperAndRetries() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        XCTAssertEqual(keeper.tick(at: 7, lastOffered: 6.9, lastAccepted: nil), .none,
                       "a slow cold open is left alone")
        let step = keeper.tick(at: 8, lastOffered: 7.9, lastAccepted: nil)
        XCTAssertEqual(step, .abandon(reason: "the helper never answered the open", killHelper: true))
        XCTAssertEqual(tickUntilStep(&keeper, from: 8)?.step, .open)
    }

    func testOpensThatNeverTakeAFrameRetryThenKillTheWedgedHelper() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        keeper.opened(at: 1)
        XCTAssertEqual(keeper.tick(at: 3, lastOffered: 2.9, lastAccepted: nil), .none)
        XCTAssertEqual(
            keeper.tick(at: 4, lastOffered: 3.9, lastAccepted: nil),
            .abandon(reason: "opened but no frame landed", killHelper: false))
        guard let (step, at) = tickUntilStep(&keeper, from: 4) else { return XCTFail() }
        XCTAssertEqual(step, .open)
        keeper.opened(at: at)
        XCTAssertEqual(
            tickUntilStep(&keeper, from: at, offered: at, accepted: nil)?.step,
            .abandon(reason: "opened but no frame landed", killHelper: true))
    }

    func testAWorkingPortIsNeverTouched() {
        var keeper = sendingKeeper()
        for second in 1...600 {
            let now = TimeInterval(second)
            XCTAssertEqual(keeper.tick(at: now, lastOffered: now - 0.2, lastAccepted: now - 0.4), .none)
        }
        XCTAssertTrue(keeper.isSending)
        XCTAssertEqual(keeper.failures, 0)
    }

    func testAStillPictureResentTwiceASecondKeepsItSending() {
        var keeper = sendingKeeper()
        for second in 1...60 {
            let now = TimeInterval(second)
            let lastResend = (now * 2).rounded(.down) / 2
            XCTAssertEqual(keeper.tick(at: now, lastOffered: lastResend, lastAccepted: lastResend), .none)
        }
        XCTAssertTrue(keeper.isSending)
    }

    func testFramesRefusedWhileOfferedReopensThePort() {
        var keeper = sendingKeeper()
        XCTAssertEqual(keeper.tick(at: 3, lastOffered: 2.9, lastAccepted: 1), .none)
        XCTAssertEqual(
            keeper.tick(at: 4, lastOffered: 3.9, lastAccepted: 1),
            .abandon(reason: "frames stopped landing", killHelper: false))
        XCTAssertTrue(keeper.hasSent, "a reconnect, not a first start")
        XCTAssertEqual(tickUntilStep(&keeper, from: 4)?.step, .open)
    }

    func testAnAppThatStoppedOfferingFramesDoesNotReopenAWorkingPort() {
        var keeper = sendingKeeper()
        // The mirror (the app's side) went quiet at 1 s: nothing was refused.
        for second in 2...30 {
            XCTAssertEqual(
                keeper.tick(at: TimeInterval(second), lastOffered: 1, lastAccepted: 1), .none)
        }
        XCTAssertTrue(keeper.isSending)
    }

    func testAPortThatKeepsDroppingOutSlowsDownInsteadOfFlapping() {
        var keeper = sendingKeeper()
        var now: TimeInterval = 1
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            // Sends for two seconds, then stalls.
            let accepted = now + 2
            guard let (step, failedAt) = tickUntilStep(
                &keeper, from: now + 3, offered: accepted + 10, accepted: accepted)
            else { return XCTFail("stall never noticed") }
            XCTAssertEqual(step, .abandon(reason: "frames stopped landing", killHelper: false))
            guard let (open, openedAt) = tickUntilStep(&keeper, from: failedAt)
            else { return XCTFail("never retried") }
            XCTAssertEqual(open, .open)
            waits.append(openedAt - failedAt)
            keeper.opened(at: openedAt)
            keeper.frameAccepted(at: openedAt)
            now = openedAt
        }
        XCTAssertEqual(waits, waits.sorted(), "each fault waits at least as long")
        XCTAssertGreaterThanOrEqual(waits.last ?? 0, 8)
    }

    func testSendingSteadilyResetsTheBackoff() {
        var keeper = sendingKeeper()
        _ = keeper.lost("helper restarted", at: 1)
        _ = keeper.tick(at: 2, lastOffered: nil, lastAccepted: nil)
        keeper.opened(at: 2)
        keeper.frameAccepted(at: 2.1)
        XCTAssertEqual(keeper.failures, 1)
        _ = keeper.tick(at: 12.5, lastOffered: 12.4, lastAccepted: 12.4)
        XCTAssertEqual(keeper.failures, 0)
    }

    func testAHelperThatGoesAwayIsRetriedFromEveryLivePhase() {
        for setUp in [
            { (k: inout OutputKeeper) in _ = k.begin(at: 0) },
            { (k: inout OutputKeeper) in _ = k.begin(at: 0); k.opened(at: 0.5) },
            { (k: inout OutputKeeper) in k = self.sendingKeeper() },
        ] {
            var keeper = OutputKeeper()
            setUp(&keeper)
            XCTAssertEqual(
                keeper.lost("helper unreachable", at: 1),
                .abandon(reason: "helper unreachable", killHelper: false))
            XCTAssertEqual(tickUntilStep(&keeper, from: 1)?.step, .open)
        }
    }

    func testLateReportsForAnAttemptAlreadyOverAreIgnored() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        _ = keeper.openFailed("busy", at: 0.5)
        XCTAssertEqual(keeper.lost("helper unreachable", at: 0.6), .none)
        XCTAssertEqual(keeper.openFailed("busy", at: 0.7), .none)
        keeper.opened(at: 0.8)
        keeper.frameAccepted(at: 0.9)
        XCTAssertEqual(keeper.failures, 1)
        XCTAssertFalse(keeper.isSending)
    }

    func testRetrySoonSkipsTheWait() {
        var keeper = OutputKeeper()
        _ = keeper.begin(at: 0)
        var now: TimeInterval = 0
        for _ in 0..<5 {
            _ = keeper.openFailed("not found", at: now)
            now = tickUntilStep(&keeper, from: now)?.at ?? now
        }
        _ = keeper.openFailed("not found", at: 100)
        XCTAssertEqual(keeper.phase, .waiting(until: 110))
        XCTAssertEqual(keeper.tick(at: 101, lastOffered: nil, lastAccepted: nil), .none)
        keeper.retrySoon(at: 101)
        XCTAssertEqual(keeper.tick(at: 101, lastOffered: nil, lastAccepted: nil), .open)
    }

    func testStopEndsEverything() {
        var keeper = sendingKeeper()
        keeper.stop()
        XCTAssertFalse(keeper.isRunning)
        XCTAssertEqual(keeper.tick(at: 100, lastOffered: 99, lastAccepted: 1), .none)
        XCTAssertEqual(keeper.lost("x", at: 100), .none)
    }
}
