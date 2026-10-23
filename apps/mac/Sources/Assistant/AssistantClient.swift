import Foundation
import PresenterCore

/// Sends one Messages API request and streams the reply. Swift has no
/// Anthropic SDK, so this is raw HTTP: the key goes in a header and nowhere
/// else (never into logs or diagnostics).
@MainActor
enum AssistantClient {
    enum Failure: LocalizedError {
        case missingKey
        case http(Int, String)
        case stream(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "Add your Anthropic API key in \(AssistantPreferences.keyLocation)."
            case .http(401, _):
                "Anthropic rejected the API key. Check it in \(AssistantPreferences.keyLocation)."
            case .http(429, _):
                "Claude is rate-limited right now. Try again in a minute."
            case .http(529, _), .http(503, _):
                "Claude is overloaded right now. Try again in a minute."
            case .http(let code, let message):
                "The Claude request failed (\(code)). \(message)"
            case .stream(let message):
                "The reply was cut off: \(message)"
            }
        }
    }

    /// Statuses worth a quiet retry before anything has streamed.
    private static let retryable: Set<Int> = [429, 500, 502, 503, 529]

    static func stream(
        _ body: AssistantJSON, onEvent: (AssistantStream.Event) -> Void
    ) async throws -> AssistantStream {
        let key = ClaudeClient.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingKey }
        var request = URLRequest(url: AssistantRequest.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        for (name, value) in AssistantRequest.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = body.encoded()

        var attempt = 0
        while true {
            attempt += 1
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let message = try await errorMessage(bytes)
                if retryable.contains(status), attempt <= 2 {
                    let hinted = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                    try await Task.sleep(for: .seconds(min(hinted ?? Double(attempt * 3), 20)))
                    continue
                }
                throw Failure.http(status, message)
            }
            var stream = AssistantStream()
            do {
                for try await line in bytes.lines {
                    for event in try stream.feed(line: line) {
                        onEvent(event)
                    }
                    if stream.finished { break }
                }
            } catch let error as AssistantStream.StreamError {
                throw Failure.stream(error.message)
            }
            return stream
        }
    }

    /// The API's own error message, from a JSON error body.
    private static func errorMessage(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 16_000 { break }
        }
        let parsed = try? AssistantJSON.parse(data)
        return parsed?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
    }
}

/// Gets the church's events: the calendar feed first, then the website.
enum ChurchEventsFetcher {
    struct Result: Sendable {
        var events: [ChurchEvent]
        var source: String
        /// Page text for the model when no event could be read from the site.
        var pageText: String?
    }

    static func fetch(today: String, includeRecentPast: Bool) async throws -> Result {
        let from = includeRecentPast ? DayStamp.adding(-90, to: today) : nil
        if let data = try? await get(ChurchEvents.feedURL(from: from)),
           let events = try? ChurchEvents.parseFeed(data), !events.isEmpty {
            return Result(events: events, source: "media.hopejc.org calendar feed (the hopejc.org events page)")
        }
        // The website: homepage › Events link › the page, or the calendar it frames.
        let home = try await get(ChurchEvents.homepage)
        let homeHTML = String(decoding: home, as: UTF8.self)
        guard let eventsURL = ChurchEvents.eventsPageLink(in: homeHTML, base: ChurchEvents.homepage) else {
            return Result(events: [], source: ChurchEvents.homepage.absoluteString,
                          pageText: String(HTMLText.plainText(homeHTML, linksFrom: ChurchEvents.homepage).prefix(12_000)))
        }
        let page = String(decoding: try await get(eventsURL), as: UTF8.self)
        var events = ChurchEvents.parseCards(page, base: eventsURL)
        var source = eventsURL.absoluteString
        var text = HTMLText.plainText(page, linksFrom: eventsURL)
        if events.isEmpty {
            for frame in ChurchEvents.frames(in: page, base: eventsURL).prefix(2) {
                guard let data = try? await get(frame) else { continue }
                let html = String(decoding: data, as: UTF8.self)
                events = ChurchEvents.parseCards(html, base: frame)
                source = frame.absoluteString
                text = HTMLText.plainText(html, linksFrom: frame)
                if !events.isEmpty { break }
            }
        }
        return Result(events: events, source: source, pageText: events.isEmpty ? String(text.prefix(12_000)) : nil)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Screens (Hope Church presentation app)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }
}
