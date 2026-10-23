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

    @Test func aCountdownThePlanAlreadyHasIsMarkedNotDoubled() {
        let welcome = ServiceItem(id: "w", itemKind: .header, name: "Countdown", refId: "")
        let shepherd = ServiceItem(id: "c", itemKind: .info, name: "COUNTDOWN", refId: "")
        let song = ServiceItem(id: "s", itemKind: .presentation, name: "Song", refId: "p")
        let plan = Service(id: "plan", name: "Sunday", serviceDate: "2026-10-25", items: [welcome, shepherd, song])
        #expect(ServiceCountdown.change(for: plan) == .mark(itemID: "c"), "a header named Countdown is only a heading")
        let marked = ServiceCountdown.ensuringCountdown(plan)!
        #expect(marked.items.count == 3)
        #expect(ServiceCountdown.item(in: marked)?.id == "c")
        #expect(ServiceCountdown.change(for: marked) == nil)

        // Linked to a countdown video, or a presentation named Countdown.
        let video = ServiceItem(id: "v", itemKind: .media, name: "Opener", refId: "cd-video")
        let linked = Service(id: "plan", name: "Sunday", serviceDate: "2026-10-25", items: [song, video])
        #expect(ServiceCountdown.change(for: linked, isCountdownLink: { $0.refId == "cd-video" }) == .mark(itemID: "v"))
        var fresh = ServiceItem(id: "new", itemKind: .media, name: "Countdown", refId: "")
        fresh.isCountdown = true
        #expect(ServiceCountdown.change(for: linked, makeID: { "new" }) == .insert(fresh))

        #expect(ServiceCountdown.looksLikeCountdown("Count Down"))
        #expect(ServiceCountdown.looksLikeCountdown("countdown:"))
        #expect(!ServiceCountdown.looksLikeCountdown("Countdown to Christmas"))
        #expect(ServiceCountdown.isCountdownFolder("Countdowns/Fall"))
        #expect(!ServiceCountdown.isCountdownFolder("Countdowns Old"))
        #expect(!ServiceCountdown.isCountdownFolder(nil))
    }

    @Test func aRemovedCountdownStaysRemoved() {
        let song = ServiceItem(id: "s", itemKind: .presentation, name: "Song", refId: "p")
        var plan = ServiceCountdown.ensuringCountdown(
            Service(id: "plan", name: "Sunday", serviceDate: "2026-10-25", items: [song]))!
        ServiceCountdown.remove(itemID: "s", from: &plan)
        #expect(plan.countdownRemoved == nil, "taking out anything else isn't remembered")
        let countdown = ServiceCountdown.item(in: plan)!
        ServiceCountdown.remove(itemID: countdown.id, from: &plan)
        #expect(plan.items.isEmpty)
        #expect(plan.countdownRemoved == true)
        #expect(ServiceCountdown.change(for: plan) == nil, "not put back")
        // A change worked out before the removal doesn't land after it.
        var stale = plan
        #expect(!ServiceCountdown.apply(.insert(countdown), to: &stale))
        // An item that plainly is the countdown (Shepherd sent it again) is
        // still marked.
        plan.items = [ServiceItem(id: "c", itemKind: .info, name: "Countdown", refId: "")]
        #expect(ServiceCountdown.change(for: plan) == .mark(itemID: "c"))
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
