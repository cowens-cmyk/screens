import Foundation
import Testing
@testable import PresenterCore

@Test func theStudentsTransitionStartsAsACopyOfSundays() {
    var sunday = Presentation(id: "sun-transition", name: "Transition", presentationKind: .deck, themeId: "t", slides: [
        Slide(id: "bumper", name: "Bumper", objects: []),
    ])
    sunday.category = "Transition"
    let copy = StudentsTransition.copy(of: sunday)
    #expect(copy.id == StudentsTransition.presentationID)
    #expect(copy.name == "Hope Students Transition")
    #expect(copy.slides.map(\.id) == ["bumper"])
    #expect(copy.category == sunday.category)
    let empty = StudentsTransition.copy(of: nil)
    #expect(empty.id == StudentsTransition.presentationID)
    #expect(empty.slides.isEmpty)
}

@Test func theStudentsTransitionIsFoundByIdThenName() {
    #expect(StudentsTransition.find(ids: [("x", "Transition")]) == nil)
    #expect(StudentsTransition.find(ids: [("x", "hope students transition")]) == "x")
    #expect(StudentsTransition.find(ids: [("x", "Hope Students Transition"), (StudentsTransition.presentationID, "Renamed")])
        == StudentsTransition.presentationID)
}

@Test func onlyATransitionOnSundaysOrNothingMoves() {
    var plan = Service(id: "wed", name: "Wednesday", serviceDate: "2026-11-25", items: [])
    var sundays = ServiceItem(id: "t", itemKind: .presentation, name: "Transition", refId: "sun")
    sundays.isTransition = true
    let message = ServiceItem(id: "m", itemKind: .presentation, name: "Message", refId: "msg")
    plan.items = [sundays, message]
    let moved = StudentsTransition.relinking(plan, sundayID: "sun", studentsID: "stu")
    #expect(moved?.items[0].refId == "stu")
    #expect(moved?.items[1].refId == "msg", "the message stays")
    #expect(StudentsTransition.relinking(moved!, sundayID: "sun", studentsID: "stu") == nil, "once")
    plan.items[0].refId = "chosen-by-hand"
    #expect(StudentsTransition.relinking(plan, sundayID: "sun", studentsID: "stu") == nil)
    plan.items[0].refId = ""
    #expect(StudentsTransition.relinking(plan, sundayID: "sun", studentsID: "stu")?.items[0].refId == "stu")
}
