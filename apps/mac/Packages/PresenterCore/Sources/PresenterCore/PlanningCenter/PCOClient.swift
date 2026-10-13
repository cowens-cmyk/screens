import Foundation

/// A Planning Center Services client authenticated with a personal access
/// token (application id + secret, sent as HTTP basic auth).
public struct PCOClient: Sendable {
    public var appID: String
    public var secret: String
    public var session: URLSession
    public var baseURL = URL(string: "https://api.planningcenteronline.com/services/v2/")!

    public init(appID: String, secret: String, session: URLSession = .shared) {
        self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public var isConfigured: Bool { !appID.isEmpty && !secret.isEmpty }

    public struct ServiceType: Hashable, Sendable, Identifiable, Codable {
        public var id: String
        public var name: String
    }

    public struct Plan: Hashable, Sendable, Identifiable {
        public var id: String
        public var serviceTypeID: String
        public var title: String?
        public var seriesTitle: String?
        public var dates: String
        public var sortDate: Date?
        public var updatedAt: String
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var itemType: String
        public var sequence: Int
        public var description: String?
        public var keyName: String?
        public var length: Int?
        public var servicePosition: String?
        public var customArrangementSequence: [String]?
        public var updatedAt: String
        public var song: Song?
        public var arrangement: Arrangement?
        public var key: Key?
    }

    public struct Song: Hashable, Sendable {
        public var id: String
        public var title: String
        public var author: String?
        public var copyright: String?
        public var ccliNumber: Int?
    }

    public struct Arrangement: Hashable, Sendable {
        public var id: String
        public var name: String
        public var lyrics: String?
        public var chordChart: String?
        public var chordChartKey: String?
        public var sequence: [String]
        public var bpm: Double?
        public var meter: String?
        public var updatedAt: String?
    }

    public struct Key: Hashable, Sendable {
        public var id: String
        public var startingKey: String?
    }

    public enum PCOError: LocalizedError {
        case notConfigured
        case http(Int, String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Planning Center personal access token in Settings › Planning Center."
            case .http(401, _): "Planning Center rejected the token — check the Application ID and Secret."
            case .http(let code, let body): "Planning Center answered \(code). \(body.prefix(200))"
            }
        }
    }

    // MARK: Requests

    public func serviceTypes() async throws -> [ServiceType] {
        let documents = try await getAll("service_types", query: [.init(name: "order", value: "sequence")])
        return documents.flatMap(\.data).map { ServiceType(id: $0.id, name: $0.string("name") ?? "Service") }
    }

    /// Upcoming plans (today onward), soonest first.
    public func futurePlans(serviceTypeID: String, limit: Int) async throws -> [Plan] {
        let document = try await get(
            "service_types/\(serviceTypeID)/plans",
            query: [
                .init(name: "filter", value: "future"),
                .init(name: "order", value: "sort_date"),
                .init(name: "per_page", value: String(max(1, min(limit, 100)))),
            ])
        return document.data.map { resource in
            Plan(
                id: resource.id, serviceTypeID: serviceTypeID,
                title: resource.string("title"),
                seriesTitle: resource.string("series_title"),
                dates: resource.string("dates") ?? "",
                sortDate: resource.string("sort_date").flatMap(Self.parseDate),
                updatedAt: resource.string("updated_at") ?? "")
        }
    }

    public func items(serviceTypeID: String, planID: String) async throws -> [Item] {
        let documents = try await getAll(
            "service_types/\(serviceTypeID)/plans/\(planID)/items",
            query: [.init(name: "include", value: "song,arrangement,key")])
        var included: [String: Resource] = [:]
        for document in documents {
            for resource in document.included ?? [] { included["\(resource.type)/\(resource.id)"] = resource }
        }
        func related(_ resource: Resource, _ name: String) -> Resource? {
            guard let link = resource.relationships?[name]?.data else { return nil }
            return included["\(link.type)/\(link.id)"]
        }
        return documents.flatMap(\.data).map { resource in
            let song = related(resource, "song").map(Self.song)
            let arrangement = related(resource, "arrangement").map(Self.arrangement)
            let key = related(resource, "key").map { Key(id: $0.id, startingKey: $0.string("starting_key")) }
            return Item(
                id: resource.id,
                title: resource.string("title") ?? "",
                itemType: resource.string("item_type") ?? "item",
                sequence: resource.int("sequence") ?? 0,
                description: resource.string("description"),
                keyName: resource.string("key_name"),
                length: resource.int("length"),
                servicePosition: resource.string("service_position"),
                customArrangementSequence: resource.strings("custom_arrangement_sequence"),
                updatedAt: resource.string("updated_at") ?? "",
                song: song, arrangement: arrangement, key: key)
        }
        .sorted { $0.sequence < $1.sequence }
    }

    // MARK: Song library

    /// Songs whose title (or CCLI number, when the text is digits) matches.
    public func searchSongs(_ text: String) async throws -> [Song] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        func query(_ name: String, _ value: String) async throws -> [Song] {
            let document = try await get("songs", query: [
                .init(name: "where[\(name)]", value: value),
                .init(name: "order", value: "title"),
                .init(name: "per_page", value: "40"),
            ])
            return document.data.map(Self.song)
        }
        if term.allSatisfy(\.isNumber) { return try await query("ccli_number", term) }
        let plain = try await query("title", term)
        return plain.isEmpty ? try await query("title", "%\(term)%") : plain
    }

    public func arrangements(songID: String) async throws -> [Arrangement] {
        let documents = try await getAll("songs/\(songID)/arrangements", query: [])
        return documents.flatMap(\.data).map(Self.arrangement)
    }

    public func keys(songID: String, arrangementID: String) async throws -> [String] {
        let document = try await get("songs/\(songID)/arrangements/\(arrangementID)/keys", query: [])
        return document.data.compactMap { $0.string("starting_key") }
    }

    static func song(_ resource: Resource) -> Song {
        Song(
            id: resource.id, title: resource.string("title") ?? "",
            author: resource.string("author"), copyright: resource.string("copyright"),
            ccliNumber: resource.int("ccli_number"))
    }

    static func arrangement(_ resource: Resource) -> Arrangement {
        Arrangement(
            id: resource.id, name: resource.string("name") ?? "",
            lyrics: resource.string("lyrics"),
            chordChart: resource.string("chord_chart"),
            chordChartKey: resource.string("chord_chart_key"),
            sequence: resource.strings("sequence") ?? [],
            bpm: resource.double("bpm"),
            meter: resource.string("meter"),
            updatedAt: resource.string("updated_at"))
    }

    // MARK: JSON:API plumbing

    struct Document: Decodable {
        var data: [Resource]
        var included: [Resource]?
        var links: Links?
        struct Links: Decodable { var next: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let many = try? container.decode([Resource].self, forKey: .data) {
                data = many
            } else {
                data = [try container.decode(Resource.self, forKey: .data)]
            }
            included = try container.decodeIfPresent([Resource].self, forKey: .included)
            links = try container.decodeIfPresent(Links.self, forKey: .links)
        }
        enum CodingKeys: String, CodingKey { case data, included, links }
    }

    struct Resource: Decodable {
        var type: String
        var id: String
        var attributes: [String: JSONValue]?
        var relationships: [String: Relationship]?

        struct Relationship: Decodable {
            var data: Link?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                data = try? container.decodeIfPresent(Link.self, forKey: .data)
            }
            enum CodingKeys: String, CodingKey { case data }
        }
        struct Link: Decodable { var type: String; var id: String }

        func string(_ key: String) -> String? {
            if case .string(let value)? = attributes?[key] { return value }
            return nil
        }
        func int(_ key: String) -> Int? {
            switch attributes?[key] {
            case .number(let value)?: Int(value)
            case .string(let value)?: Int(value)
            default: nil
            }
        }
        func double(_ key: String) -> Double? {
            if case .number(let value)? = attributes?[key] { return value }
            return nil
        }
        func strings(_ key: String) -> [String]? {
            guard case .array(let values)? = attributes?[key] else { return nil }
            return values.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
    }

    enum JSONValue: Decodable {
        case string(String), number(Double), bool(Bool), array([JSONValue]), object, null
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object }
        }
    }

    private func getAll(_ path: String, query: [URLQueryItem]) async throws -> [Document] {
        var documents: [Document] = []
        var next: URL? = url(path, query: query + [.init(name: "per_page", value: "100")])
        while let url = next, documents.count < 20 {
            let document = try await fetch(url)
            documents.append(document)
            next = document.links?.next.flatMap(URL.init(string:))
        }
        return documents
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Document {
        try await fetch(url(path, query: query))
    }

    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return components.url!
    }

    private func fetch(_ url: URL) async throws -> Document {
        guard isConfigured else { throw PCOError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 20)
        let credentials = Data("\(appID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PCOError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Document.self, from: data)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
