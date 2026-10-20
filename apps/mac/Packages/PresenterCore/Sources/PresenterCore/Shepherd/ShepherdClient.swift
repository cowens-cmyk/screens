import Foundation

/// Shepherd's church-wide service API, authenticated with a connected-app key.
public struct ShepherdClient: Sendable {
    public var baseURL: URL
    private let apiKey: String
    public var session: URLSession

    // Kept internal so tests can observe backoff without waiting or using the network.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(
        baseURL: URL = URL(string: "https://shepherd.hopejc.org/api/v1")!,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public struct Ping: Codable, Hashable, Sendable {
        public var ok: Bool
        public var app: String
        public var scopes: [String]
        public var apiVersion: Int
    }

    public struct ServiceType: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
    }

    public struct PlanTime: Codable, Hashable, Sendable {
        public var kind: String
        public var label: String?
        public var startsAt: Date?
        public var endsAt: Date?
    }

    public struct Plans: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var plans: [PlanSummary]
    }

    public struct PlanSummary: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var serviceType: ServiceType
        public var title: String?
        public var series: String?
        public var seriesArtUrl: String?
        public var startsAt: Date?
        public var location: String?
        public var times: [PlanTime]
        public var lengthSeconds: Int?
        public var liveItemId: String?
        public var liveAt: Date?
        public var updatedAt: Date
    }

    public struct PlanDetail: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var serviceType: ServiceType
        public var title: String?
        public var series: String?
        public var seriesArtUrl: String?
        public var startsAt: Date?
        public var location: String?
        public var times: [PlanTime]
        public var lengthSeconds: Int?
        public var liveItemId: String?
        public var liveAt: Date?
        public var updatedAt: Date
        public var files: [File]
        public var items: [Item]
    }

    public struct File: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var contentType: String
        public var size: Int
        public var createdAt: Date
        public var arrangementId: String?
        public var key: String?
        public var keys: [String]?
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var position: Int
        public var kind: String
        public var title: String
        public var description: String?
        public var lengthSeconds: Int?
        public var startsAt: Date?
        public var song: PlanSong?
        public var files: [File]
    }

    public struct MediaLink: Codable, Hashable, Sendable {
        public var service: String
        public var url: String
    }

    public struct PlanSong: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var author: String?
        public var ccliNumber: String?
        public var copyright: String?
        public var key: String?
        public var arrangementId: String?
        public var arrangement: String?
        public var tempo: Double?
        public var timeSignature: String?
        public var sequence: [String]
        public var mediaLinks: [MediaLink]
    }

    public struct SongDetail: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var author: String?
        public var ccliNumber: String?
        public var copyright: String?
        public var themes: [String]
        public var defaultKey: String?
        public var tempo: Double?
        public var timeSignature: String?
        public var sequence: [String]
        public var archived: Bool
        public var keys: [SongKey]
        public var arrangements: [SongArrangement]
        public var mediaLinks: [MediaLink]
        public var updatedAt: Date
        public var lyrics: String?
        public var chordChart: String?
        public var files: [File]
    }

    public struct SongKey: Codable, Hashable, Sendable {
        public var key: String
        public var description: String?
    }

    public struct SongArrangement: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var tempo: Double?
        public var timeSignature: String?
        public var lengthSeconds: Int?
        public var sequence: [String]
        public var chordChart: String?
        public var mediaLinks: [MediaLink]
    }

    // MARK: Requests

    public func ping() async throws -> Ping {
        try await get("ping")
    }

    /// Inclusive dates in the church's calendar, formatted YYYY-MM-DD.
    public func plans(
        from: String? = nil, to: String? = nil, serviceType: String? = nil
    ) async throws -> [PlanSummary] {
        let query = [
            from.map { URLQueryItem(name: "from", value: $0) },
            to.map { URLQueryItem(name: "to", value: $0) },
            serviceType.map { URLQueryItem(name: "service_type", value: $0) },
        ].compactMap { $0 }
        let document: Plans = try await get("services/plans", query: query)
        return document.plans
    }

    public func plan(id: String) async throws -> PlanDetail {
        try await get("services/plans/\(try checkedID(id))")
    }

    public func song(id: String) async throws -> SongDetail {
        try await get("services/songs/\(try checkedID(id))")
    }

    private func checkedID(_ id: String) throws -> String {
        guard !id.isEmpty, id != ".", id != "..",
              id.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#%")) == nil else {
            throw ShepherdError.invalidRequest
        }
        return id
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date.")
        }
        return decoder
    }

    private func get<Response: Decodable>(
        _ path: String, query: [URLQueryItem] = []
    ) async throws -> Response {
        guard !apiKey.isEmpty else { throw ShepherdError.notConfigured }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else { throw ShepherdError.invalidRequest }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ShepherdError.invalidRequest }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0...3 {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                // Never forward underlying errors or response bodies: they may echo credentials.
                throw ShepherdError.connection
            }
            guard let response = response as? HTTPURLResponse else {
                throw ShepherdError.invalidResponse
            }
            let status = response.statusCode
            if (status == 429 || (500...599).contains(status)), attempt < 3 {
                try await sleep(.seconds(1 << attempt))
                continue
            }
            guard (200..<300).contains(status) else { throw ShepherdError.http(status) }
            do {
                return try Self.decoder().decode(Response.self, from: data)
            } catch {
                throw ShepherdError.invalidResponse
            }
        }
        throw ShepherdError.invalidResponse
    }
}

public enum ShepherdError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidRequest
    case connection
    case invalidResponse
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Shepherd API key in Settings."
        case .invalidRequest: "Check the Shepherd address and request."
        case .connection: "Could not connect to Shepherd. Try again."
        case .invalidResponse: "Shepherd sent an unreadable response. Try again."
        case .http(401): "Shepherd rejected the key. It may have been rotated or disabled."
        case .http(403): "This key is missing the services:read scope. Ask the church to add it."
        case .http(404): "This Shepherd item could not be found."
        case .http(429): "Shepherd is busy. Wait a moment and try again."
        case .http(500...599): "Shepherd is having trouble. Try again shortly."
        case .http: "Shepherd could not complete the request."
        }
    }
}
