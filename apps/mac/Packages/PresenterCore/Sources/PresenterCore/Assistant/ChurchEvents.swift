import Foundation

/// One event from the church calendar.
public struct ChurchEvent: Equatable, Sendable {
    public var title: String
    /// "2026-10-25".
    public var startDate: String
    /// Last day, for events that run several days.
    public var endDate: String?
    /// "5 - 7pm", "All day", or "17:00-19:00".
    public var time: String?
    public var summary: String?
    public var location: String?
    public var url: String?
    public var cancelled: Bool

    public init(
        title: String, startDate: String, endDate: String? = nil, time: String? = nil,
        summary: String? = nil, location: String? = nil, url: String? = nil, cancelled: Bool = false
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.time = time
        self.summary = summary
        self.location = location
        self.url = url
        self.cancelled = cancelled
    }

    /// The day the event is over by: its end date, else its start date.
    public var lastDay: String { (endDate?.isEmpty == false ? endDate : nil) ?? startDate }

    /// True once the event's last day is before `today` ("YYYY-MM-DD").
    /// An event on today's date is still current.
    public func hasEnded(today: String) -> Bool { lastDay < today }

    public func json(today: String) -> AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "title": .string(title), "start_date": .string(startDate), "ended": .bool(hasEnded(today: today)),
        ]
        if let endDate, endDate != startDate { fields["end_date"] = .string(endDate) }
        if let time, !time.isEmpty { fields["time"] = .string(time) }
        if let summary, !summary.isEmpty { fields["summary"] = .string(summary) }
        if let location, !location.isEmpty { fields["location"] = .string(location) }
        if let url { fields["link"] = .string(url) }
        if cancelled { fields["cancelled"] = true }
        return .object(fields)
    }
}

/// Reads the church's events. The church's own CMS publishes the calendar as
/// JSON (the same feed hopejc.org is built from), which is the first choice;
/// when that fails, the homepage's Events link is followed and the event
/// cards are read out of the page (or the calendar embed it frames).
public enum ChurchEvents {
    public static let homepage = URL(string: "https://www.hopejc.org/")!

    /// The public calendar feed, from `from` (to include recent past events) on.
    public static func feedURL(from: String?, limit: Int = 200) -> URL {
        var components = URLComponents(string: "https://media.hopejc.org/api/public/calendar")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let from {
            items.append(URLQueryItem(name: "past", value: "1"))
            items.append(URLQueryItem(name: "from", value: from))
        }
        components.queryItems = items
        return components.url!
    }

    // MARK: The JSON feed

    public static func parseFeed(_ data: Data) throws -> [ChurchEvent] {
        let root = try AssistantJSON.parse(data)
        guard let events = root["events"]?.array else { throw CocoaError(.coderReadCorrupt) }
        return events.compactMap { event in
            guard let title = event["title"]?.string, let start = event["start_date"]?.string else { return nil }
            let allDay = event["all_day"]?.bool ?? false
            let time: String? = allDay ? "All day" : [event["start_time"]?.string, event["end_time"]?.string]
                .compactMap { $0 }.joined(separator: "-")
            return ChurchEvent(
                title: title, startDate: start, endDate: event["end_date"]?.string,
                time: time?.isEmpty == true ? nil : time,
                summary: event["summary"]?.string, location: event["location_name"]?.string,
                url: event["url"]?.string, cancelled: event["cancelled"]?.bool ?? false)
        }
    }

    // MARK: The web pages

    /// The homepage's link to its events page.
    public static func eventsPageLink(in html: String, base: URL) -> URL? {
        let links = HTMLText.links(in: html, base: base)
        let sameSite = links.filter { $0.url.host == nil || $0.url.host?.hasSuffix(base.host ?? "") == true }
        let byPath = sameSite.first { link in
            let path = link.url.path.lowercased()
            return path == "/events" || path == "/events/" || path.hasSuffix("/events") || path.hasSuffix("/calendar")
        }
        return byPath?.url ?? sameSite.first { $0.text.lowercased() == "events" }?.url
    }

    /// The pages an events page frames (the calendar embed).
    public static func frames(in html: String, base: URL) -> [URL] {
        let pattern = /<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/
        return html.matches(of: pattern.ignoresCase()).compactMap { match in
            URL(string: HTMLText.decodeEntities(String(match.1)), relativeTo: base)?.absoluteURL
        }
    }

    /// Event cards: links to an event page whose address ends in the event's
    /// date ("/events/fall-festival-2026-10-25"), with the title, time and
    /// description in the card.
    public static func parseCards(_ html: String, base: URL) -> [ChurchEvent] {
        let anchor = /<a\b([^>]*)>(.*?)<\/a>/
        var events: [ChurchEvent] = []
        for match in html.matches(of: anchor.dotMatchesNewlines().ignoresCase()) {
            let attributes = String(match.1)
            guard let href = attributes.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase()).map({ String($0.1) }),
                  let url = URL(string: HTMLText.decodeEntities(href), relativeTo: base)?.absoluteURL,
                  url.path.lowercased().contains("/event"),
                  let date = url.lastPathComponent.firstMatch(of: /(\d{4})-(\d{2})-(\d{2})(?:-\d+)?$/)
            else { continue }
            let start = "\(date.1)-\(date.2)-\(date.3)"
            let inner = String(match.2)
            let title = classText("t", in: inner) ?? classText("title", in: inner)
                ?? HTMLText.plainText(inner).split(separator: "\n").first.map(String.init)
            guard let title, !title.isEmpty else { continue }
            var end: String?
            if let range = inner.firstMatch(of: /class\s*=\s*["']when range["'][^>]*>\s*<b>\s*(\d{1,2})\s*-\s*(\d{1,2})\s*<\/b>/.ignoresCase()),
               let first = Int(range.1), let last = Int(range.2), let year = Int(date.1), let month = Int(date.2) {
                end = last >= first
                    ? DayStamp.make(year: year, month: month, day: last)
                    : DayStamp.make(year: month == 12 ? year + 1 : year, month: month == 12 ? 1 : month + 1, day: last)
            }
            let meta = classText("meta", in: inner)
            events.append(ChurchEvent(
                title: title, startDate: start, endDate: end,
                time: meta?.components(separatedBy: " · ").first,
                summary: classText("desc", in: inner), url: url.absoluteString))
        }
        var seen = Set<String>()
        return events.filter { seen.insert(($0.url ?? "") + $0.title).inserted }
    }

    private static func classText(_ name: String, in html: String) -> String? {
        // Card fields are spans or simple blocks; a field ends at the first
        // closing tag of that kind, so inline <b> inside it is kept.
        let pattern = try? Regex("<(?:span|div|p|h[1-6])\\b[^>]*\\bclass\\s*=\\s*[\"']\(name)[\"'][^>]*>(.*?)</(?:span|div|p|h[1-6])>")
        guard let pattern, let match = html.firstMatch(of: pattern.dotMatchesNewlines().ignoresCase()),
              let inner = match.output[1].substring
        else { return nil }
        let text = HTMLText.plainText(String(inner)).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// "YYYY-MM-DD" day stamps. They compare correctly as strings.
public enum DayStamp {
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    public static func make(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Today (or any moment) as a local day stamp.
    public static func of(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return make(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    public static func parts(_ stamp: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = stamp.prefix(10).split(separator: "-").compactMap { Int($0) }
        return pieces.count == 3 ? (pieces[0], pieces[1], pieces[2]) : nil
    }

    /// The stamp `days` later (or earlier, when negative).
    public static func adding(_ days: Int, to stamp: String) -> String {
        guard let p = parts(stamp),
              let date = gregorian.date(from: DateComponents(year: p.year, month: p.month, day: p.day)),
              let moved = gregorian.date(byAdding: .day, value: days, to: date)
        else { return stamp }
        return of(moved, calendar: gregorian)
    }

    /// Whole days from `from` to `to`.
    public static func days(from: String, to: String) -> Int? {
        guard let a = parts(from), let b = parts(to),
              let start = gregorian.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
              let end = gregorian.date(from: DateComponents(year: b.year, month: b.month, day: b.day))
        else { return nil }
        return gregorian.dateComponents([.day], from: start, to: end).day
    }
}

/// HTML to plain text for the model and for card fields.
public enum HTMLText {
    public struct Link: Equatable, Sendable {
        public var text: String
        public var url: URL
    }

    public static func links(in html: String, base: URL) -> [Link] {
        let anchor = /<a\b([^>]*)>(.*?)<\/a>/
        return html.matches(of: anchor.dotMatchesNewlines().ignoresCase()).compactMap { match in
            guard let href = String(match.1).firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase()).map({ String($0.1) }),
                  !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:"),
                  let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL
            else { return nil }
            let text = plainText(String(match.2)).replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Link(text: text, url: url)
        }
    }

    /// Readable text: scripts, styles and comments dropped, block elements on
    /// their own lines (blank lines dropped), links written as "text (address)" when a base is
    /// given, entities decoded, whitespace collapsed.
    public static func plainText(_ html: String, linksFrom base: URL? = nil) -> String {
        var text = html
        for pattern in [/<script\b.*?<\/script>/, /<style\b.*?<\/style>/, /<svg\b.*?<\/svg>/, /<!--.*?-->/,
                        /<noscript\b.*?<\/noscript>/] {
            text = text.replacing(pattern.dotMatchesNewlines().ignoresCase(), with: " ")
        }
        if let base {
            text = text.replacing(/<a\b([^>]*)>(.*?)<\/a>/.dotMatchesNewlines().ignoresCase()) { match in
                let inner = String(match.2)
                guard let href = String(match.1).firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase()).map({ String($0.1) }),
                      !href.hasPrefix("#"),
                      let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL
                else { return inner }
                return "\(inner) (\(url.absoluteString))"
            }
        }
        text = text.replacing(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr|\/section|\/article|\/header|\/footer|\/a)\b[^>]*>/.ignoresCase(), with: "\n")
        text = text.replacing(/<[^>]+>/, with: " ")
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "middot": "·",
            "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…",
        ]
        return text.replacing(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/) { match in
            let body = String(match.1)
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            } else if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.0)
            }
            return named[body.lowercased()] ?? String(match.0)
        }
    }
}
