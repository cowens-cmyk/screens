import Foundation
import Testing
@testable import PresenterCore

/// The main window's activity bar: what it says while files are imported
/// and the plan is loaded, and when its summaries go.
struct ActivityBoardTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func importing(_ board: ActivityBoard) -> ActivityBoard.Line? {
        board.lines.first { $0.kind == .importing }
    }

    private func plan(_ board: ActivityBoard) -> ActivityBoard.Line? {
        board.lines.first { $0.kind == .plan }
    }

    @Test func nothingRunningSaysNothing() {
        #expect(ActivityBoard().lines.isEmpty)
        #expect(ActivityBoard().nextExpiry == nil)
    }

    @Test func aDropGoesThroughItsStagesInOrder() {
        var board = ActivityBoard()
        let ticket = board.beginImport()
        #expect(importing(board)?.title == "Getting files ready")
        #expect(importing(board)?.fraction == nil, "no count yet")

        board.noteFiles(done: 0, total: 318, fileName: "Slide01_Wide.png", of: ticket)
        #expect(importing(board)?.title == "Importing 1 of 318")
        #expect(importing(board)?.detail == "Slide01_Wide.png")
        #expect(importing(board)?.fraction == 0)

        board.noteFiles(done: 41, total: 318, fileName: "Slide21_Wide.png", of: ticket)
        #expect(importing(board)?.title == "Importing 42 of 318")
        #expect(abs((importing(board)?.fraction ?? 0) - 41.0 / 318) < 1e-9)

        board.setStage(.makingSlides, of: ticket)
        #expect(importing(board)?.title == "Making slides")
        #expect(importing(board)?.tone == .working)

        board.note("Imported 318 of 318 files", of: ticket)
        board.endImport(ticket, at: start)
        #expect(importing(board)?.title == "Imported 318 of 318 files")
        #expect(importing(board)?.tone == .done)
    }

    @Test func theLastFileNeverCountsPastTheTotal() {
        var board = ActivityBoard()
        let ticket = board.beginImport()
        board.noteFiles(done: 3, total: 3, fileName: "c.png", of: ticket)
        #expect(importing(board)?.title == "Importing 3 of 3")
        #expect(importing(board)?.fraction == 1)
    }

    @Test func aSecondDropWhileOneRunsCountsBothAndClearsNeither() {
        var board = ActivityBoard()
        let first = board.beginImport()
        board.noteFiles(done: 10, total: 100, fileName: "a10.png", of: first)
        let second = board.beginImport()
        #expect(importing(board)?.title == "Importing 11 of 100", "the second is still getting ready")
        board.noteFiles(done: 0, total: 50, fileName: "b0.png", of: second)
        #expect(importing(board)?.title == "Importing 11 of 150")
        #expect(importing(board)?.detail == "b0.png", "the file most recently started")

        // The first finishing must not take the bar away from the second.
        board.noteFiles(done: 100, total: 100, fileName: "a99.png", of: first)
        board.note("Imported 100 of 100 files", of: first)
        board.endImport(first, at: start)
        #expect(importing(board)?.tone == .working)
        #expect(importing(board)?.title == "Importing 1 of 50")

        board.noteFiles(done: 50, total: 50, fileName: "b49.png", of: second)
        board.note("Imported 48 of 50 files — 2 skipped", problem: true, of: second)
        board.endImport(second, at: start)
        let summary = importing(board)
        #expect(summary?.title == "Imported 100 of 100 files · Imported 48 of 50 files — 2 skipped")
        #expect(summary?.tone == .problem, "one of them skipped files")
    }

    @Test func aMakingSlidesJobDoesNotHideAnotherStillCopying() {
        var board = ActivityBoard()
        let first = board.beginImport()
        board.noteFiles(done: 20, total: 20, fileName: "a.png", of: first)
        board.setStage(.makingSlides, of: first)
        let second = board.beginImport()
        board.noteFiles(done: 1, total: 10, fileName: "b.png", of: second)
        #expect(importing(board)?.title == "Importing 22 of 30", "the finished batch still counts")
    }

    @Test func aTicketsSecondBatchAddsToItsCount() {
        // A PDF's pages, then the pictures dropped with it, on one ticket.
        var board = ActivityBoard()
        let ticket = board.beginImport(.document(name: "Notes.pdf"))
        #expect(importing(board)?.title == "Importing \u{201C}Notes.pdf\u{201D}")
        board.noteFiles(done: 0, total: 4, fileName: "Notes 1.png", of: ticket)
        board.noteFiles(done: 4, total: 4, fileName: "Notes 4.png", of: ticket)
        board.noteFiles(done: 0, total: 2, fileName: "x.png", of: ticket)
        #expect(importing(board)?.title == "Importing 5 of 6")
    }

    @Test func aPlainSummaryGoesQuicklyAProblemStaysLonger() {
        var board = ActivityBoard()
        let ok = board.beginImport()
        board.note("Imported 3 of 3 files", of: ok)
        board.endImport(ok, at: start)
        #expect(board.nextExpiry == start.addingTimeInterval(ActivityBoard.doneShown))
        board.expire(at: start.addingTimeInterval(ActivityBoard.doneShown - 0.1))
        #expect(importing(board) != nil)
        board.expire(at: start.addingTimeInterval(ActivityBoard.doneShown))
        #expect(importing(board) == nil)

        let bad = board.beginImport()
        board.note("Keynote export failed", problem: true, of: bad)
        board.endImport(bad, at: start)
        board.expire(at: start.addingTimeInterval(ActivityBoard.doneShown + 1))
        #expect(importing(board)?.tone == .problem, "still up after a plain summary would have gone")
        board.expire(at: start.addingTimeInterval(ActivityBoard.problemShown))
        #expect(importing(board) == nil)
    }

    @Test func aNewImportReplacesTheLastSummaryAndClosingOneTakesItDown() {
        var board = ActivityBoard()
        let first = board.beginImport()
        board.note("Imported 1 of 1 files", of: first)
        board.endImport(first, at: start)
        _ = board.beginImport()
        #expect(importing(board)?.title == "Getting files ready")
        #expect(board.nextExpiry == nil, "nothing to expire while it runs")

        var other = ActivityBoard()
        let ticket = other.beginImport()
        other.note("Imported 1 of 1 files", of: ticket)
        other.endImport(ticket, at: start)
        other.dismiss(.importing)
        #expect(other.lines.isEmpty)
    }

    @Test func anImportThatSaysNothingLeavesNothing() {
        var board = ActivityBoard()
        let ticket = board.beginImport()
        board.endImport(ticket, at: start)
        #expect(board.lines.isEmpty)
        board.endImport(ticket, at: start)  // twice is harmless
        #expect(!board.isImporting)
    }

    @Test func thePlanLoadsOnItsOwnLineBesideAnImport() {
        var board = ActivityBoard()
        board.beginPlanLoad(total: 340)
        board.notePlanLoad(done: 12, total: 340)
        let ticket = board.beginImport()
        board.noteFiles(done: 4, total: 9, fileName: "x.png", of: ticket)
        #expect(board.lines.map(\.kind) == [.importing, .plan])
        #expect(plan(board)?.title == "Loading the plan into memory 12 of 340")
        #expect(abs((plan(board)?.fraction ?? 0) - 12.0 / 340) < 1e-9)
        #expect(importing(board)?.title == "Importing 5 of 9")

        board.endPlanLoad(files: 340, leftOut: 0, at: start)
        #expect(plan(board)?.title == "Plan in memory: 340 files")
        #expect(plan(board)?.tone == .done)
        #expect(importing(board)?.tone == .working, "the plan finishing leaves the import alone")
    }

    @Test func picturesLeftOutAreSaidAndStayUp() {
        var board = ActivityBoard()
        board.beginPlanLoad(total: 300)
        board.endPlanLoad(files: 300, leftOut: 12, at: start)
        #expect(plan(board)?.tone == .problem)
        #expect(plan(board)?.title.contains("12 pictures") == true)
        #expect(board.nextExpiry == start.addingTimeInterval(ActivityBoard.problemShown))
    }

    @Test func anOvertakenOrCancelledPassLeavesNoSummary() {
        var board = ActivityBoard()
        board.beginPlanLoad(total: 10)
        board.cancelPlanLoad()
        #expect(board.lines.isEmpty)
        board.notePlanLoad(done: 3, total: 10)
        #expect(board.lines.isEmpty, "progress from a pass that's gone is ignored")
    }

    @Test func releasingThePlanForMemorySaysSo() {
        var board = ActivityBoard()
        board.notePlanReleased(at: start)
        #expect(plan(board)?.tone == .problem)
        board.beginPlanLoad(total: 5)
        #expect(plan(board)?.tone == .working, "loading again replaces the notice")
    }
}
