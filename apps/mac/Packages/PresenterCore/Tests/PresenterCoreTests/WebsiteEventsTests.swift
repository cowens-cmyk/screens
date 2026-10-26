import Foundation
import Testing

@testable import PresenterCore

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func event(
    _ title: String, _ start: String, time: String? = nil, end: String? = nil, endTime: String? = nil,
    allDay: Bool = false, image: String? = "https://media.hopejc.org/events/img/x.jpg",
    cancelled: Bool = false, base: String? = nil, slug: String? = nil, calendars: [String] = ["master"]
) -> WebsiteEvent {
    WebsiteEvent(
        slug: slug ?? "\(title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(start)", title: title,
        baseTitle: base, cancelled: cancelled, startDate: start, startTime: time, endDate: end, endTime: endTime,
        allDay: allDay, image: image.map { $0 == "https://media.hopejc.org/events/img/x.jpg" ? "https://media.hopejc.org/events/img/\(title).jpg" : $0 },
        calendars: calendars)
}

private let sample = """
{"events":[
 {"slug":"operation-christmas-child-2026-10-12","title":"Operation Christmas Child","summary":"x","cancelled":false,
  "base_title":"Operation Christmas Child","cancel_note":null,"start_date":"2026-10-12","start_time":null,
  "end_date":"2026-11-22","end_time":null,"all_day":true,"location_name":"Hope Church","signup_url":null,
  "image":"/events/img/mv09c39s-occ-shoeboxes-1920x1080.jpg","calendars":["master"],
  "url":"https://www.hopejc.org/events/operation-christmas-child-2026-10-12"},
 {"slug":"discover-hope-2026-11-04","title":"Discover Hope","cancelled":false,"base_title":null,
  "start_date":"2026-11-04","start_time":"18:30","end_date":null,"end_time":"20:00","all_day":false,
  "image":null,"calendars":["master"]},
 {"slug":"broken","title":null,"start_date":"2026-11-04"},
 {"slug":"no-date","title":"No Date","start_date":"soon"},
 {"slug":"skate-2026-11-07","title":"70s Skate Night","start_date":"2026-11-07","start_time":"16:30",
  "end_date":"2026-11-07","end_time":"18:30","all_day":false,"cancelled":true,
  "image":"https://cdn.example.org/skate.jpg","calendars":["master","students"]}
]}
"""

// MARK: The feed

@Test func feedDecodesWithNullsAndSkipsBrokenEntries() throws {
    let events = try WebsiteEvents.parseFeed(Data(sample.utf8))
    #expect(events.map(\.slug) == ["operation-christmas-child-2026-10-12", "discover-hope-2026-11-04", "skate-2026-11-07"])
    let occ = events[0]
    #expect(occ.allDay && occ.startTime == nil && occ.endDate == "2026-11-22")
    #expect(occ.image == "https://media.hopejc.org/events/img/mv09c39s-occ-shoeboxes-1920x1080.jpg", "relative to the CMS")
    let discover = events[1]
    #expect(discover.baseTitle == "Discover Hope", "a null base title falls back to the title")
    #expect(discover.image == nil && discover.endDate == nil && discover.endTime == "20:00")
    #expect(events[2].cancelled && events[2].image == "https://cdn.example.org/skate.jpg")
    #expect(events[2].calendars == ["master", "students"])
    #expect(throws: (any Error).self) { try WebsiteEvents.parseFeed(Data("{\"nope\":1}".utf8)) }
}

@Test func feedAsksForTheChurchCalendar() {
    let url = WebsiteEvents.feedURL().absoluteString
    #expect(url.hasPrefix("https://media.hopejc.org/api/public/calendar?"))
    #expect(url.contains("calendar=master"))
}

// MARK: The window and removal

@Test func timedEventShowsFromAMonthBeforeUntilItStarts() {
    // Oct 31 at 17:00 EDT is 21:00 UTC.
    let trunk = event("Trunk or Treat", "2026-10-31", time: "17:00", end: "2026-10-31", endTime: "19:00")
    let options = WebsiteEvents.Options()
    #expect(WebsiteEvents.startsAt(trunk) == utc(2026, 10, 31, 21))
    #expect(WebsiteEvents.showFrom(trunk, windowDays: 30) == utc(2026, 10, 1, 4), "midnight church time, 30 days before")
    #expect(WebsiteEvents.desired([trunk], now: utc(2026, 10, 1, 3, 59), options: options).isEmpty)
    #expect(WebsiteEvents.desired([trunk], now: utc(2026, 10, 1, 4), options: options).count == 1)
    #expect(WebsiteEvents.desired([trunk], now: utc(2026, 10, 31, 20, 59), options: options).count == 1)
    #expect(WebsiteEvents.desired([trunk], now: utc(2026, 10, 31, 21), options: options).isEmpty, "gone as it starts")
    let untilEnd = WebsiteEvents.Options(removeAtEnd: true)
    #expect(WebsiteEvents.removeAt(trunk, removeAtEnd: true) == utc(2026, 10, 31, 23))
    #expect(WebsiteEvents.desired([trunk], now: utc(2026, 10, 31, 22), options: untilEnd).count == 1)
}

@Test func allDayEventsComeDownAtTheStartOfTheirDay() {
    let arc = event("Arc Encounter", "2026-10-29", end: "2026-10-31", allDay: true)
    #expect(WebsiteEvents.removeAt(arc, removeAtEnd: false) == utc(2026, 10, 29, 4))
    // Until it ends: the end of its last day.
    #expect(WebsiteEvents.removeAt(arc, removeAtEnd: true) == utc(2026, 11, 1, 4))
    // An event with no time is treated as all day.
    let untimed = event("Bake Sale", "2026-10-29")
    #expect(WebsiteEvents.removeAt(untimed, removeAtEnd: false) == utc(2026, 10, 29, 4))
}

@Test func multiDayEventStaysUntilItEndsWhenChosen() {
    let occ = event("Operation Christmas Child", "2026-10-12", end: "2026-11-22", allDay: true)
    let now = utc(2026, 10, 26, 14)
    #expect(WebsiteEvents.desired([occ], now: now, options: .init()).isEmpty, "already started")
    let shown = WebsiteEvents.desired([occ], now: now, options: .init(removeAtEnd: true))
    #expect(shown.count == 1)
    #expect(shown.first?.removeAt == utc(2026, 11, 23, 5), "the end of Nov 22, after the clocks go back")
    // A timed event over several days ends at its end time on its last day.
    let camp = event("Camp", "2026-11-06", time: "18:00", end: "2026-11-08", endTime: "12:00")
    #expect(WebsiteEvents.removeAt(camp, removeAtEnd: true) == utc(2026, 11, 8, 17))
    // An end time before the start on the same day doesn't end it early.
    let odd = event("Odd", "2026-11-06", time: "18:00", endTime: "10:00")
    #expect(WebsiteEvents.removeAt(odd, removeAtEnd: true) == utc(2026, 11, 7, 5))
}

@Test func cancelledUnpicturedAndOtherCalendarsAreNeverShown() {
    let now = utc(2026, 10, 26, 14)
    let events = [
        event("Skate Night", "2026-11-07", time: "16:30", cancelled: true),
        event("Discover Hope", "2026-11-04", time: "18:30", image: nil),
        event("Students Gathering", "2026-10-28", time: "19:00", calendars: ["students"]),
        event("Baptisms", "2026-11-08", time: "08:00", calendars: ["master", "kids"]),
    ]
    #expect(WebsiteEvents.desired(events, now: now, options: .init()).map(\.event.title) == ["Baptisms"])
}

@Test func theWindowSpansTheChangeBackFromDaylightTime() {
    // The clocks go back on Nov 1, 2026: 8:00 that morning is 13:00 UTC,
    // and the window opened at midnight EDT on Oct 2.
    let baptisms = event("Baptisms", "2026-11-01", time: "08:00")
    #expect(WebsiteEvents.startsAt(baptisms) == utc(2026, 11, 1, 13))
    #expect(WebsiteEvents.showFrom(baptisms, windowDays: 30) == utc(2026, 10, 2, 4))
    let dinner = event("Dinner", "2026-11-03", time: "18:30")
    #expect(WebsiteEvents.startsAt(dinner) == utc(2026, 11, 3, 23, 30))
    #expect(WebsiteEvents.desired([dinner], now: utc(2026, 11, 3, 23, 29), options: .init()).count == 1)
    #expect(WebsiteEvents.desired([dinner], now: utc(2026, 11, 3, 23, 30), options: .init()).isEmpty)
    // The window in the spring: Mar 8, 2027 is after the clocks go forward.
    let spring = event("Spring", "2027-03-20", time: "09:00")
    #expect(WebsiteEvents.startsAt(spring) == utc(2027, 3, 20, 13))
    #expect(WebsiteEvents.showFrom(spring, windowDays: 30) == utc(2027, 2, 18, 5))
}

@Test func theWindowFollowsTheChosenLength() {
    let event = event("Passion", "2027-02-05", allDay: true)
    let now = utc(2026, 12, 20, 12)
    #expect(WebsiteEvents.desired([event], now: now, options: .init(windowDays: 30)).isEmpty)
    #expect(WebsiteEvents.desired([event], now: now, options: .init(windowDays: 60)).count == 1)
    #expect(WebsiteEvents.Options(windowDays: 200).windowDays == 60)
    #expect(WebsiteEvents.Options(windowDays: 1).windowDays == 7)
}

// MARK: Repeating events, hiding and order

@Test func aRepeatingEventShowsOnlyItsNextOccurrence() {
    let image = "https://media.hopejc.org/events/img/next-steps.jpg"
    let weekly = ["2026-10-21", "2026-10-28", "2026-11-04"].map {
        event("Next Steps 202", $0, time: "18:30", image: image, slug: "next-steps-202-\($0)")
    }
    let now = utc(2026, 10, 26, 14)
    let shown = WebsiteEvents.desired(weekly, now: now, options: .init())
    #expect(shown.map(\.event.slug) == ["next-steps-202-2026-10-28"])
    // Once that one starts, the next takes its place under the same key.
    let later = WebsiteEvents.desired(weekly, now: utc(2026, 10, 29, 12), options: .init())
    #expect(later.map(\.event.slug) == ["next-steps-202-2026-11-04"])
    #expect(later.first?.key == shown.first?.key)
    // A cancelled occurrence passes to the next one.
    var withCancelled = weekly
    withCancelled[1].cancelled = true
    #expect(WebsiteEvents.desired(withCancelled, now: now, options: .init()).map(\.event.slug) == ["next-steps-202-2026-11-04"])
    // A different picture under the same name is its own event.
    var other = weekly[2]
    other.image = "https://media.hopejc.org/events/img/other.jpg"
    #expect(WebsiteEvents.desired([weekly[1], other], now: now, options: .init()).count == 2)
}

@Test func hiddenEventsStayOutButSettingsCanListThem() {
    let events = [event("Baptisms", "2026-11-08", time: "08:00"), event("Dinner", "2026-11-15", time: "18:00")]
    let now = utc(2026, 10, 26, 14)
    let settings = WebsiteEvents.setting(nil, hidden: true, baseTitle: "baptisms ")
    #expect(settings.hidden == ["baptisms"])
    let options = WebsiteEvents.Options(settings)
    #expect(WebsiteEvents.desired(events, now: now, options: options).map(\.event.title) == ["Dinner"])
    let listed = WebsiteEvents.desired(events, now: now, options: options, includingHidden: true)
    #expect(listed.map(\.event.title) == ["Baptisms", "Dinner"])
    #expect(listed.map(\.hidden) == [true, false])
    let shownAgain = WebsiteEvents.setting(settings, hidden: false, baseTitle: "Baptisms")
    #expect(shownAgain.hidden == nil)
    #expect(WebsiteEvents.isEnabled(nil) && !WebsiteEvents.isEnabled(WebsiteEventSettings(enabled: false)))
}

@Test func soonestEventComesFirst() {
    let events = [
        event("Dinner", "2026-11-15", time: "18:00"),
        event("Summit", "2026-11-07", time: "10:00"),
        event("Skate", "2026-11-07", time: "16:30"),
        event("Arc", "2026-11-07", allDay: true),
    ]
    let order = WebsiteEvents.desired(events, now: utc(2026, 10, 26, 14), options: .init()).map(\.event.title)
    #expect(order == ["Arc", "Summit", "Skate", "Dinner"])
}

// MARK: The next boundary

@Test func nextBoundaryIsTheNextWindowOrRemovalOrMidnight() {
    let options = WebsiteEvents.Options()
    let dinner = event("Dinner", "2026-11-15", time: "18:00")
    let trunk = event("Trunk", "2026-10-31", time: "17:00")
    let now = utc(2026, 10, 31, 12)
    // Trunk comes down at 21:00 UTC; midnight is 04:00 UTC on Nov 1.
    #expect(WebsiteEvents.nextBoundary([dinner, trunk], now: now, options: options) == utc(2026, 10, 31, 21))
    // Dinner's window opens at midnight Oct 16 church time.
    #expect(WebsiteEvents.nextBoundary([dinner], now: utc(2026, 10, 15, 12), options: options) == utc(2026, 10, 16, 4))
    // With nothing else, the next local midnight; after the change it's 05:00 UTC.
    #expect(WebsiteEvents.nextBoundary([], now: utc(2026, 11, 5, 12), options: options) == utc(2026, 11, 6, 5))
    // A slide's own removal time counts with no feed.
    let tag = WebsiteEventTag(key: "k", slug: "s", title: "T", startDate: "2026-11-05",
                              removeAt: WebsiteEvents.stamp(utc(2026, 11, 5, 14)), imageUrl: "u")
    #expect(WebsiteEvents.nextBoundary([], tags: [tag], now: utc(2026, 11, 5, 12), options: options) == utc(2026, 11, 5, 14))
    // Cancelled events don't wake anything.
    let cancelled = event("Gone", "2026-10-31", time: "13:00", cancelled: true)
    #expect(WebsiteEvents.nextBoundary([cancelled], now: now, options: options) == utc(2026, 11, 1, 4))
}

// MARK: Slides

private func handMade(_ id: String) -> Slide {
    Slide(id: id, name: id, objects: [])
}

private func wanted(_ titles: [String], now: Date = utc(2026, 10, 26, 14)) -> [WebsiteEvents.Wanted] {
    let events = titles.enumerated().map { index, title in
        event(title, DayStamp.adding(index + 1, to: "2026-11-01"), time: "18:00")
    }
    return WebsiteEvents.desired(events, now: now, options: .init()).map {
        WebsiteEvents.Wanted(shown: $0, mediaID: "media-\($0.event.title)")
    }
}

@Test func newEventsGoInARunAfterTheHandMadeSlides() {
    let existing = [handMade("welcome"), handMade("giving")]
    let plan = WebsiteEvents.plan(existing: existing, wanted: wanted(["Dinner", "Summit"]))
    #expect(plan.slides.map(\.name) == ["welcome", "giving", "Dinner", "Summit"])
    #expect(plan.added.count == 2 && plan.removed.isEmpty && plan.updated.isEmpty)
    let dinner = plan.slides[2]
    #expect(dinner.id == WebsiteEvents.slideID(forKey: dinner.sourceEvent!.key), "the same id on every Mac")
    #expect(dinner.background?.mediaId == "media-Dinner" && dinner.objects.isEmpty && dinner.unthemed == true)
    #expect(dinner.sourceEvent?.slug == "dinner-2026-11-02")
    #expect(SlideLabels.label(for: dinner, at: 2, in: Presentation(
        id: "p", name: "Pre-Service", presentationKind: .deck, themeId: "", slides: plan.slides)).title == "Dinner \u{00B7} Nov 2")
}

@Test func runningAgainChangesNothing() {
    let first = WebsiteEvents.plan(existing: [handMade("welcome")], wanted: wanted(["Dinner", "Summit"]))
    let again = WebsiteEvents.plan(existing: first.slides, wanted: wanted(["Dinner", "Summit"]))
    #expect(!again.changed)
    #expect(again.slides == first.slides)
}

@Test func onlyTaggedSlidesAreUpdatedOrRemovedAndTheRunStaysWhereItWas() {
    let start = WebsiteEvents.plan(existing: [handMade("welcome")], wanted: wanted(["Dinner", "Summit"])).slides
    // Someone moves the run to the front and adds slides around it.
    var existing = [start[1], start[2], start[0], handMade("giving")]
    existing[1].transition = Transition(transitionKind: .dissolve, durationSeconds: 1)
    // Summit's picture changes media; Dinner is over; Retreat is new.
    var want = wanted(["Dinner", "Summit", "Retreat"], now: utc(2026, 11, 2, 23, 30))
    want[0].mediaID = "media-Summit-2"
    let plan = WebsiteEvents.plan(existing: existing, wanted: want)
    #expect(plan.slides.map(\.name) == ["Summit", "Retreat", "welcome", "giving"])
    #expect(plan.removed == [start[1].id])
    #expect(plan.added == [plan.slides[1].id])
    #expect(plan.updated == [start[2].id])
    #expect(plan.slides[0].background?.mediaId == "media-Summit-2")
    #expect(plan.slides[0].transition != nil, "what someone set on the slide stays")
    #expect(plan.slides[2] == existing[2] && plan.slides[3] == existing[3], "hand-made slides untouched")
}

@Test func aSecondCopyOfAnEventIsDropped() {
    let made = WebsiteEvents.plan(existing: [], wanted: wanted(["Dinner"])).slides
    let twice = [handMade("welcome"), made[0], handMade("giving"), made[0]]
    let plan = WebsiteEvents.plan(existing: twice, wanted: wanted(["Dinner"]))
    #expect(plan.slides.map(\.name) == ["welcome", "Dinner", "giving"])
    #expect(plan.removed == [made[0].id])
}

@Test func everythingGoesWhenNothingIsWanted() {
    let made = WebsiteEvents.plan(existing: [handMade("welcome")], wanted: wanted(["Dinner", "Summit"])).slides
    let plan = WebsiteEvents.plan(existing: made, wanted: [])
    #expect(plan.slides.map(\.name) == ["welcome"])
    #expect(plan.removed.count == 2)
}

@Test func artworkNotYetDownloadedWaitsButKeepsAnExistingSlide() {
    let made = WebsiteEvents.plan(existing: [], wanted: wanted(["Dinner"])).slides
    var want = wanted(["Dinner", "Summit"])
    want[0].mediaID = nil
    want[1].mediaID = nil
    let plan = WebsiteEvents.plan(existing: made, wanted: want)
    #expect(plan.slides.map(\.name) == ["Dinner"])
    #expect(plan.slides[0].background?.mediaId == "media-Dinner")
    #expect(!plan.changed)
}

@Test func theLiveSlideIsLeftAloneUntilItMovesOn() {
    let made = WebsiteEvents.plan(existing: [handMade("welcome")], wanted: wanted(["Dinner", "Summit"])).slides
    let live = made[1].id
    // Dinner is over while it's on the screens.
    let plan = WebsiteEvents.plan(existing: made, wanted: Array(wanted(["Dinner", "Summit"]).dropFirst()), liveSlideID: live)
    #expect(plan.slides.map(\.name) == ["welcome", "Dinner", "Summit"])
    #expect(plan.deferred && plan.removed.isEmpty)
    // Its artwork changing waits too.
    var changed = wanted(["Dinner", "Summit"])
    changed[0].mediaID = "media-new"
    let update = WebsiteEvents.plan(existing: made, wanted: changed, liveSlideID: live)
    #expect(update.slides[1] == made[1] && update.deferred)
    // A hand-made slide being live changes nothing.
    let handLive = WebsiteEvents.plan(existing: made, wanted: Array(wanted(["Dinner", "Summit"]).dropFirst()), liveSlideID: "welcome")
    #expect(!handLive.deferred && handLive.removed == [live])
}

@Test func expiredSlidesGoWithNoFeed() {
    let made = WebsiteEvents.plan(existing: [handMade("welcome")], wanted: wanted(["Dinner", "Summit"])).slides
    let afterDinner = utc(2026, 11, 2, 23, 0)
    let plan = WebsiteEvents.expiredOnly(existing: made, now: afterDinner, liveSlideID: nil)
    #expect(plan.slides.map(\.name) == ["welcome", "Summit"])
    #expect(plan.removed == [made[1].id])
    let held = WebsiteEvents.expiredOnly(existing: made, now: afterDinner, liveSlideID: made[1].id)
    #expect(held.removed.isEmpty && held.deferred)
    #expect(WebsiteEvents.mediaIDs(in: made) == ["media-Dinner", "media-Summit"])
}

@Test func labelsReadTheEventAndItsDay() {
    let tag = WebsiteEventTag(key: "k", slug: "s", title: "Trunk or Treat", startDate: "2026-10-31", imageUrl: "u")
    #expect(WebsiteEvents.label(tag) == "Trunk or Treat \u{00B7} Oct 31")
    #expect(WebsiteEvents.shortDay("2027-01-05") == "Jan 5")
}

// MARK: The live slide's place

@Test func theLiveSlideKeepsItsPlaceWhenSlidesMoveAroundIt() {
    #expect(LiveOccurrence.follow(slideID: "b", from: 1, in: ["new", "a", "b", "c"]) == 2)
    #expect(LiveOccurrence.follow(slideID: "b", from: 1, in: ["b", "c"]) == 0)
    #expect(LiveOccurrence.follow(slideID: "x", from: 1, in: ["a", "b"]) == nil)
    // An arrangement repeating the chorus: the nearest one.
    #expect(LiveOccurrence.follow(slideID: "chorus", from: 3, in: ["v1", "chorus", "v2", "chorus", "end"]) == 3)
    #expect(LiveOccurrence.follow(slideID: "chorus", from: nil, in: ["v1", "chorus", "v2", "chorus"]) == 1)
}

@Test func announcementsIsAMediaCategory() {
    #expect(MediaLibraryCategory.announcements.folder == "Announcements")
    #expect(MediaLibraryCategory.containing(folder: "Announcements") == .announcements)
}
