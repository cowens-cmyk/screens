import Foundation
import Testing
@testable import PresenterCore

/// #require can't take a mutating call, so the panel's answer goes through here.
private func unwrap(_ wait: ShellPanel.Wait?, sourceLocation: SourceLocation = #_sourceLocation) throws -> ShellPanel.Wait {
    try #require(wait, sourceLocation: sourceLocation)
}

@Suite struct ShellPanelTests {
    @Test func hoverPeeksOnlyAfterTheOpenDelay() throws {
        var panel = ShellPanel(pinned: false)
        let wait = try unwrap(panel.pointerEntered(at: 10))
        #expect(wait == .open(generation: panel.generation))
        #expect(panel.mode == .collapsed, "nothing opens the moment the pointer touches the bubble")
        #expect(panel.waited(wait) == nil)
        #expect(panel.mode == .peek)
    }

    @Test func aPointerThatOnlyCrossesTheBubbleOpensNothing() throws {
        var panel = ShellPanel(pinned: false)
        let wait = try unwrap(panel.pointerEntered(at: 10))
        _ = panel.pointerLeft()
        _ = panel.waited(wait)
        #expect(panel.mode == .collapsed)
    }

    @Test func leavingAPeekCollapsesAfterTheGrace() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let close = try unwrap(panel.pointerLeft())
        #expect(close == .close(generation: panel.generation))
        #expect(panel.mode == .peek, "the grace delay runs first")
        #expect(panel.waited(close) == .release(generation: panel.generation), "then its content waits for the shape to settle")
        #expect(panel.mode == .collapsed)
    }

    @Test func comingBackDuringTheGraceKeepsThePeek() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let close = try unwrap(panel.pointerLeft())
        #expect(panel.pointerEntered(at: 10.2) == nil, "already open; nothing to wait for")
        #expect(panel.waited(close) == nil)
        #expect(panel.mode == .peek)
    }

    @Test func anOldGraceNeverClosesALaterPeek() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let first = try unwrap(panel.pointerLeft())
        _ = panel.pointerEntered(at: 10.1)
        let second = try unwrap(panel.pointerLeft())
        #expect(panel.waited(first) == nil)
        #expect(panel.mode == .peek, "the first leave was cancelled by the return")
        _ = panel.waited(second)
        #expect(panel.mode == .collapsed)
    }

    @Test func somethingHeldOpenFromThePeekKeepsItOpen() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let close = try unwrap(panel.pointerLeft())
        let again = try unwrap(panel.waited(close, holding: true))
        #expect(again == .close(generation: panel.generation), "the grace starts over")
        #expect(panel.mode == .peek)
        _ = panel.waited(again, holding: false)
        #expect(panel.mode == .collapsed)
    }

    @Test func clickPinsFromCollapsedOrPeek() throws {
        var collapsed = ShellPanel(pinned: false)
        collapsed.click(at: 10)
        #expect(collapsed.mode == .pinned)

        var peeking = ShellPanel(pinned: false)
        _ = peeking.waited(try unwrap(peeking.pointerEntered(at: 10)))
        peeking.click(at: 11)
        #expect(peeking.mode == .pinned)
        #expect(peeking.pointerLeft() == nil, "a pinned panel ignores the pointer")
        #expect(peeking.mode == .pinned)
    }

    @Test func aQuickClickBeatsThePeek() throws {
        var panel = ShellPanel(pinned: false)
        let open = try unwrap(panel.pointerEntered(at: 10))
        panel.click(at: 10.05)
        #expect(panel.waited(open) == nil)
        #expect(panel.mode == .pinned, "the pending hover doesn't turn the pin into a peek")
    }

    @Test func clickingAPinnedPanelCollapsesItWithoutReopeningUnderThePointer() {
        var panel = ShellPanel(pinned: true)
        panel.click(at: 20)
        #expect(panel.mode == .collapsed)
        #expect(panel.pointerEntered(at: 20.2) == nil, "the bubble lands under the pointer and stays a bubble")
        _ = panel.pointerLeft()
        #expect(panel.pointerEntered(at: 20 + ShellPanel.quietAfterCollapse + 0.1) != nil)
    }

    @Test func theMenuTogglesBetweenPinnedAndCollapsed() throws {
        var panel = ShellPanel(pinned: true)
        panel.toggle()
        #expect(panel.mode == .collapsed)
        #expect(panel.pointerEntered(at: 0) != nil, "no quiet period: the pointer was in the menu")
        panel.toggle()
        #expect(panel.mode == .pinned)

        var peeking = ShellPanel(pinned: false)
        _ = peeking.waited(try unwrap(peeking.pointerEntered(at: 1)))
        peeking.toggle()
        #expect(peeking.mode == .pinned)
    }

    @Test func dismissingFoldsOnlyAPeek() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 1)))
        panel.dismissPeek()
        #expect(panel.mode == .collapsed)
        #expect(!panel.hovering)

        var pinned = ShellPanel(pinned: true)
        pinned.dismissPeek()
        #expect(pinned.mode == .pinned)
    }

    @Test func setPinnedFollowsAnOutsideChange() {
        var panel = ShellPanel(pinned: false)
        panel.setPinned(true)
        #expect(panel.isPinned)
        panel.setPinned(false)
        #expect(panel.mode == .collapsed)
    }

    @Test func thePlanStartsDockedAndTheScreensAsTheStrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShellPanelTests-\(UUID().uuidString)"))
        #expect(ShellPanel.Side.plans.storedPinned(in: defaults))
        #expect(!ShellPanel.Side.screens.storedPinned(in: defaults))
        defaults.set(false, forKey: ShellPanel.Side.plans.defaultsKey)
        #expect(!ShellPanel.Side.plans.storedPinned(in: defaults))
        #expect(ShellPanel.Side.plans.defaultsKey != ShellPanel.Side.screens.defaultsKey)
    }

    @Test func theGraceIsLongerThanTheOpenDelay() {
        #expect(ShellPanel.graceDelay == .milliseconds(350))
        #expect(ShellPanel.openDelay < ShellPanel.graceDelay)
        #expect(ShellPanel.Wait.close(generation: 0).duration == ShellPanel.graceDelay)
    }

    // MARK: Motion: what's built and drawn while the shape moves

    @Test func theContentIsBuiltWhileThePointerWaitsToOpen() throws {
        var panel = ShellPanel(pinned: false)
        #expect(!panel.contentBuilt, "a folded panel builds nothing")
        let open = try unwrap(panel.pointerEntered(at: 10))
        #expect(panel.contentBuilt, "built during the open delay, before the shape moves")
        #expect(panel.mode == .collapsed)
        _ = panel.waited(open)
        #expect(panel.mode == .peek)
        #expect(panel.contentBuilt, "the frame the shape starts to grow in has nothing to build")
    }

    @Test func theContentGoesOnlyOnceTheFoldedShapeHasSettled() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let close = try unwrap(panel.pointerLeft())
        let release = try unwrap(panel.waited(close))
        #expect(panel.mode == .collapsed)
        #expect(panel.contentBuilt, "kept while the shape shrinks over it")
        #expect(release == .release(generation: panel.generation))
        #expect(release.duration >= .milliseconds(Int(ShellPanel.settleTime * 1000)))
        #expect(panel.waited(release) == nil)
        #expect(!panel.contentBuilt, "let go once nothing is moving")
    }

    @Test func comingBackBeforeTheReleaseKeepsTheContent() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        let release = try unwrap(panel.waited(try unwrap(panel.pointerLeft())))
        _ = panel.pointerEntered(at: 11)
        #expect(panel.waited(release) == nil)
        #expect(panel.contentBuilt, "the pointer is back: reopening needs it")
    }

    @Test func aPointerThatOnlyCrossesTheBubbleLetsTheContentGoLater() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.pointerEntered(at: 10)
        let release = try unwrap(panel.pointerLeft())
        #expect(panel.contentBuilt)
        _ = panel.waited(release)
        #expect(!panel.contentBuilt)
    }

    @Test func unpinningKeepsTheContentUntilTheShapeSettles() throws {
        var panel = ShellPanel(pinned: true)
        #expect(panel.contentBuilt, "a pinned panel starts with its content")
        let release = try unwrap(panel.click(at: 20))
        #expect(panel.contentBuilt)
        _ = panel.pointerLeft()
        #expect(panel.waited(release) == nil)
        #expect(panel.contentBuilt, "the pointer moved after the click; its own release wait follows")

        var menu = ShellPanel(pinned: true)
        let fromMenu = try unwrap(menu.toggle())
        _ = menu.waited(fromMenu)
        #expect(!menu.contentBuilt)
    }

    @Test func aPinFromTheMenuBuildsTheContentBeforeTheShapeGrows() {
        var panel = ShellPanel(pinned: false)
        #expect(panel.needsContentBeforePin)
        panel.buildContent()
        #expect(!panel.needsContentBeforePin)
        #expect(panel.mode == .collapsed, "building moves nothing")
        #expect(panel.toggle() == nil)
        #expect(panel.isPinned && panel.contentBuilt)
    }

    @Test func aPinnedPanelNeverLetsItsContentGo() throws {
        var panel = ShellPanel(pinned: false)
        let open = try unwrap(panel.pointerEntered(at: 10))
        panel.click(at: 10.3)
        _ = panel.waited(open)
        #expect(panel.pointerLeft() == nil)
        #expect(panel.contentBuilt)
    }

    @Test func previewsDrawOnlyOnTheFaceThatShows() throws {
        var panel = ShellPanel(pinned: false)
        #expect(!panel.showsOpenFace, "folded: the strip's previews draw, the column's are paused")
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 10)))
        #expect(panel.showsOpenFace, "peeking: the column's previews draw from the start, so they're fresh when its content fades in")
        panel.click(at: 11)
        #expect(panel.showsOpenFace)
    }

    @Test func leavingEditDropsAPeeksContentAtOnce() throws {
        var panel = ShellPanel(pinned: false)
        _ = panel.waited(try unwrap(panel.pointerEntered(at: 1)))
        panel.dismissPeek()
        #expect(!panel.contentBuilt, "its views went with Edit; nothing waits to be released")
    }

    @Test func theShapeSettlesInAboutHalfASecond() {
        // The release waits this long, and the hitch meter watches this long.
        #expect(ShellPanel.settleTime > 0.4 && ShellPanel.settleTime < 0.6)
        #expect(ShellPanel.springResponse == 0.42 && ShellPanel.springDamping == 0.72)
        #expect(ShellPanel.Wait.release(generation: 0).duration > ShellPanel.graceDelay)
    }
}

@Suite struct FrameHitchCountTests {
    private static let hz120 = 1.0 / 120

    @Test func steadyFramesAreNeverLate() {
        var count = FrameHitchCount()
        for frame in 0...60 { count.record(timestamp: Double(frame) * Self.hz120, interval: Self.hz120) }
        #expect(count.frames == 60)
        #expect(count.late == 0 && count.missed == 0)
        #expect(count.summary == "60 frames at 120 Hz, none late, longest 8.3 ms")
    }

    @Test func aGapOfMoreThanOneAndAHalfIntervalsIsLate() {
        var count = FrameHitchCount()
        let times = [0.0, 1, 2, 5, 6, 7.4].map { $0 * Self.hz120 }
        for time in times { count.record(timestamp: time, interval: Self.hz120) }
        #expect(count.frames == 5)
        #expect(count.late == 1, "1.4 intervals is jitter, 3 is a hitch")
        #expect(count.missed == 2)
        #expect(abs(count.longest - 3 * Self.hz120) < 1e-9)
        #expect(count.summary.contains("1 late (2 missed)"))
    }

    @Test func theFirstTickOnlyStartsTheClock() {
        var count = FrameHitchCount()
        count.record(timestamp: 5, interval: Self.hz120)
        #expect(count.frames == 0)
        count.record(timestamp: 5 + 1.0 / 60, interval: 1.0 / 60)
        #expect(count.frames == 1 && count.late == 0, "the display dropped to 60 Hz; judged by its own interval")
    }
}
