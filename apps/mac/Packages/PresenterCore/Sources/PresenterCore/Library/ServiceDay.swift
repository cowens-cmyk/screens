import Foundation

/// Between services the last slide of the one before is often left up while
/// the operator steps away. The Service Day setup names the service times and
/// the pre-service slideshow, and keeps one weekly scheduler trigger per
/// service that starts the slideshow again a little before it.
///
/// The settings live in the team's slide-building settings document so every
/// computer sees the same Sunday; the triggers they make are ordinary
/// scheduler triggers, marked in their notes so saving the setup again
/// replaces them rather than adding more.
public enum ServiceDay {
    /// The board folder the restart triggers are grouped in, on every
    /// computer (the board itself is per computer).
    public static let folderID = "service-day"
    public static let folderName = "Service Day"
    /// Marks a restart trigger, followed by the id of its service time.
    public static let triggerNotePrefix = "preservice:"

    public static let defaultDays = [1]
    public static let defaultServiceTimes = ["08:00", "09:30", "11:15"]
    /// The first service has nothing before it, so its slides can start
    /// earlier; later ones start about when the service before is out.
    public static let firstServiceLeadMinutes = 30
    public static let laterServiceLeadMinutes = 25
    /// Seconds per slide when the slideshow has no timing of its own.
    public static let slideSeconds: Double = 10

    // MARK: Times of day

    /// "08:00" or "08:00:30" as seconds after midnight.
    public static func secondsOfDay(_ raw: String) -> Int? {
        ScheduleMath.parseTimeOfDay(raw).map { $0.hour * 3600 + $0.minute * 60 + $0.second }
    }

    /// Seconds after midnight as "08:00" (or "08:00:30"), wrapping past
    /// midnight either way.
    public static func timeString(secondsOfDay: Int) -> String {
        let day = 24 * 3600
        let value = ((secondsOfDay % day) + day) % day
        let base = String(format: "%02d:%02d", value / 3600, value % 3600 / 60)
        return value % 60 == 0 ? base : base + String(format: ":%02d", value % 60)
    }

    /// "08:00" as "8:00 AM", for names and captions.
    public static func displayTime(_ raw: String) -> String {
        guard let seconds = secondsOfDay(raw) else { return raw }
        let hour = seconds / 3600
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        var text = String(format: "%d:%02d", twelve, seconds % 3600 / 60)
        if seconds % 60 != 0 { text += String(format: ":%02d", seconds % 60) }
        return text + (hour < 12 ? " AM" : " PM")
    }

    /// When the slides start again before a service, prefilled.
    public static func restartTime(forService serviceTime: String, isFirst: Bool) -> String {
        let lead = (isFirst ? firstServiceLeadMinutes : laterServiceLeadMinutes) * 60
        return timeString(secondsOfDay: (secondsOfDay(serviceTime) ?? 0) - lead)
    }

    // MARK: Settings

    /// Sunday at 8:00, 9:30 and 11:15, each with its restart prefilled.
    public static func defaultSettings(
        preServicePresentationId: String?, makeID: () -> String = { UUID().uuidString }
    ) -> ServiceDaySettings {
        let services = defaultServiceTimes.enumerated().map { index, time in
            ServiceDayTime(id: makeID(), serviceTime: time, restartTime: restartTime(forService: time, isFirst: index == 0))
        }
        return ServiceDaySettings(
            services: services, days: defaultDays,
            preServicePresentationId: preServicePresentationId, clearFirst: true)
    }

    /// Another service an hour and three quarters after the last one.
    public static func nextService(
        after services: [ServiceDayTime], makeID: () -> String = { UUID().uuidString }
    ) -> ServiceDayTime {
        let last = sorted(services).last.flatMap { secondsOfDay($0.serviceTime) }
        let time = timeString(secondsOfDay: last.map { $0 + 105 * 60 } ?? 10 * 3600)
        return ServiceDayTime(id: makeID(), serviceTime: time, restartTime: restartTime(forService: time, isFirst: last == nil))
    }

    public static func sorted(_ services: [ServiceDayTime]) -> [ServiceDayTime] {
        services.sorted { (secondsOfDay($0.serviceTime) ?? 0, $0.id) < (secondsOfDay($1.serviceTime) ?? 0, $1.id) }
    }

    public static func days(_ settings: ServiceDaySettings) -> [Int] {
        let days = (settings.days ?? defaultDays).filter { (1 ... 7).contains($0) }
        return days.isEmpty ? defaultDays : Array(Set(days)).sorted()
    }

    public static func clearsFirst(_ settings: ServiceDaySettings) -> Bool {
        settings.clearFirst ?? true
    }

    // MARK: The pre-service slideshow

    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let name: String
        public let autoAdvances: Bool

        public init(id: String, name: String, autoAdvances: Bool) {
            self.id = id
            self.name = name
            self.autoAdvances = autoAdvances
        }
    }

    /// "Pre-Service", "Pre Service", "PreService Loop" and the like.
    public static func looksLikePreService(_ name: String) -> Bool {
        name.lowercased().filter { $0.isLetter }.contains("preservice")
    }

    /// The slideshow to suggest: one named like pre-service, one that
    /// already advances by itself first, then the shortest name (the plain
    /// "Pre-Service" over "Pre-Service Old").
    public static func suggestedPresentation(_ candidates: [Candidate]) -> String? {
        candidates
            .filter { looksLikePreService($0.name) }
            .min { a, b in
                (a.autoAdvances ? 0 : 1, a.name.count, a.name, a.id) < (b.autoAdvances ? 0 : 1, b.name.count, b.name, b.id)
            }?.id
    }

    /// The timing that makes a slideshow advance by itself and loop: nil
    /// when it already does. Its own delay is kept; without one, ten seconds.
    public static func loopingAdvance(_ current: AutoAdvance?) -> AutoAdvance? {
        if let current, current.loopToStart == true, current.delaySeconds > 0 { return nil }
        let delay = (current?.delaySeconds ?? 0) > 0 ? current!.delaySeconds : slideSeconds
        return AutoAdvance(delaySeconds: delay, loopToStart: true, afterPlayback: current?.afterPlayback)
    }

    // MARK: Triggers

    public static func isRestartTrigger(_ trigger: ScheduleTrigger) -> Bool {
        trigger.notes?.hasPrefix(triggerNotePrefix) == true
    }

    /// The service time a restart trigger belongs to.
    public static func serviceID(of trigger: ScheduleTrigger) -> String? {
        guard isRestartTrigger(trigger), let notes = trigger.notes else { return nil }
        return String(notes.dropFirst(triggerNotePrefix.count))
    }

    /// One weekly trigger per service: clear (when chosen), then the
    /// slideshow from its first slide. Nothing without a slideshow.
    public static func triggers(
        for settings: ServiceDaySettings, makeID: () -> String = { UUID().uuidString }
    ) -> [ScheduleTrigger] {
        guard let presentationID = settings.preServicePresentationId, !presentationID.isEmpty else { return [] }
        let days = days(settings)
        return sorted(settings.services).compactMap { service in
            guard secondsOfDay(service.serviceTime) != nil, secondsOfDay(service.restartTime) != nil else { return nil }
            let id = makeID()
            // Ids inside the trigger follow the service, so saving the same
            // setup again changes nothing.
            let condition = ScheduleCondition(
                id: "\(service.id)-when", kind: .weekly, days: days, timeOfDay: service.restartTime)
            var actions: [SlideAction] = []
            if clearsFirst(settings) {
                actions.append(SlideAction(id: "\(service.id)-clear", kind: .clearAll))
            }
            actions.append(SlideAction(
                id: "\(service.id)-slides", kind: .firePresentation,
                presentationId: presentationID, slideIndex: 0))
            return ScheduleTrigger(
                id: id, name: "Pre-Service for \(displayTime(service.serviceTime))",
                conditions: [condition], actions: actions, enabled: true,
                notes: triggerNotePrefix + service.id)
        }
    }

    /// What saving the setup does to the scheduler: new services get new
    /// triggers, changed ones are rewritten in place (their on/off and
    /// snooze kept), and services that are gone lose theirs.
    public struct Changes: Equatable, Sendable {
        public var creates: [ScheduleTrigger] = []
        public var updates: [ScheduleTrigger] = []
        public var deletes: [String] = []

        public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && deletes.isEmpty }
    }

    public static func changes(
        from existing: [ScheduleTrigger], to settings: ServiceDaySettings,
        makeID: () -> String = { UUID().uuidString }
    ) -> Changes {
        let current = existing.filter(isRestartTrigger)
        var changes = Changes()
        var kept = Set<String>()
        for fresh in triggers(for: settings, makeID: { "" }) {
            let match = current.first { $0.notes == fresh.notes && !kept.contains($0.id) }
            guard let match else {
                var made = fresh
                made.id = makeID()
                changes.creates.append(made)
                continue
            }
            kept.insert(match.id)
            var updated = match
            applyManagedFields(of: fresh, to: &updated)
            if updated != match { changes.updates.append(updated) }
        }
        changes.deletes = current.map(\.id).filter { !kept.contains($0) }
        return changes
    }

    /// The parts of a restart trigger the setup owns.
    public static func applyManagedFields(of fresh: ScheduleTrigger, to trigger: inout ScheduleTrigger) {
        trigger.name = fresh.name
        trigger.conditions = fresh.conditions
        trigger.actions = fresh.actions
        trigger.notes = fresh.notes
        trigger.conditionLogic = nil
        trigger.archived = nil
    }

    /// The restart triggers in the order they fire in a day.
    public static func restartTriggerIDs(_ triggers: [ScheduleTrigger]) -> [String] {
        triggers
            .filter { isRestartTrigger($0) && $0.archived != true }
            .sorted { a, b in
                (restartSeconds(a) ?? 0, a.name, a.id) < (restartSeconds(b) ?? 0, b.name, b.id)
            }
            .map(\.id)
    }

    private static func restartSeconds(_ trigger: ScheduleTrigger) -> Int? {
        trigger.conditions.first { $0.kind == .weekly }?.timeOfDay.flatMap(secondsOfDay)
    }

    // MARK: The day at a glance

    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case preService
            case countdown
            case service
        }

        public let kind: Kind
        public let date: Date

        public init(kind: Kind, date: Date) {
            self.kind = kind
            self.date = date
        }
    }

    /// The next service day still to come (today, if a service is still
    /// ahead), from now on: each restart, each scheduled countdown that day,
    /// and each service, in time order.
    public static func upcomingDay(
        _ settings: ServiceDaySettings, countdownStarts: [Date],
        after now: Date, calendar: Calendar
    ) -> (day: Date, events: [Event])? {
        let services = sorted(settings.services)
        guard !services.isEmpty else { return nil }
        let days = Set(days(settings))
        let restarts = settings.preServicePresentationId?.isEmpty == false
        let today = calendar.startOfDay(for: now)
        for offset in 0 ... 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendar.component(.weekday, from: day))
            else { continue }
            func at(_ raw: String) -> Date? {
                guard let seconds = secondsOfDay(raw) else { return nil }
                return calendar.date(
                    bySettingHour: seconds / 3600, minute: seconds % 3600 / 60, second: seconds % 60, of: day)
            }
            var events: [Event] = []
            for service in services {
                if let date = at(service.serviceTime) { events.append(Event(kind: .service, date: date)) }
                if restarts, let date = at(service.restartTime) { events.append(Event(kind: .preService, date: date)) }
            }
            events += countdownStarts
                .filter { calendar.isDate($0, inSameDayAs: day) }
                .map { Event(kind: .countdown, date: $0) }
            events = events.filter { $0.date >= now }
            guard events.contains(where: { $0.kind == .service }) else { continue }
            let order: [Event.Kind: Int] = [.preService: 0, .countdown: 1, .service: 2]
            return (day, events.sorted { ($0.date, order[$0.kind]!) < ($1.date, order[$1.kind]!) })
        }
        return nil
    }
}

public extension SchedulerBoard {
    /// The restart triggers together in the Service Day folder, first on
    /// the board. Anything else put in the folder stays after them. Nil when
    /// they're already there, so the scheduler only writes when it must.
    func placingServiceDay(triggerIDs: [String]) -> SchedulerBoard? {
        guard !triggerIDs.isEmpty else { return nil }
        var board = self
        let managed = Set(triggerIDs)
        if board.folder(id: ServiceDay.folderID) == nil {
            board.folders.append(ScheduleFolder(id: ServiceDay.folderID, name: ServiceDay.folderName, triggerIds: []))
            board.nodes.insert(ServiceDay.folderID, at: 0)
        }
        board.nodes.removeAll { managed.contains($0) }
        for index in board.folders.indices {
            if board.folders[index].id == ServiceDay.folderID {
                let others = board.folders[index].triggerIds.filter { !managed.contains($0) }
                board.folders[index].triggerIds = triggerIDs + others
            } else {
                board.folders[index].triggerIds.removeAll { managed.contains($0) }
            }
        }
        return board == self ? nil : board
    }
}

/// Whether a scheduled pre-service restart may take the screens. Between
/// services the screens hold the last service's final slide, the slideshow,
/// or nothing; anything else that changed in the last few minutes means
/// someone is presenting (a service running long), and is left alone. So is
/// a video or the countdown playing, and the message with its timer running.
public enum PreServiceGuard {
    public static let quietSeconds: TimeInterval = 180

    public struct Situation: Equatable, Sendable {
        /// Since the live slide went up; nil with no slide up.
        public var secondsSinceSlideChange: TimeInterval?
        public var preServiceIsUp = false
        /// The last slide of the plan's last presentation.
        public var finalSlideIsUp = false
        public var messageIsUp = false
        public var sermonTimerRunning = false
        public var videoPlaying = false
        public var countdownPlaying = false

        public init(
            secondsSinceSlideChange: TimeInterval? = nil, preServiceIsUp: Bool = false,
            finalSlideIsUp: Bool = false, messageIsUp: Bool = false, sermonTimerRunning: Bool = false,
            videoPlaying: Bool = false, countdownPlaying: Bool = false
        ) {
            self.secondsSinceSlideChange = secondsSinceSlideChange
            self.preServiceIsUp = preServiceIsUp
            self.finalSlideIsUp = finalSlideIsUp
            self.messageIsUp = messageIsUp
            self.sermonTimerRunning = sermonTimerRunning
            self.videoPlaying = videoPlaying
            self.countdownPlaying = countdownPlaying
        }
    }

    public enum Decision: Equatable, Sendable {
        case restart
        /// Left alone, with why, for the scheduler's history.
        case skip(String)
    }

    public static func decide(_ situation: Situation) -> Decision {
        if situation.countdownPlaying { return .skip("The countdown was playing.") }
        if situation.videoPlaying { return .skip("A video was playing.") }
        if situation.messageIsUp, situation.sermonTimerRunning, !situation.finalSlideIsUp {
            return .skip("The message was up with its timer running.")
        }
        guard let age = situation.secondsSinceSlideChange else { return .restart }
        let recent = age < quietSeconds
        if situation.preServiceIsUp {
            // Still advancing: it's running already. Stuck: start it over.
            return recent ? .skip("The pre-service slides were already running.") : .restart
        }
        if recent, !situation.finalSlideIsUp {
            return .skip("A slide changed in the last 3 minutes.")
        }
        return .restart
    }
}
