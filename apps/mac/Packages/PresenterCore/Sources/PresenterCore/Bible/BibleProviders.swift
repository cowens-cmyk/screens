import Foundation

public struct BibleTranslation: Hashable, Sendable, Identifiable, Codable {
    public enum Source: String, Hashable, Sendable, Codable { case apiBible, esv }

    public var source: Source
    /// API.Bible's bible id, or "ESV".
    public var id: String
    public var abbreviation: String
    public var name: String

    public init(source: Source, id: String, abbreviation: String, name: String) {
        self.source = source
        self.id = id
        self.abbreviation = abbreviation
        self.name = name
    }

    public static let esv = BibleTranslation(source: .esv, id: "ESV", abbreviation: "ESV", name: "English Standard Version")
}

public struct BiblePassage: Hashable, Sendable {
    public var reference: BibleReference
    public var translation: BibleTranslation
    public var verses: [BibleVerse]
    public var copyright: String?

    public init(reference: BibleReference, translation: BibleTranslation, verses: [BibleVerse], copyright: String? = nil) {
        self.reference = reference
        self.translation = translation
        self.verses = verses
        self.copyright = copyright
    }
}

public enum BibleError: LocalizedError, Equatable {
    case unrecognizedReference(String)
    case missingKey(String)
    case http(Int, String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .unrecognizedReference(let text): "“\(text)” isn't a Bible reference I recognize."
        case .missingKey(let service): "Add your \(service) key in Settings › Bible."
        case .http(let code, let body): "The Bible service answered \(code). \(body.prefix(200))"
        case .empty: "No verses came back for that reference."
        }
    }
}

public struct BibleKeys: Sendable {
    public var apiBible: String?
    public var esv: String?

    public init(apiBible: String?, esv: String?) {
        self.apiBible = apiBible?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.esv = esv?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One verse from the ESV API's search: "Romans 8:28" and its text.
public struct ESVSearchResult: Hashable, Sendable, Decodable {
    public var reference: String
    public var content: String

    public init(reference: String, content: String) {
        self.reference = reference
        self.content = content
    }
}

/// The ESV API answered 429: too many requests.
public struct ESVRateLimited: Error, Sendable {
    public var retryAfter: TimeInterval?
}

/// Fetches passages from API.Bible (rest.api.bible) and the ESV API
/// (api.esv.org). Both return text with "[n]" verse markers, which
/// ScriptureText.verses(fromMarked:) splits.
public struct BibleService: Sendable {
    public var keys: BibleKeys
    public var session: URLSession

    public init(keys: BibleKeys, session: URLSession = .shared) {
        self.keys = keys
        self.session = session
    }

    public func translations(language: String = "eng") async throws -> [BibleTranslation] {
        var result: [BibleTranslation] = keys.esv == nil ? [] : [.esv]
        guard let key = keys.apiBible else { return result }
        var components = URLComponents(string: "https://rest.api.bible/v1/bibles")!
        components.queryItems = [URLQueryItem(name: "language", value: language)]
        let data = try await get(components.url!, headers: ["api-key": key])
        struct Response: Decodable {
            struct Bible: Decodable {
                var id: String
                var abbreviation: String?
                var abbreviationLocal: String?
                var name: String
            }
            var data: [Bible]
        }
        let bibles = try JSONDecoder().decode(Response.self, from: data).data
        result += bibles.map {
            BibleTranslation(
                source: .apiBible, id: $0.id,
                abbreviation: $0.abbreviationLocal ?? $0.abbreviation ?? $0.name, name: $0.name)
        }
        .sorted { $0.abbreviation.localizedStandardCompare($1.abbreviation) == .orderedAscending }
        return result
    }

    public func passage(_ text: String, translation: BibleTranslation) async throws -> BiblePassage {
        guard let reference = BibleReference.parse(text) else { throw BibleError.unrecognizedReference(text) }
        return try await passage(reference, translation: translation)
    }

    public func passage(_ reference: BibleReference, translation: BibleTranslation) async throws -> BiblePassage {
        let (marked, copyright) = switch translation.source {
        case .apiBible: try await apiBibleText(reference, bibleID: translation.id)
        case .esv: try await esvText(reference)
        }
        let verses = ScriptureText.verses(
            fromMarked: marked, chapter: reference.chapter, startVerse: reference.startVerse ?? 1)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !verses.isEmpty else { throw BibleError.empty }
        return BiblePassage(reference: reference, translation: translation, verses: verses, copyright: copyright)
    }

    private func apiBibleText(_ reference: BibleReference, bibleID: String) async throws -> (String, String?) {
        guard let key = keys.apiBible else { throw BibleError.missingKey("API.Bible") }
        let id = reference.apiBiblePassageID
        var components = URLComponents(string: "https://rest.api.bible/v1/bibles/\(bibleID)/passages/\(id)")!
        components.queryItems = [
            .init(name: "content-type", value: "text"),
            .init(name: "include-notes", value: "false"),
            .init(name: "include-titles", value: "false"),
            .init(name: "include-chapter-numbers", value: "false"),
            .init(name: "include-verse-numbers", value: "true"),
            .init(name: "include-verse-spans", value: "false"),
        ]
        let data = try await get(components.url!, headers: ["api-key": key])
        struct Response: Decodable {
            struct Passage: Decodable { var content: String; var copyright: String? }
            var data: Passage
        }
        let passage = try JSONDecoder().decode(Response.self, from: data).data
        return (passage.content, passage.copyright)
    }

    private func esvText(_ reference: BibleReference) async throws -> (String, String?) {
        guard let key = keys.esv else { throw BibleError.missingKey("ESV API") }
        var components = URLComponents(string: "https://api.esv.org/v3/passage/text/")!
        components.queryItems = [
            .init(name: "q", value: reference.query),
            .init(name: "include-passage-references", value: "false"),
            .init(name: "include-verse-numbers", value: "true"),
            .init(name: "include-first-verse-numbers", value: "true"),
            .init(name: "include-footnotes", value: "false"),
            .init(name: "include-footnote-body", value: "false"),
            .init(name: "include-headings", value: "false"),
            .init(name: "include-short-copyright", value: "false"),
            .init(name: "include-passage-horizontal-lines", value: "false"),
            .init(name: "include-heading-horizontal-lines", value: "false"),
            .init(name: "indent-paragraphs", value: "0"),
            .init(name: "indent-poetry", value: "false"),
        ]
        let data = try await get(components.url!, headers: ["Authorization": "Token \(key)"])
        struct Response: Decodable { var passages: [String] }
        let text = try JSONDecoder().decode(Response.self, from: data).passages.joined(separator: "\n")
        return (text, "Scripture quotations are from the ESV® Bible, © 2001 by Crossway.")
    }

    /// Verses matching words, from the ESV API's search. Used to find a
    /// passage the pastor is reading without saying where it is, so the
    /// caller keeps it inside the API's limits (ScriptureSearchPacer). A
    /// 429 throws `ESVRateLimited` with how long the API asked to wait.
    public func esvSearch(_ query: String, pageSize: Int = 20) async throws -> [ESVSearchResult] {
        guard let key = keys.esv else { throw BibleError.missingKey("ESV API") }
        var request = URLRequest(url: Self.esvSearchURL(query: query, pageSize: pageSize), timeoutInterval: 10)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 429 {
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ESVRateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(status) else {
            throw BibleError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try Self.esvSearchResults(from: data)
    }

    static func esvSearchURL(query: String, pageSize: Int) -> URL {
        var components = URLComponents(string: "https://api.esv.org/v3/passage/search/")!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "page-size", value: String(pageSize)),
        ]
        return components.url!
    }

    static func esvSearchResults(from data: Data) throws -> [ESVSearchResult] {
        struct Response: Decodable { var results: [ESVSearchResult]? }
        return try JSONDecoder().decode(Response.self, from: data).results ?? []
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BibleError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
