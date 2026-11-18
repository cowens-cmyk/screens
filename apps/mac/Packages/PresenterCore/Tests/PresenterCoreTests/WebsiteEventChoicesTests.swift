import Foundation
import Testing
@testable import PresenterCore

@Test func eachSlideshowTurnsOffOnItsOwn() {
    #expect(WebsiteEvents.isEnabled(nil, for: .preService))
    #expect(WebsiteEvents.isEnabled(nil, for: .students))
    let noStudents = WebsiteEvents.setting(nil, enabled: false, for: .students)
    #expect(WebsiteEvents.isEnabled(noStudents, for: .preService))
    #expect(!WebsiteEvents.isEnabled(noStudents, for: .students))
    #expect(WebsiteEvents.isEnabled(noStudents), "still writes for Sundays")
    let neither = WebsiteEvents.setting(noStudents, enabled: false, for: .preService)
    #expect(!WebsiteEvents.isEnabled(neither))
    let back = WebsiteEvents.setting(neither, enabled: true, for: .students)
    #expect(back.studentsEnabled == nil)
    #expect(!WebsiteEvents.isEnabled(back, for: .preService))
}

@Test func theOldAllOffSwitchTurnsBothOff() {
    let old = WebsiteEventSettings(enabled: false)
    #expect(!WebsiteEvents.isEnabled(old, for: .preService))
    #expect(!WebsiteEvents.isEnabled(old, for: .students))
    // Turning one on keeps the other off, as it was.
    let sundays = WebsiteEvents.setting(old, enabled: true, for: .preService)
    #expect(sundays.enabled == nil)
    #expect(WebsiteEvents.isEnabled(sundays, for: .preService))
    #expect(!WebsiteEvents.isEnabled(sundays, for: .students))
}

@Test func anEventsOwnPictureIsKeptByName() {
    var settings = WebsiteEvents.setting(nil, replacement: "m1", baseTitle: " Hope Students Gathering ")
    #expect(WebsiteEvents.replacement(settings, baseTitle: "hope students gathering") == "m1")
    #expect(WebsiteEvents.replacement(settings, baseTitle: "Trunk or Treat") == nil)
    settings = WebsiteEvents.setting(settings, replacement: "m2", baseTitle: "Hope Students Gathering")
    #expect(settings.replacements?.count == 1)
    #expect(WebsiteEvents.replacement(settings, baseTitle: "Hope Students Gathering") == "m2")
    settings = WebsiteEvents.setting(settings, replacement: nil, baseTitle: "HOPE STUDENTS GATHERING")
    #expect(settings.replacements == nil)
}

@Test func aHiddenStudentsEventIsLeftOut() {
    let now = WebsiteEvents.date(day: "2026-11-18", time: "12:00")!
    let gathering = WebsiteEvent(
        slug: "g", title: "Hope Students Gathering", startDate: "2026-11-25", startTime: "18:30",
        image: "https://media.hopejc.org/g.jpg", calendars: ["students"])
    let retreat = WebsiteEvent(
        slug: "r", title: "Winter Retreat", startDate: "2026-12-05",
        image: "https://media.hopejc.org/r.jpg", calendars: ["students"])
    let settings = WebsiteEvents.setting(nil, hidden: true, baseTitle: "Hope Students Gathering")
    let shown = WebsiteEvents.desired(
        [gathering, retreat], now: now, options: .init(settings), calendar: StudentsHangTime.calendar)
    #expect(shown.map(\.event.title) == ["Winter Retreat"])
    let listed = WebsiteEvents.desired(
        [gathering, retreat], now: now, options: .init(settings), includingHidden: true,
        calendar: StudentsHangTime.calendar)
    #expect(listed.first { $0.event.slug == "g" }?.hidden == true)
}
