import Foundation

/// Matches event-promo slides to the church's events, so stale promos can be
/// found in the pre-service slideshow and announcements. It only suggests:
/// the model reads the result, and the user approves any deletion.
public enum EventSlideMatcher {
    public struct SlideFacts: Equatable, Sendable {
        public var id: String
        public var name: String
        public var text: String
        /// The background image or video's library name (often the file name).
        public var mediaName: String

        public init(id: String, name: String, text: String, mediaName: String) {
            self.id = id
            self.name = name
            self.text = text
            self.mediaName = mediaName
        }
    }

    public enum Status: String, Sendable {
        /// The matched event is over, or every date on the slide has passed.
        case passed
        /// The matched event is today or later, or the slide names a coming date.
        case current
        /// Nothing ties the slide to an event (welcome, giving, and so on).
        case unmatched
    }

    public struct Verdict: Equatable, Sendable {
        public var slideID: String
        public var status: Status
        public var event: ChurchEvent?
        /// How sure the match is, 0...1 (share of the event title's words found).
        public var score: Double
        public var reason: String

        public func json(index: Int, slide: SlideFacts, today: String) -> AssistantJSON {
            var fields: [String: AssistantJSON] = [
                "slide_id": .string(slideID), "index": .number(Double(index)), "slide_name": .string(slide.name),
                "status": .string(status.rawValue), "reason": .string(reason),
            ]
            if !slide.mediaName.isEmpty { fields["background"] = .string(slide.mediaName) }
            if let event {
                fields["event"] = event.json(today: today)
                fields["match_score"] = .number((score * 100).rounded() / 100)
            }
            return .object(fields)
        }
    }

    /// Words that say nothing about which event a slide is for.
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "you", "your", "our", "are", "join", "us", "at", "of", "to", "in", "on", "a",
        "an", "is", "it", "be", "this", "that", "from", "will", "all", "hope", "church", "jc", "johnson", "city",
        "slide", "title", "final", "copy", "hd", "4k", "png", "jpg", "jpeg", "mov", "mp4", "pdf", "graphic",
        "promo", "announcement", "announcements", "card", "sunday", "sundays", "event", "events", "v", "wide",
        "new", "pm", "am", "register", "sign", "up", "more", "info", "details",
    ]

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9,
        "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    /// Lowercased words of three letters or more, minus stop words, numbers,
    /// month names and sizes like 1920x1080.
    public static func words(_ text: String) -> Set<String> {
        let spaced = text.replacing(/([a-z])([A-Z])/) { "\($0.1) \($0.2)" }
        let pieces = spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(pieces.filter { word in
            word.count >= 3 && !stopWords.contains(word) && months[word] == nil
                && !word.allSatisfy(\.isNumber) && word.wholeMatch(of: /\d+x\d+/) == nil
        })
    }

    /// Two words count as the same when equal, or when one is a prefix of the
    /// other and both are five letters or more ("christmas" / "christmastime").
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 5, b.count >= 5 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Share of the event title's words that appear on the slide.
    public static func score(slide: Set<String>, title: String) -> Double {
        let titleWords = words(title)
        guard !titleWords.isEmpty else { return 0 }
        let found = titleWords.filter { word in slide.contains { same($0, word) } }
        return Double(found.count) / Double(titleWords.count)
    }

    /// Dates written on a slide ("Oct 25", "October 25-27", "10/25", "10/25/26"),
    /// as day stamps. A month-day without a year takes today's year, or next
    /// year when that would put it more than four months back.
    public static func dates(in text: String, today: String) -> [String] {
        guard let now = DayStamp.parts(today) else { return [] }
        var found: [String] = []
        func add(_ year: Int?, _ month: Int, _ day: Int) {
            guard (1...12).contains(month), (1...31).contains(day) else { return }
            var stamp = DayStamp.make(year: year ?? now.year, month: month, day: day)
            if year == nil, let gap = DayStamp.days(from: stamp, to: today), gap > 120 {
                stamp = DayStamp.make(year: now.year + 1, month: month, day: day)
            }
            found.append(stamp)
        }
        let lower = text.lowercased()
        for match in lower.matches(of: /\b([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*[-–]\s*(\d{1,2}))?(?:,?\s+(\d{4}))?\b/) {
            guard let month = months[String(match.1)], let day = Int(match.2) else { continue }
            let year = match.4.flatMap { Int($0) }
            add(year, month, day)
            if let last = match.3.flatMap({ Int($0) }) { add(year, month, last) }
        }
        for match in lower.matches(of: /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2}|\d{4}))?\b/) {
            guard let month = Int(match.1), let day = Int(match.2) else { continue }
            let year = match.3.flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
            add(year, month, day)
        }
        return found
    }

    /// One verdict per slide, in order.
    public static func classify(_ slides: [SlideFacts], events: [ChurchEvent], today: String) -> [Verdict] {
        let usable = events.filter { !words($0.title).isEmpty }
        return slides.map { slide in
            let mediaStem = (slide.mediaName as NSString).deletingPathExtension
            let slideWords = words([slide.name, slide.text, mediaStem].joined(separator: " "))
            let written = dates(in: [slide.name, slide.text, mediaStem].joined(separator: " "), today: today)

            let scored = usable.map { (event: $0, score: score(slide: slideWords, title: $0.title)) }
                .filter { $0.score >= 0.6 }
            if let best = scored.map(\.score).max() {
                let tied = scored.filter { abs($0.score - best) < 0.001 }.map(\.event)
                let event = pick(tied, written: written, today: today)
                let ended = event.hasEnded(today: today)
                let when = event.lastDay == event.startDate ? event.startDate : "\(event.startDate) to \(event.lastDay)"
                return Verdict(
                    slideID: slide.id, status: ended ? .passed : .current, event: event, score: best,
                    reason: ended ? "Matches \"\(event.title)\", which ended (\(when))."
                        : "Matches \"\(event.title)\" (\(when)), still to come.")
            }
            if !written.isEmpty {
                let upcoming = written.filter { $0 >= today }
                return Verdict(
                    slideID: slide.id, status: upcoming.isEmpty ? .passed : .current, event: nil, score: 0,
                    reason: upcoming.isEmpty
                        ? "No event matched, but every date on the slide has passed (\(written.joined(separator: ", ")))."
                        : "No event matched; the slide names a coming date (\(upcoming.joined(separator: ", "))).")
            }
            return Verdict(slideID: slide.id, status: .unmatched, event: nil, score: 0,
                           reason: "No event or date found on the slide.")
        }
    }

    /// Among equally good matches (a recurring event's past and future
    /// dates): the one whose date the slide names; else the next one still to
    /// come; else the most recent.
    static func pick(_ events: [ChurchEvent], written: [String], today: String) -> ChurchEvent {
        if let named = events.first(where: { event in
            written.contains { $0 >= event.startDate && $0 <= event.lastDay }
        }) {
            return named
        }
        let coming = events.filter { !$0.hasEnded(today: today) }.sorted { $0.startDate < $1.startDate }
        if let next = coming.first { return next }
        return events.sorted { $0.lastDay > $1.lastDay }[0]
    }
}
