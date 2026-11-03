import Foundation
import Testing

/// The plan page's keyboard copy, cut, paste and delete across its many
/// item grids.
@Suite struct PlanPageSelectionSweepTests {
    @Test func everyCopyAndCutHasItsOwnRound() throws {
        let sweep = try SourceSweep.app()
        let grid = try #require(sweep.file("PresentGridView.swift")).text
        // A cut never changes `copies`, and a rebuilt page counts from zero
        // again, so matching on `copies` added old slides to a new copy.
        #expect(grid.contains("SlidePasteboard.copyGeneration == clipboardRequests.round"))
        #expect(!grid.contains("copyGeneration == clipboardRequests.copies"))
        #expect(grid.contains("case .cut:\n            round = SlidePasteboard.nextRound()"))
        #expect(grid.contains("case .copy:\n            round = SlidePasteboard.nextRound()"))
    }

    @Test func followingTheLiveSlideLeavesPasteWhereTheOperatorPointed() throws {
        let sweep = try SourceSweep.app()
        let page = try #require(sweep.file("ServiceContinuousView.swift")).text
        let grid = try #require(sweep.file("PresentGridView.swift")).text
        #expect(page.contains("let followed = focusScroll.honoredItemID == id\n"))
        #expect(page.contains("if !followed { pointNewSlide(at: id) }"))
        #expect(grid.contains("let followsLive = pageMarquee == nil || route.clickedSlide(in: contextID)"))
    }

    @Test func aClickInOneItemLetsTheOthersSelectionGo() throws {
        let sweep = try SourceSweep.app()
        let grid = try #require(sweep.file("PresentGridView.swift")).text
        #expect(grid.components(separatedBy: "pageMarquee?.own(contextID)").count - 1 == 2, "a tile click and an empty-space click")
        #expect(grid.contains("onOtherOwner: clearSelection"))
    }

    @Test func thePageBodyNeverReadsTheDraggedBox() throws {
        let sweep = try SourceSweep.app()
        let file = try #require(sweep.file("ServiceContinuousView.swift"))
        for index in file.lines.indices
        where file.code(index).contains("marquee.rect") || file.code(index).contains("pageMarquee.rect") {
            #expect(file.enclosingType(of: index) == "PageMarqueeBox", "line \(index + 1): the box changes on every mouse move")
        }
        #expect(file.text.contains("PageMarqueeBox(marquee: pageMarquee)"))
    }
}
