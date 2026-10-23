import Foundation
@testable import PresenterCore
import Testing

struct ServiceCountdownTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ stamp: String) -> Date {
        ScheduleMath.parseLocalDate(stamp, calendar: calendar)!
    }

    @Test func countdownEndsAtTheServiceTime() {
        let service = date("2026-10-25T10:30:00")
        #expect(ServiceCountdown.start(serviceTime: service, videoSeconds: 310)
            == date("2026-10-25T10:24:50"))
        // A fraction of a second over starts a second earlier, never late.
        #expect(ServiceCountdown.start(serviceTime: service, videoSeconds: 300.4)
            == date("2026-10-25T10:24:59"))
        #expect(ServiceCountdown.start(serviceTime: service, videoSeconds: nil)
            == date("2026-10-25T10:25:00"))
    }

    @Test func plansGetACountdownFirstOnce() {
        let song = ServiceItem(id: "s", itemKind: .presentation, name: "Song", refId: "p")
        let plan = Service(id: "plan", name: "Sunday", serviceDate: "2026-10-25", items: [song])
        let ensured = ServiceCountdown.ensuringCountdown(plan)!
        #expect(ensured.items.count == 2)
        #expect(ensured.items[0].isCountdown == true)
        #expect(ensured.items[0].itemKind == .media)
        #expect(ensured.items[0].refId.isEmpty)
        #expect(ServiceCountdown.ensuringCountdown(ensured) == nil)

        var template = plan
        template.isTemplate = true
        #expect(ServiceCountdown.ensuringCountdown(template) == nil)
    }

    @Test func triggerPlaysThePlansCountdownAtItsStart() {
        let start = date("2026-10-25T10:24:50")
        let trigger = ServiceCountdown.trigger(
            planID: "plan", planName: "Sunday", countdownItemID: "cd",
            start: start, serviceTime: date("2026-10-25T10:30:00"), calendar: calendar)
        #expect(trigger.conditions.first?.kind == .oneTime)
        #expect(trigger.conditions.first?.date == "2026-10-25T10:24:50")
        #expect(trigger.actions.first?.kind == .fireServiceItem)
        #expect(trigger.actions.first?.serviceId == "plan")
        #expect(trigger.actions.first?.serviceItemId == "cd")
        #expect(trigger.name == "Sunday 10:30 AM Countdown")
        #expect(ServiceCountdown.isCountdownTrigger(trigger, planID: "plan"))
        #expect(!ServiceCountdown.isCountdownTrigger(trigger, planID: "other"))
        #expect(ScheduleMath.nextDue(for: trigger.conditions[0], after: date("2026-10-25T09:00:00"), calendar: calendar) == start)
    }
}
