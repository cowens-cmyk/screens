import Foundation

/// How a Hope Students night (a Wednesday Night plan from Shepherd) runs,
/// filled in on the plan so the booth only has to press go:
///
/// - **Students Hang Time**: the Students Hang Time slideshow, Walk-in
///   lights, full screen on the livestream.
/// - **Countdown**: the countdown item already there (Choose Video, or drop
///   one on it); the Countdown lights and full screen come with it, and it
///   goes on to the game when it ends.
/// - **Game**: an empty presentation of its own, to drop the game's slides
///   on; Walk-in lights, transparent on the livestream.
/// - **Songs**: Song 1, Song 2 and the closing song Song 3, as the lights
///   number them by themselves.
/// - **Message**: the bumper (the Transition, full screen) and then an empty
///   Message for the notes, with a 30-minute timer, transparent on the
///   livestream.
/// - **Breakout Groups**: an empty presentation of its own; Walk-in lights,
///   full screen on the livestream.
///
/// Only an item with nothing linked is filled in, and its lights and
/// livestream are set as it is linked, so anything chosen in Screens since
/// stays. The presentations made for a plan have fixed ids from the
/// Shepherd plan, so two Macs make one, and they go when the plan does.
public enum StudentsNight {
    /// The Wednesday night message runs 30 minutes.
    public static let messageSeconds: Double = 30 * 60

    public enum Role: Equatable, Sendable {
        case hangTime, game, message, breakout
    }

    /// What a plan item is for, by its name: "Students Hang Time", "Game
    /// TBD", "Message", "Breakout Groups". Headers and songs are none.
    public static func role(of item: ServiceItem) -> Role? {
        guard item.itemKind != .header, item.mxuSongTitle == nil, item.isCountdown != true,
              item.isTransition != true, item.isWalkout != true, item.isPreService != true
        else { return nil }
        let name = letters(item.name)
        if name.contains("hangtime") { return .hangTime }
        if name.contains("breakout") { return .breakout }
        if name.contains("game") { return .game }
        if name.contains("message") || name.contains("sermon") { return .message }
        return nil
    }

    /// The presentation made for a role in one Shepherd plan.
    public static func presentationID(_ role: Role, planID: String) -> String? {
        let plan = planID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        switch role {
        case .hangTime: return nil
        case .game: return "shepherd-\(plan)-game"
        case .message: return "shepherd-message-\(plan)"
        case .breakout: return "shepherd-\(plan)-breakout"
        }
    }

    /// Every presentation made for a plan, for when the plan goes.
    public static func presentationIDs(planID: String) -> [String] {
        [Role.game, .message, .breakout].compactMap { presentationID($0, planID: planID) }
    }

    /// An empty presentation for a role, ready for slides to be dropped on.
    public static func newPresentation(_ role: Role, planID: String, sermonThemeId: String? = nil) -> Presentation? {
        guard let id = presentationID(role, planID: planID) else { return nil }
        switch role {
        case .message:
            var message = Presentation(
                id: id, name: "Message", presentationKind: .deck,
                themeId: sermonThemeId ?? BasicTemplates.pointsThemeID, slides: [])
            message.category = PresentationTypes.sermon
            message.sermonTimerSeconds = messageSeconds
            return message
        case .game:
            return Presentation(id: id, name: "Game", presentationKind: .deck, themeId: "", slides: [])
        case .breakout:
            return Presentation(id: id, name: "Breakout Groups", presentationKind: .deck, themeId: "", slides: [])
        case .hangTime:
            return nil
        }
    }

    /// The lights and livestream a role's item gets as it's linked.
    static func look(_ role: Role) -> (cue: String?, stream: String?) {
        switch role {
        case .hangTime: (ServicePosition.walkIn.key, "fullScreen")
        case .game: (ServicePosition.walkIn.key, "off")
        case .breakout: (ServicePosition.walkIn.key, "fullScreen")
        // The Message lights come from its header. The bumper before it is
        // full screen by itself, being a video; the message is transparent,
        // the camera on the livestream.
        case .message: (nil, "off")
        }
    }

    public struct Shaping: Equatable, Sendable {
        public var service: Service
        /// Presentations to make before the plan is written.
        public var presentations: [Presentation]
    }

    /// The plan with its night filled in, or nil when there's nothing to do.
    /// `hangTimeID` is the Students Hang Time slideshow, nil until there is
    /// one.
    public static func shaping(_ service: Service, planID: String, hangTimeID: String?) -> Shaping? {
        var plan = service
        var made: [Presentation] = []
        for index in plan.items.indices {
            guard let role = role(of: plan.items[index]), plan.items[index].refId.isEmpty else { continue }
            let link: String
            if role == .hangTime {
                guard let hangTimeID, !hangTimeID.isEmpty else { continue }
                link = hangTimeID
            } else {
                guard let deck = newPresentation(role, planID: planID, sermonThemeId: service.sermonThemeId) else { continue }
                link = deck.id
                made.append(deck)
            }
            var item = plan.items[index]
            item.itemKind = .presentation
            item.refId = link
            let look = look(role)
            if item.lightingCue == nil, let cue = look.cue { item.lightingCue = cue }
            if let stream = look.stream, !(item.actions ?? []).contains(where: { $0.kind == .setStreamMode }) {
                item.actions = (item.actions ?? []) + [
                    SlideAction(id: "students-stream-" + item.id, kind: .setStreamMode, streamMode: stream),
                ]
            }
            plan.items[index] = item
            if role == .message {
                if plan.messagePresentationId?.isEmpty ?? true { plan.messagePresentationId = link }
                // The bumper goes in before the message (StandingItems), as on
                // a Sunday: Wednesday plans were made with it taken out.
                if StandingItems.transition(in: plan) == nil { plan.transitionRemoved = nil }
            }
        }
        return plan == service ? nil : Shaping(service: plan, presentations: made)
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }
}
