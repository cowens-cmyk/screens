import Foundation
import Testing
@testable import PresenterCore

@Suite struct ShepherdTemplatePlanTests {

    private func header(_ name: String) -> ServiceItem {
        ServiceItem(id: "h-" + name, itemKind: .header, name: name, refId: "")
    }

    private func deck(_ name: String) -> ServiceItem {
        ServiceItem(id: "d-" + name, itemKind: .presentation, name: name, refId: "ref-" + name)
    }

    private func synced(_ name: String) -> ServiceItem {
        var item = ServiceItem(id: "s-" + name, itemKind: .presentation, name: name, refId: "song-" + name)
        item.mxuSourceItemId = "shepherd-" + name
        item.mxuKind = "song"
        return item
    }

    /// The Hope Students template as it is in Screens.
    private var hopeStudents: [ServiceItem] {
        [header("Pre Service"), deck("Hope Students Announcements"), header("Countdown"), deck("Hope Students Countdown"),
         header("Game"), deck("Game of the week"), header("Worship"), deck("Tear Off The Roof"),
         deck("The Lord Will Provide"), header("Sermon"), deck("Students Message"), header("Closing Song"),
         deck("Goodness of God"), header("Breakout Groups"), deck("Breakout Groups")]
    }

    private let placeholders: Set<String> = ["Tear Off The Roof", "The Lord Will Provide", "Goodness of God"]

    @Test func shepherdsSongsTakeThePlaceholdersPlacesByHeader() {
        let songs = [
            ShepherdTemplatePlan.Song(header: "6:55 PM - WORSHIP", item: synced("Come To Jesus")),
            ShepherdTemplatePlan.Song(header: "6:55 PM - WORSHIP", item: synced("The Lord Is With Me")),
            ShepherdTemplatePlan.Song(header: "7:40 PM - CLOSING SONG", item: synced("Gratitude")),
        ]
        let items = ShepherdTemplatePlan.laying(songs, over: hopeStudents) { placeholders.contains($0.name) }
        #expect(items.map(\.name) == [
            "Pre Service", "Hope Students Announcements", "Countdown", "Hope Students Countdown", "Game",
            "Game of the week", "Worship", "Come To Jesus", "The Lord Is With Me", "Sermon", "Students Message",
            "Closing Song", "Gratitude", "Breakout Groups", "Breakout Groups",
        ])
    }

    @Test func songsUnderOtherHeadersGoWhereThePlaceholdersWere() {
        let songs = [
            ShepherdTemplatePlan.Song(header: "SET ONE", item: synced("A")),
            ShepherdTemplatePlan.Song(header: "SET ONE", item: synced("B")),
            ShepherdTemplatePlan.Song(header: "END", item: synced("C")),
            ShepherdTemplatePlan.Song(header: "EXTRA", item: synced("D")),
        ]
        let items = ShepherdTemplatePlan.laying(songs, over: hopeStudents) { placeholders.contains($0.name) }
        let names = items.map(\.name)
        #expect(names[6...8] == ["Worship", "A", "B"])
        #expect(names[11...14] == ["Closing Song", "C", "D", "Breakout Groups"])
    }

    @Test func aPlanWithNoSongsYetHasEmptySongHeaders() {
        let items = ShepherdTemplatePlan.laying([], over: hopeStudents) { placeholders.contains($0.name) }
        #expect(!items.contains { placeholders.contains($0.name) })
        #expect(items.count == hopeStudents.count - 3)
    }

    @Test func anUpdateReplacesSyncedSongsAndKeepsWhatWasAddedHere() {
        var plan = ShepherdTemplatePlan.laying(
            [ShepherdTemplatePlan.Song(header: "6:55 PM - WORSHIP", item: synced("Come To Jesus")),
             ShepherdTemplatePlan.Song(header: "7:40 PM - CLOSING SONG", item: synced("Gratitude"))],
            over: hopeStudents) { placeholders.contains($0.name) }
        // Added by the operator after the message.
        plan.insert(deck("Response Video"), at: plan.firstIndex { $0.name == "Students Message" }! + 1)

        let updated = ShepherdTemplatePlan.laying(
            [ShepherdTemplatePlan.Song(header: "6:55 PM - WORSHIP", item: synced("Come To Jesus")),
             ShepherdTemplatePlan.Song(header: "6:55 PM - WORSHIP", item: synced("Holy Forever")),
             ShepherdTemplatePlan.Song(header: "7:40 PM - CLOSING SONG", item: synced("Gratitude"))],
            over: plan) { $0.mxuSourceItemId != nil }
        #expect(updated.map(\.name) == [
            "Pre Service", "Hope Students Announcements", "Countdown", "Hope Students Countdown", "Game",
            "Game of the week", "Worship", "Come To Jesus", "Holy Forever", "Sermon", "Students Message",
            "Response Video", "Closing Song", "Gratitude", "Breakout Groups", "Breakout Groups",
        ])
    }

    @Test func headersMatchWithoutTheirTimes() {
        #expect(ShepherdTemplatePlan.sameHeader("6:55 PM - WORSHIP", "Worship"))
        #expect(ShepherdTemplatePlan.sameHeader("7:40 PM - CLOSING SONG", "Closing Song"))
        #expect(ShepherdTemplatePlan.sameHeader("7:50pm: Breakout Groups", "BREAKOUT GROUPS"))
        #expect(!ShepherdTemplatePlan.sameHeader("7:15 PM - MESSAGE", "Sermon"))
        #expect(!ShepherdTemplatePlan.sameHeader("6:00 PM", "Game"))
    }

    @Test func theTemplateIsTheChosenOneElseOneNamedForTheTypeOrStudents() {
        func template(_ id: String, _ name: String, type: String? = nil) -> Service {
            var service = Service(id: id, name: name, serviceDate: "", items: [], mxuServiceTypeName: type)
            service.isTemplate = true
            return service
        }
        let sunday = template("sun", "Sunday Morning Template", type: "Sunday Morning")
        let students = template("stu", "Hope Students Template")
        let plain = Service(id: "plan", name: "Wednesday Night", serviceDate: "2026-11-18", items: [])
        let all = [sunday, students, plain]
        #expect(ShepherdTemplatePlan.template(for: "Wednesday Night", chosenID: nil, in: all)?.id == "stu")
        #expect(ShepherdTemplatePlan.template(for: "Wednesday Night", chosenID: "sun", in: all)?.id == "sun")
        #expect(ShepherdTemplatePlan.template(for: "Wednesday Night", chosenID: "gone", in: all)?.id == "stu")
        let named = template("wed", "Wednesday Night Template")
        #expect(ShepherdTemplatePlan.template(for: "Wednesday Night", chosenID: nil, in: all + [named])?.id == "wed")
        #expect(ShepherdTemplatePlan.template(for: "", chosenID: nil, in: all) == nil)
        #expect(ShepherdTemplatePlan.template(for: "Wednesday Night", chosenID: nil, in: [sunday, plain]) == nil)
    }
}

@Suite struct PlanBrandTests {
    @Test func studentsLogoForWednesdayNightAndStudentsPlansHopeForTheRest() {
        let wednesday = Service(id: "w", name: "2026-11-18 — Youth", serviceDate: "2026-11-18", items: [],
                                mxuServiceTypeName: "Wednesday Night")
        var template = Service(id: "t", name: "Hope Students Template", serviceDate: "", items: [])
        template.isTemplate = true
        let sunday = Service(id: "s", name: "2026-11-22 — Genesis 42-45", serviceDate: "2026-11-22", items: [],
                             mxuServiceTypeName: "Sunday Morning")
        #expect(PlanBrand.of(wednesday, midweekServiceType: "wednesday night ") == .students)
        #expect(PlanBrand.of(template, midweekServiceType: "Wednesday Night") == .students)
        #expect(PlanBrand.of(sunday, midweekServiceType: "Wednesday Night") == .hope)
        #expect(PlanBrand.of(wednesday, midweekServiceType: "") == .hope)
        // Made by hand: Hope, whatever it's called.
        let manual = Service(id: "m", name: "Hope Students Lock-In", serviceDate: "2026-12-04", items: [])
        #expect(PlanBrand.of(manual, midweekServiceType: "Wednesday Night") == .hope)
    }
}
