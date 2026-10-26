import Foundation

/// One event from the church CMS's public calendar feed, the one hopejc.org
/// is built from.
public struct WebsiteEvent: Equatable, Sendable {
    public var slug: String
    public var title: String
    /// Shared by every occurrence of a repeating event.
    public var baseTitle: String
    public var cancelled: Bool
    /// "2026-10-31", church time.
    public var startDate: String
    /// "18:30", or nil for an all-day event or one with no time yet.
    public var startTime: String?
    public var endDate: String?
    public var endTime: String?
    public var allDay: Bool
    /// The event's 1920×1080 artwork as a full address; nil when it has none.
    public var image: String?
    public var calendars: [String]

    public init(
        slug: String, title: String, baseTitle: String? = nil, cancelled: Bool = false,
        startDate: String, startTime: String? = nil, endDate: String? = nil, endTime: String? = nil,
        allDay: Bool = false, image: String?, calendars: [String] = [WebsiteEvents.calendar]
    ) {
        self.slug = slug
        self.title = title
        self.baseTitle = baseTitle ?? title
        self.cancelled = cancelled
        self.startDate = startDate
        self.startTime = startTime
        self.endDate = endDate
        self.endTime = endTime
        self.allDay = allDay
        self.image = image
        self.calendars = calendars
    }
}

/// The pre-service slideshow carries a slide for each church event coming up
/// on hopejc.org: the event's artwork, full screen, from a month before the
/// event until it starts (or ends, when chosen). Everything here is worked
/// out from the feed and the clock, so the app only fetches, downloads the
/// artwork and writes what this says.
///
/// The slides it makes are tagged with their event (Slide.sourceEvent), and
/// it only ever adds, changes or removes tagged slides: slides made by hand
/// stay where they are. Its slides sit together in one run, soonest first,
/// after the hand-made ones, or wherever someone has moved the run to.
public enum WebsiteEvents {
    public static let host = URL(string: "https://media.hopejc.org")!
    /// Only the church-wide calendar: ministry calendars (students, kids)
    /// have their own gatherings that aren't for the whole room.
    public static let calendar = "master"
    /// The church's own clock, whatever the Mac is set to.
    public static let timeZone = TimeZone(identifier: "America/New_York")!

    public static let defaultWindowDays = 30
    public static let windowDayRange = 7 ... 60
    /// Slide ids start with this, followed by a hash of the event's key, so
    /// two Macs writing the same event write the same slide.
    public static let slideIDPrefix = "hopejc-"

    public static func feedURL() -> URL {
        var components = URLComponents(url: host.appendingPathComponent("api/public/calendar"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "calendar", value: calendar),
            URLQueryItem(name: "limit", value: "200"),
        ]
        return components.url!
    }

    // MARK: The feed

    /// The events in the feed. An entry missing its slug, title or a
    /// readable start date is left out rather than failing the rest.
    public static func parseFeed(_ data: Data) throws -> [WebsiteEvent] {
        let root = try AssistantJSON.parse(data)
        guard let events = root["events"]?.array else { throw CocoaError(.coderReadCorrupt) }
        return events.compactMap { entry in
            guard let slug = text(entry["slug"]), let title = text(entry["title"]),
                  let start = text(entry["start_date"]), DayStamp.parts(start) != nil
            else { return nil }
            return WebsiteEvent(
                slug: slug, title: title, baseTitle: text(entry["base_title"]) ?? title,
                cancelled: entry["cancelled"]?.bool ?? false,
                startDate: String(start.prefix(10)), startTime: text(entry["start_time"]),
                endDate: text(entry["end_date"]).map { String($0.prefix(10)) }, endTime: text(entry["end_time"]),
                allDay: entry["all_day"]?.bool ?? false,
                image: text(entry["image"]).flatMap(imageAddress),
                calendars: entry["calendars"]?.array?.compactMap(\.string) ?? [])
        }
    }

    private static func text(_ value: AssistantJSON?) -> String? {
        guard let raw = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// "/events/img/x.jpg" on the CMS's host; a full address stays as it is.
    static func imageAddress(_ raw: String) -> String? {
        if raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://") { return raw }
        return URL(string: raw, relativeTo: host)?.absoluteURL.absoluteString
    }

    // MARK: Choices

    public struct Options: Equatable, Sendable {
        public var windowDays: Int
        public var removeAtEnd: Bool
        /// Events someone chose not to show, by hideKey(_:).
        public var hidden: Set<String>

        public init(windowDays: Int = WebsiteEvents.defaultWindowDays, removeAtEnd: Bool = false, hidden: Set<String> = []) {
            self.windowDays = min(max(windowDays, WebsiteEvents.windowDayRange.lowerBound), WebsiteEvents.windowDayRange.upperBound)
            self.removeAtEnd = removeAtEnd
            self.hidden = hidden
        }

        public init(_ settings: WebsiteEventSettings?) {
            self.init(
                windowDays: settings?.windowDays ?? WebsiteEvents.defaultWindowDays,
                removeAtEnd: settings?.removeAtEnd ?? false,
                hidden: Set((settings?.hidden ?? []).map(WebsiteEvents.hideKey)))
        }
    }

    /// On unless someone turned it off; only the Mac that runs the service
    /// writes, so being on elsewhere does nothing.
    public static func isEnabled(_ settings: WebsiteEventSettings?) -> Bool {
        settings?.enabled ?? true
    }

    /// "Don't show" is remembered by the event's name, so it covers every
    /// occurrence of a repeating event and next year's one too.
    public static func hideKey(_ baseTitle: String) -> String {
        baseTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Settings with an event shown or not.
    public static func setting(_ settings: WebsiteEventSettings?, hidden: Bool, baseTitle: String) -> WebsiteEventSettings {
        var next = settings ?? WebsiteEventSettings()
        let key = hideKey(baseTitle)
        var list = (next.hidden ?? []).filter { hideKey($0) != key }
        if hidden { list.append(baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)) }
        next.hidden = list.isEmpty ? nil : list
        return next
    }

    // MARK: Times

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// A day at a time of day ("18:30" or "18:30:00"), or the day's start
    /// when there's no time, in church time.
    public static func date(day: String, time: String?, timeZone: TimeZone = WebsiteEvents.timeZone) -> Date? {
        guard let p = DayStamp.parts(day) else { return nil }
        var parts = DateComponents(year: p.year, month: p.month, day: p.day)
        if let time, let clock = ScheduleMath.parseTimeOfDay(time) {
            parts.hour = clock.hour
            parts.minute = clock.minute
            parts.second = clock.second
        }
        return calendar(timeZone).date(from: parts)
    }

    /// When the event starts: its time, or the start of its day when it's
    /// all day or has no time.
    public static func startsAt(_ event: WebsiteEvent, timeZone: TimeZone = WebsiteEvents.timeZone) -> Date? {
        date(day: event.startDate, time: event.allDay ? nil : event.startTime, timeZone: timeZone)
    }

    /// When its slide comes down: as it starts, or once it's over (its end
    /// time on its last day, else the end of its last day).
    public static func removeAt(
        _ event: WebsiteEvent, removeAtEnd: Bool, timeZone: TimeZone = WebsiteEvents.timeZone
    ) -> Date? {
        guard let start = startsAt(event, timeZone: timeZone) else { return nil }
        guard removeAtEnd else { return start }
        let lastDay = (event.endDate.flatMap { DayStamp.parts($0) != nil ? $0 : nil }).map { max($0, event.startDate) }
            ?? event.startDate
        if !event.allDay, let endTime = event.endTime,
           let end = date(day: lastDay, time: endTime, timeZone: timeZone), end > start {
            return end
        }
        return date(day: DayStamp.adding(1, to: lastDay), time: nil, timeZone: timeZone).map { max($0, start) }
    }

    /// The first moment its slide shows: the start of the day `windowDays`
    /// before it starts, so slides come and go at midnight, not mid-loop at
    /// the event's own time of day.
    public static func showFrom(_ event: WebsiteEvent, windowDays: Int, timeZone: TimeZone = WebsiteEvents.timeZone) -> Date? {
        date(day: DayStamp.adding(-windowDays, to: event.startDate), time: nil, timeZone: timeZone)
    }

    // MARK: What shows

    /// An event's slide as it should be now.
    public struct Shown: Equatable, Sendable {
        public var key: String
        public var event: WebsiteEvent
        public var startsAt: Date
        public var showFrom: Date
        public var removeAt: Date
        public var imageURL: String
        /// Someone chose not to show it (only in the list for Settings).
        public var hidden: Bool

        public var tag: WebsiteEventTag {
            WebsiteEventTag(
                key: key, slug: event.slug, title: event.title, startDate: event.startDate,
                startTime: event.allDay ? nil : event.startTime,
                removeAt: WebsiteEvents.stamp(removeAt), imageUrl: imageURL)
        }
    }

    /// The occurrences of one repeating event share a name and a picture.
    public static func key(_ event: WebsiteEvent) -> String {
        hideKey(event.baseTitle) + "|" + (event.image ?? "")
    }

    /// Events that can have a slide at all: on the church calendar, not
    /// cancelled, with artwork.
    static func eligible(_ event: WebsiteEvent) -> Bool {
        !event.cancelled && event.image != nil
            && event.calendars.contains { $0.caseInsensitiveCompare(calendar) == .orderedSame }
    }

    /// The slides that belong in the slideshow now, soonest first: for each
    /// event (a repeating one counts once, by its next occurrence), from
    /// `windowDays` before it starts until it starts or ends. With
    /// `includingHidden`, events someone chose not to show are listed too,
    /// marked, so Settings can offer them back.
    public static func desired(
        _ events: [WebsiteEvent], now: Date, options: Options,
        includingHidden: Bool = false, timeZone: TimeZone = WebsiteEvents.timeZone
    ) -> [Shown] {
        var next: [String: Shown] = [:]
        for event in events where eligible(event) {
            guard let image = event.image,
                  let starts = startsAt(event, timeZone: timeZone),
                  let remove = removeAt(event, removeAtEnd: options.removeAtEnd, timeZone: timeZone),
                  let from = showFrom(event, windowDays: options.windowDays, timeZone: timeZone),
                  remove > now
            else { continue }
            let hidden = options.hidden.contains(hideKey(event.baseTitle))
            if hidden, !includingHidden { continue }
            let key = key(event)
            let shown = Shown(
                key: key, event: event, startsAt: starts, showFrom: from, removeAt: remove,
                imageURL: image, hidden: hidden)
            if let current = next[key], (current.startsAt, current.event.slug) <= (starts, event.slug) { continue }
            next[key] = shown
        }
        return next.values
            .filter { $0.showFrom <= now }
            .sorted { ($0.startsAt, $0.event.title, $0.key) < ($1.startsAt, $1.event.title, $1.key) }
    }

    /// The next moment what shows changes by the clock alone: an event's
    /// window opening, a slide's time to come down, or the next midnight
    /// (so a long gap still gets looked at once a day).
    public static func nextBoundary(
        _ events: [WebsiteEvent], tags: [WebsiteEventTag] = [], now: Date, options: Options,
        timeZone: TimeZone = WebsiteEvents.timeZone
    ) -> Date {
        var times: [Date] = []
        for event in events where eligible(event) {
            if let from = showFrom(event, windowDays: options.windowDays, timeZone: timeZone) { times.append(from) }
            if let remove = removeAt(event, removeAtEnd: options.removeAtEnd, timeZone: timeZone) { times.append(remove) }
        }
        times += tags.compactMap { $0.removeAt.flatMap(parseStamp) }
        let cal = calendar(timeZone)
        let midnight = cal.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
        times.append(midnight)
        return times.filter { $0 > now }.min() ?? midnight
    }

    // MARK: Stamps

    public static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func parseStamp(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    /// A slide's event is over by its own record, with no feed to hand: the
    /// network can be down and its time still comes.
    public static func hasExpired(_ tag: WebsiteEventTag, now: Date) -> Bool {
        tag.removeAt.flatMap(parseStamp).map { $0 <= now } ?? false
    }

    // MARK: Labels

    /// "Trunk or Treat · Oct 31" for the slide's tile.
    public static func label(_ tag: WebsiteEventTag) -> String {
        guard let day = shortDay(tag.startDate) else { return tag.title }
        return "\(tag.title) \u{00B7} \(day)"
    }

    /// "Oct 31" from "2026-10-31".
    public static func shortDay(_ stamp: String) -> String? {
        guard let p = DayStamp.parts(stamp), (1 ... 12).contains(p.month) else { return nil }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[p.month - 1]) \(p.day)"
    }

    // MARK: Slides

    /// The slide id for an event's key: the same on every Mac.
    public static func slideID(forKey key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return slideIDPrefix + String(hash, radix: 16)
    }

    /// The artwork as the whole slide, the way an image dropped to make a
    /// slide is placed.
    public static func background(mediaID: String) -> CueMedia {
        CueMedia(mediaId: mediaID, layer: .stillGraphics, classification: .foreground)
    }

    /// One slide wanted in the slideshow, with the media its artwork was
    /// brought in as; nil when the artwork couldn't be had yet.
    public struct Wanted: Equatable, Sendable {
        public var shown: Shown
        public var mediaID: String?

        public init(shown: Shown, mediaID: String?) {
            self.shown = shown
            self.mediaID = mediaID
        }
    }

    public struct SlidePlan: Equatable, Sendable {
        public var slides: [Slide]
        public var added: [String] = []
        public var updated: [String] = []
        public var removed: [String] = []
        /// Only the order changed.
        public var moved = false
        /// A change left for later because its slide is on the screens.
        public var deferred = false

        public var changed: Bool { !added.isEmpty || !updated.isEmpty || !removed.isEmpty || moved }
    }

    /// The slideshow's slides with the website's brought up to date. Slides
    /// without a tag are never touched and keep their order. The tagged ones
    /// are rebuilt as one run in `wanted`'s order, where the first tagged
    /// slide was (after the hand-made slides when there was none); a second
    /// slide for the same event (two Macs both adding it) is dropped.
    ///
    /// The slide on the screens (`liveSlideID`) is left exactly as it is,
    /// even when its event has gone, so the loop isn't pulled out from under
    /// the room; `deferred` says to look again shortly.
    public static func plan(existing: [Slide], wanted: [Wanted], liveSlideID: String? = nil) -> SlidePlan {
        let handMade = existing.filter { $0.sourceEvent == nil }
        let anchor = existing.firstIndex { $0.sourceEvent != nil }
            .map { index in existing[..<index].filter { $0.sourceEvent == nil }.count } ?? handMade.count
        var byKey: [String: Slide] = [:]
        for slide in existing {
            guard let key = slide.sourceEvent?.key, byKey[key] == nil else { continue }
            byKey[key] = slide
        }

        var deferred = false
        var run: [Slide] = []
        var placed = Set<String>()
        for want in wanted where !placed.contains(want.shown.key) {
            let key = want.shown.key
            if let old = byKey[key] {
                if old.id == liveSlideID {
                    if refreshed(old, with: want) != old { deferred = true }
                    run.append(old)
                } else {
                    run.append(refreshed(old, with: want))
                }
                placed.insert(key)
            } else if let mediaID = want.mediaID {
                var slide = Slide(id: slideID(forKey: key), name: want.shown.event.title, objects: [])
                slide.background = background(mediaID: mediaID)
                slide.unthemed = true
                slide.sourceEvent = want.shown.tag
                run.append(slide)
                placed.insert(key)
            }
        }
        // The live slide stays even when its event is no longer wanted, in
        // date order among the rest.
        if let liveSlideID, let live = existing.first(where: { $0.id == liveSlideID }),
           let tag = live.sourceEvent, !run.contains(where: { $0.id == liveSlideID }) {
            deferred = true
            let order = { (slide: Slide) in (slide.sourceEvent?.startDate ?? "", slide.sourceEvent?.startTime ?? "") }
            let index = run.firstIndex { order($0) > (tag.startDate, tag.startTime ?? "") } ?? run.count
            run.insert(live, at: index)
        }

        let slides = Array(handMade[..<anchor]) + run + Array(handMade[anchor...])
        var plan = SlidePlan(slides: slides, deferred: deferred)
        let before = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for slide in run {
            if let old = before[slide.id] {
                if old != slide { plan.updated.append(slide.id) }
            } else {
                plan.added.append(slide.id)
            }
        }
        // Every tagged slide not carried over, a second copy of one included.
        let runIDs = Set(run.map(\.id))
        var kept = Set<String>()
        for slide in existing where slide.sourceEvent != nil {
            if !(runIDs.contains(slide.id) && kept.insert(slide.id).inserted) {
                plan.removed.append(slide.id)
            }
        }
        // The run gathered back together, or put back in date order.
        plan.moved = slides.map(\.id) != existing.map(\.id) && plan.added.isEmpty && plan.removed.isEmpty
        return plan
    }

    /// An existing slide brought up to its event: its name, artwork and tag.
    /// Anything else someone set on it (a transition, the livestream) stays.
    static func refreshed(_ slide: Slide, with want: Wanted) -> Slide {
        var slide = slide
        slide.name = want.shown.event.title
        if let mediaID = want.mediaID, slide.background?.mediaId != mediaID {
            slide.background = background(mediaID: mediaID)
        }
        slide.unthemed = true
        slide.sourceEvent = want.shown.tag
        return slide
    }

    /// The tagged slides whose events are over by their own records. Used
    /// when there's no feed to go on.
    public static func expiredOnly(existing: [Slide], now: Date, liveSlideID: String?) -> SlidePlan {
        var plan = SlidePlan(slides: [])
        for slide in existing {
            if let tag = slide.sourceEvent, hasExpired(tag, now: now) {
                if slide.id == liveSlideID {
                    plan.deferred = true
                } else {
                    plan.removed.append(slide.id)
                    continue
                }
            }
            plan.slides.append(slide)
        }
        return plan
    }

    /// The media an event's slides use, by the address they came from.
    public static func mediaIDs(in slides: [Slide]) -> Set<String> {
        Set(slides.compactMap { $0.sourceEvent == nil ? nil : $0.background?.mediaId })
    }
}
