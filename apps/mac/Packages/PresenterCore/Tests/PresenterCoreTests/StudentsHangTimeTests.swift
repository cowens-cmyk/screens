import Foundation
import Testing
@testable import PresenterCore

@Suite struct StudentsHangTimeTests {
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

@Suite struct StudentsNightTests {
    private func item(_ id: String, _ name: String, kind: ServiceItemKind = .info, ref: String = "") -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: name, refId: ref)
    }

    /// Tomorrow's plan as Shepherd has it.
    private var wednesday: Service {
        var countdown = item("cd", "Countdown")
        countdown.isCountdown = true
        var song = item("s1", "Come To Jesus", kind: .presentation, ref: "song-1")
        song.mxuSongTitle = "Come To Jesus"
        var closing = item("s3", "Gratitude", kind: .presentation, ref: "song-3")
        closing.mxuSongTitle = "Gratitude"
        var plan = Service(id: "shepherd-p1", name: "November 18, 2026 — Wednesday Night", serviceDate: "2026-11-18", items: [
            item("h1", "6:00 PM - DOORS OPEN", kind: .header), item("ht", "Students Hang Time"),
            item("h2", "6:30 PM - START COUNTDOWN", kind: .header), countdown,
            item("h3", "6:35 PM - WELCOME/GAME", kind: .header), item("g", "Game TBD"),
            item("h4", "6:55 PM - WORSHIP", kind: .header), song,
            item("h5", "7:15 PM - MESSAGE", kind: .header), item("m", "Message"),
            item("h6", "7:40 PM - CLOSING SONG", kind: .header), closing,
            item("h7", "7:50 PM - BREAKOUT GROUPS", kind: .header), item("b", "Breakout Groups"),
        ], mxuServiceTypeName: "Wednesday Night")
        plan.transitionRemoved = true
        plan.preServiceRemoved = true
        return plan
    }

    @Test func theNightIsFilledIn() throws {
        let shaped = try #require(StudentsNight.shaping(wednesday, planID: "p1", hangTimeID: "students-hang-time"))
        let byID = Dictionary(uniqueKeysWithValues: shaped.service.items.map { ($0.id, $0) })
        func stream(_ id: String) -> String? { byID[id]?.actions?.first { $0.kind == .setStreamMode }?.streamMode }

        #expect(byID["ht"]?.refId == "students-hang-time" && byID["ht"]?.lightingCue == "walkIn" && stream("ht") == "fullScreen")
        #expect(byID["g"]?.refId == "shepherd-p1-game" && byID["g"]?.lightingCue == "walkIn" && stream("g") == "off")
        #expect(byID["b"]?.refId == "shepherd-p1-breakout" && byID["b"]?.lightingCue == "walkIn" && stream("b") == "fullScreen")
        #expect(byID["m"]?.refId == "shepherd-message-p1" && byID["m"]?.lightingCue == nil && stream("m") == "off")
        #expect(shaped.service.messagePresentationId == "shepherd-message-p1")
        // The bumper goes back in before the message.
        #expect(shaped.service.transitionRemoved == nil)
        #expect(shaped.service.preServiceRemoved == true)
        // Songs and the countdown are left to the lights' own numbering.
        #expect(byID["s1"] == wednesday.items.first { $0.id == "s1" })
        #expect(byID["cd"] == wednesday.items.first { $0.id == "cd" })

        let decks = Dictionary(uniqueKeysWithValues: shaped.presentations.map { ($0.id, $0) })
        #expect(decks.keys.sorted() == ["shepherd-message-p1", "shepherd-p1-breakout", "shepherd-p1-game"])
        #expect(decks["shepherd-message-p1"]?.sermonTimerSeconds == 1800)
        #expect(decks["shepherd-message-p1"]?.category == PresentationTypes.sermon)
        #expect(decks.values.allSatisfy { $0.slides.isEmpty })
        // Once filled in, nothing more to do.
        #expect(StudentsNight.shaping(shaped.service, planID: "p1", hangTimeID: "students-hang-time") == nil)
    }

    @Test func theLightsNumberTheSongsOneTwoThree() throws {
        let shaped = try #require(StudentsNight.shaping(wednesday, planID: "p1", hangTimeID: nil))
        let positions = ServicePosition.positions(in: shaped.service.items)
        #expect(positions["s1"] == .song(1))
        #expect(positions["s3"] == .song(2), "two songs in this fixture: the closing song is the next one")
        #expect(positions["cd"] == .countdown)
        #expect(positions["m"] == .message)
        #expect(positions["g"] == .walkIn && positions["b"] == .walkIn)
        // No slideshow yet: hang time waits for it.
        #expect(shaped.service.items.first { $0.id == "ht" }?.refId == "")
    }

    @Test func whatWasChosenInScreensStays() {
        var plan = wednesday
        plan.items = plan.items.map { item in
            var item = item
            if item.id == "g" { item.itemKind = .presentation; item.refId = "my-game" }
            if item.id == "b" { item.lightingCue = "announcements" }
            return item
        }
        let shaped = StudentsNight.shaping(plan, planID: "p1", hangTimeID: nil)
        let items = Dictionary(uniqueKeysWithValues: (shaped?.service.items ?? []).map { ($0.id, $0) })
        #expect(items["g"]?.refId == "my-game" && items["g"]?.lightingCue == nil)
        #expect(items["b"]?.refId == "shepherd-p1-breakout" && items["b"]?.lightingCue == "announcements")
        #expect(StudentsNight.presentationIDs(planID: "p1") == ["shepherd-p1-game", "shepherd-message-p1", "shepherd-p1-breakout"])
    }
}
