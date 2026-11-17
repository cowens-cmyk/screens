import Foundation
import Testing
@testable import PresenterCore

@Suite struct PlanCleanupTests {
    private func plan(_ id: String, _ date: String, message: String? = nil, template: Bool = false) -> Service {
        var service = Service(id: id, name: "Plan \(id)", serviceDate: date, items: [])
        service.messagePresentationId = message
        service.isTemplate = template ? true : nil
        return service
    }

    @Test func keepsFourWeeksAndTakesWhatIsOlder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 14))!
        let cutoff = PlanCleanup.cutoff(today: today, calendar: calendar)
        #expect(cutoff == "2026-10-20")
        let plans = [
            plan("old", "2026-10-18"), plan("edge", "2026-10-20"), plan("recent", "2026-11-15"),
            plan("next", "2026-11-22"), plan("template", "2026-01-04", template: true), plan("undated", ""),
            plan("open", "2026-09-27"), plan("older", "2026-10-04T10:00"),
        ]
        let old = PlanCleanup.oldPlans(plans, cutoff: cutoff, keep: ["open"])
        #expect(old.map(\.id) == ["older", "old"])
    }

    @Test func aMessageGoesOnlyWhenNothingLeftNamesIt() {
        let removed = [plan("a", "2026-10-04", message: "m1"), plan("b", "2026-10-11", message: "m2"),
                       plan("c", "2026-10-11", message: "song")]
        let remaining = [plan("d", "2026-11-15", message: "m2"), plan("t", "", message: "m3", template: true)]
        let messages = PlanCleanup.messages(
            of: removed + [plan("e", "2026-10-11", message: "m3")], remaining: remaining,
            isSermon: { $0.hasPrefix("m") }, protected: [])
        #expect(messages == ["m1"])
        #expect(PlanCleanup.messages(of: removed, remaining: [], isSermon: { _ in true }, protected: ["m1"]) == ["m2", "song"])
    }

    @Test func trashFileNamesAreSafe() {
        var service = plan("x", "2026-10-04")
        service.name = "October 4, 2026 — Genesis 30/31: Jacob"
        #expect(PlanCleanup.trashFileName(for: service) == "Screens plan — October 4, 2026 — Genesis 30-31- Jacob.json")
    }
}
