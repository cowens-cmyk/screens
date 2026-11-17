import Foundation
import Testing
@testable import PresenterCore

@Suite struct StudentsHangTimeTests {
    private func item(_ id: String, _ name: String, kind: ServiceItemKind = .info, ref: String = "") -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: name, refId: ref)
    }

    @Test func theHangTimeItemGetsTheSlideshowAndWalkIn() throws {
        let items = [item("h", "6:00 PM - DOORS OPEN", kind: .header), item("a", "Students Hang Time"), item("b", "Countdown")]
        let linked = try #require(StudentsHangTime.linking(items, to: "students-hang-time"))
        #expect(linked[1].itemKind == .presentation && linked[1].refId == "students-hang-time")
        #expect(linked[1].lightingCue == "walkIn")
        #expect(linked[0] == items[0] && linked[2] == items[2])
        // Once linked, nothing more to do.
        #expect(StudentsHangTime.linking(linked, to: "students-hang-time") == nil)
    }

    @Test func aHandLinkOrAnotherLookStays() {
        var mine = item("a", "HANG TIME", kind: .presentation, ref: "my-deck")
        #expect(StudentsHangTime.linking([mine], to: "students-hang-time") == nil)
        mine.refId = "students-hang-time"
        mine.lightingCue = "announcements"
        #expect(StudentsHangTime.linking([mine], to: "students-hang-time") == nil)
        #expect(StudentsHangTime.linking([item("a", "Students Hang Time")], to: nil) == nil)
    }

    @Test func findsTheSlideshowAndChecksSizes() {
        #expect(StudentsHangTime.find(ids: [("x", "Students Hang Time"), ("students-hang-time", "Hang")]) == "students-hang-time")
        #expect(StudentsHangTime.find(ids: [("z", "students hang-time"), ("y", "Students Hang Time")]) == "y")
        #expect(StudentsHangTime.find(ids: [("x", "Pre-Service")]) == nil)
        #expect(StudentsHangTime.fits(width: 1920, height: 1080))
        #expect(!StudentsHangTime.fits(width: 1080, height: 1080))
        #expect(!StudentsHangTime.fits(width: nil, height: nil))
        let deck = StudentsHangTime.newSlideshow()
        #expect(deck.id == "students-hang-time" && deck.name == "Students Hang Time")
        #expect(deck.autoAdvance?.loopToStart == true)
    }

    @Test func theStudentsCalendarIsReadOnItsOwn() {
        #expect(WebsiteEvents.feedURL(calendar: "students").absoluteString.contains("calendar=students"))
        #expect(WebsiteEvents.feedURL().absoluteString.contains("calendar=master"))
    }
}
