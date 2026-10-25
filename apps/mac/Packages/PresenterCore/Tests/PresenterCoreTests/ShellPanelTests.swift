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
        #expect(panel.waited(close) == nil)
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
}
