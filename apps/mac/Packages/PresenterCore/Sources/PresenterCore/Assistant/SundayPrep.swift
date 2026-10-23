import Foundation

/// The decisions behind the Assistant's Build Sunday job: which plan is
/// next, which countdown video to suggest, and when the services are. The
/// app gathers the facts; these choose, so the choices can be tested.
public enum SundayPrep {

    /// The plan to get ready: the soonest upcoming plan from Shepherd when
    /// there is one (that's the Sunday service; a plan made in Screens for a
    /// midweek event shouldn't jump ahead of it), else the soonest upcoming
    /// plan. Today's plan counts as upcoming all day.
    public static func nextPlan(_ plans: [Service], today: String) -> Service? {
        let upcoming = plans
            .filter { $0.isTemplate != true && String($0.serviceDate.prefix(10)) >= today }
            .sorted { ($0.serviceDate, $0.name, $0.id) < ($1.serviceDate, $1.name, $1.id) }
        return upcoming.first { $0.origin == ShepherdPlanSync.origin } ?? upcoming.first
    }

    /// Planned songs with no slides yet: Shepherd sync leaves them as info
    /// items with the song's details until a presentation is linked.
    public static func songsWithoutSlides(in plan: Service) -> [ServiceItem] {
        plan.items.filter { $0.itemKind == .info && $0.refId.isEmpty && $0.mxuSongTitle != nil }
    }

    /// Planned songs that have slides: the ones whose words can be checked.
    public static func songsWithSlides(in plan: Service) -> [ServiceItem] {
        plan.items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty && $0.mxuSongTitle != nil }
    }

    // MARK: Countdown

    public struct Video: Equatable, Sendable {
        public var id: String
        public var name: String
        public var folder: String?
        /// When it was added or last changed; newest first.
        public var added: Date
        public var seconds: Double?

        public init(id: String, name: String, folder: String?, added: Date, seconds: Double? = nil) {
            self.id = id
            self.name = name
            self.folder = folder
            self.added = added
            self.seconds = seconds
        }
    }

    /// The countdown videos the plans in the week before this one played.
    public static func countdownsUsedLastWeek(before plan: Service, among plans: [Service]) -> Set<String> {
        let day = String(plan.serviceDate.prefix(10))
        let start = DayStamp.adding(-7, to: day)
        return Set(plans.compactMap { other -> String? in
            let date = String(other.serviceDate.prefix(10))
            guard other.id != plan.id, other.isTemplate != true, date >= start, date < day,
                  let item = ServiceCountdown.item(in: other), !item.refId.isEmpty
            else { return nil }
            return item.refId
        })
    }

    /// This week's countdown: the newest video in Media › Countdowns that
    /// last week's plans didn't use. Nil when every one was used or there
    /// are none.
    public static func suggestedCountdown(_ videos: [Video], for plan: Service, among plans: [Service]) -> Video? {
        let used = countdownsUsedLastWeek(before: plan, among: plans)
        return videos
            .filter { ServiceCountdown.isCountdownFolder($0.folder) && !used.contains($0.id) }
            .sorted { ($0.added, $1.name) > ($1.added, $0.name) }
            .first
    }

    // MARK: Service times

    public enum TimesSource: String, Sendable {
        case serviceDay = "service_day"
        case shepherd
    }

    /// Times to propose for Schedule Service, as local "yyyy-MM-ddTHH:mm"
    /// (what schedule_service takes): the Service Day times on the plan's
    /// date, else Shepherd's service times for the plan. Times already past
    /// are left out.
    public static func proposedServiceTimes(
        planDate: String, serviceDay: ServiceDaySettings?, shepherdTimes: [MxUPlanTime] = [],
        now: Date, calendar: Calendar = .current
    ) -> (times: [String], source: TimesSource?) {
        let day = String(planDate.prefix(10))
        guard let parts = DayStamp.parts(day) else { return ([], nil) }
        if let serviceDay, !serviceDay.services.isEmpty {
            let times = ServiceDay.sorted(serviceDay.services).compactMap { service -> String? in
                guard let seconds = ServiceDay.secondsOfDay(service.serviceTime),
                      let date = calendar.date(from: DateComponents(
                          year: parts.year, month: parts.month, day: parts.day,
                          hour: seconds / 3600, minute: seconds % 3600 / 60)),
                      date > now
                else { return nil }
                return stamp(date, calendar: calendar)
            }
            return (times, .serviceDay)
        }
        let formatter = ISO8601DateFormatter()
        let planned = shepherdTimes
            .filter { $0.isRehearsal != true }
            .compactMap { $0.startsAt.flatMap(formatter.date(from:)) }
            .filter { $0 > now }
            .sorted()
        guard !planned.isEmpty else { return ([], nil) }
        return (planned.map { stamp($0, calendar: calendar) }, .shepherd)
    }

    static func stamp(_ date: Date, calendar: Calendar) -> String {
        String(ServiceCountdown.localStamp(date, calendar: calendar).prefix(16))
    }
}

/// Finding a planned or library song in Shepherd's song list.
public enum ShepherdSongMatch {
    /// By CCLI number first, then by title; never an archived song. `search`
    /// is Shepherd's song search (title, author or CCLI number).
    public static func find(
        ccli: String?, title: String,
        search: @Sendable (String) async throws -> [ShepherdClient.SongSummary]
    ) async throws -> ShepherdClient.SongSummary? {
        let number = ccli?.trimmingCharacters(in: .whitespaces).filter(\.isNumber) ?? ""
        if !number.isEmpty {
            let found = try await search(number).filter { $0.archived != true }
            if let match = found.first(where: { $0.ccliNumber?.filter(\.isNumber) == number }) { return match }
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let found = try await search(name).filter { $0.archived != true }
        return found.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            ?? found.first { sameTitle($0.title, name) }
    }

    /// "It Is Well (With My Soul)" and "it is well with my soul" are one title.
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        let squash = { (text: String) in
            String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber })
        }
        let left = squash(a)
        return !left.isEmpty && left == squash(b)
    }

    /// The arrangement the plan uses: by id, then by name, else the song's
    /// first.
    public static func arrangement(
        in song: ShepherdClient.SongDetail, id: String?, name: String?
    ) -> ShepherdClient.SongArrangement? {
        if let id, let match = song.arrangements.first(where: { $0.id == id }) { return match }
        if let name, let match = song.arrangements.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        return song.arrangements.first
    }

    /// The order the band plays the song in: the arrangement's sequence, or
    /// the song's own.
    public static func sequence(of song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?) -> [String] {
        if let sequence = arrangement?.sequence, !sequence.isEmpty { return sequence }
        return song.sequence
    }
}
