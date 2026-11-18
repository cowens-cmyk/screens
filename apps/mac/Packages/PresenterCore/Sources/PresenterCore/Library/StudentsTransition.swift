import Foundation

/// Hope Students' own Transition: the presentation a Wednesday Night plan's
/// Transition item plays before the message, so the students' sermon bumper
/// can go on it without touching Sunday's.
///
/// It starts as a copy of Sunday's Transition (its slides, cues and
/// settings), made once; from then on the two are separate. The Message
/// lights and timer come from the plan item being the Transition
/// (`ServiceItem.isTransition`), so they run the same on both nights.
///
/// There is one for the whole library, with a fixed id, so two Macs that
/// make it at once make one.
public enum StudentsTransition {
    public static let presentationID = "students-transition"
    public static let presentationName = "Hope Students Transition"

    /// The presentation in the library: the one with the fixed id, else one
    /// with its name.
    public static func find(ids: [(id: String, name: String)]) -> String? {
        if ids.contains(where: { $0.id == presentationID }) { return presentationID }
        return ids.filter { letters($0.name) == letters(presentationName) }.map(\.id).sorted().first
    }

    /// The students' copy of Sunday's Transition, or an empty Transition
    /// when there's no Sunday one to copy.
    public static func copy(of sunday: Presentation?) -> Presentation {
        var deck = sunday ?? SharedPlanItems.newPresentation(.transition)
        deck.id = presentationID
        deck.name = presentationName
        return deck
    }

    /// The plan with its Transition item played from the students'
    /// presentation; nil when nothing changes. Only an item linked to
    /// Sunday's Transition, or to nothing, is moved: one linked to anything
    /// else was chosen by hand and stays.
    public static func relinking(_ service: Service, sundayID: String?, studentsID: String) -> Service? {
        var plan = service
        for index in plan.items.indices where plan.items[index].isTransition == true {
            let current = plan.items[index].refId
            guard current != studentsID, current.isEmpty || current == sundayID else { continue }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = studentsID
        }
        return plan == service ? nil : plan
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }
}
