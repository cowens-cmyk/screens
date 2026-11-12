import Foundation
@testable import PresenterCore
import Testing

struct MessageCleanupTests {
    private func plan(_ id: String, _ date: String, message: String?, items refs: [String] = [], template: Bool = false) -> Service {
        var plan = Service(id: id, name: id, serviceDate: date, items: refs.map {
            ServiceItem(id: id + $0, itemKind: .presentation, name: $0, refId: $0)
        })
        plan.messagePresentationId = message
        if template { plan.isTemplate = true }
        return plan
    }

    private let sermons: Set<String> = ["gen38", "gen40", "gen12", "tmplMsg", "bumper"]

    private func sweep(_ plans: [Service], folders: [String: String] = [:], protected: Set<String> = []) -> MessageCleanup.Sweep {
        MessageCleanup.sweep(
            plans: plans, isSermon: { sermons.contains($0) }, folderOf: { folders[$0] },
            protected: protected, cutoff: "2026-10-12")
    }

    @Test func theCutoffIsThirtyDaysBack() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
        #expect(MessageCleanup.cutoff(today: today, calendar: calendar) == "2026-10-12")
    }

    @Test func oldMessagesGoAndNewOnesAreFiled() {
        let result = sweep([
            plan("oct11", "2026-10-11", message: "gen38", items: ["song", "gen38"]),
            plan("oct12", "2026-10-12T10:30:00", message: "gen12", items: ["gen12"]),
            plan("nov15", "2026-11-15", message: "gen40", items: ["song", "gen40"]),
        ])
        #expect(result.toRemove == ["gen12", "gen38"], "30 days old or older")
        #expect(result.toFile == ["gen40"])
    }

    @Test func songsAndOtherPresentationsAreNeverTouched() {
        // "song" is in old plans but is not a message, and not a sermon.
        let result = sweep([plan("old", "2025-01-05", message: "song", items: ["song"])])
        #expect(result.toRemove.isEmpty && result.toFile.isEmpty)
    }

    @Test func aMessageUsedAgainRecentlyOrByATemplateStays() {
        let reused = sweep([
            plan("old", "2026-09-01", message: "gen38", items: ["gen38"]),
            plan("recent", "2026-11-01", message: nil, items: ["gen38"]),
        ], folders: ["gen38": "Messages"])
        #expect(reused.toRemove.isEmpty && reused.toFile.isEmpty)

        let template = sweep([
            plan("old", "2026-09-01", message: "tmplMsg", items: ["tmplMsg"]),
            plan("tmpl", "2026-01-01", message: "tmplMsg", items: ["tmplMsg"], template: true),
        ])
        #expect(template.toRemove.isEmpty)
    }

    @Test func serviceDayPresentationsAreProtected() {
        let result = sweep([plan("old", "2026-09-01", message: "bumper", items: ["bumper"])], protected: ["bumper"])
        #expect(result.toRemove.isEmpty)
    }

    @Test func foldersInsideMessagesCount() {
        #expect(MessageCleanup.isInFolder("Messages"))
        #expect(MessageCleanup.isInFolder("Messages/2026"))
        #expect(!MessageCleanup.isInFolder("Messages Old"))
        #expect(!MessageCleanup.isInFolder(nil))
    }
}
