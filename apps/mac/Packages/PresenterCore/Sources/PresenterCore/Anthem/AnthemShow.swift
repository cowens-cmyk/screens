import Foundation

/// What Anthem's read-only show feed answers (Bonjour `_anthem-show._tcp`,
/// port 7731 by default). Anthem leads: Screens reads the setlist and each
/// song's performed section order so its own arrangements can match.
///
///   GET /v1/info              {"app","version","feed"}
///   GET /v1/setlist/active    the setlist, or 404 {"error":"no active setlist"}
///   GET /v1/status            what is live and cued, while a song plays
public enum AnthemShow {
    public static let serviceType = "_anthem-show._tcp"
    public static let defaultPort: UInt16 = 7731
    /// The feed version this build understands; a newer feed may add fields.
    public static let feedVersion = 1

    public struct Info: Codable, Equatable, Sendable {
        public var app: String
        public var version: String?
        public var feed: Int?

        public init(app: String, version: String? = nil, feed: Int? = nil) {
            self.app = app
            self.version = version
            self.feed = feed
        }
    }

    public struct Setlist: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var entries: [Entry]

        public init(id: String, name: String, entries: [Entry]) {
            self.id = id
            self.name = name
            self.entries = entries
        }
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var entryId: String
        public var songId: String?
        public var title: String
        public var ccli: String?
        public var key: String?
        public var bpm: Double?
        public var arrangement: Arrangement?

        public var id: String { entryId }

        public init(
            entryId: String, songId: String? = nil, title: String, ccli: String? = nil,
            key: String? = nil, bpm: Double? = nil, arrangement: Arrangement? = nil
        ) {
            self.entryId = entryId
            self.songId = songId
            self.title = title
            self.ccli = ccli
            self.key = key
            self.bpm = bpm
            self.arrangement = arrangement
        }

        enum CodingKeys: String, CodingKey {
            case entryId, songId, title, ccli, key, bpm, arrangement
        }

        // CCLI is a string in the contract; a number is taken too, so a
        // feed that sends 7104200 bare still matches.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entryId = try c.decode(String.self, forKey: .entryId)
            songId = try c.decodeIfPresent(String.self, forKey: .songId)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            if let text = try? c.decodeIfPresent(String.self, forKey: .ccli) {
                ccli = text
            } else if let number = try? c.decodeIfPresent(Int.self, forKey: .ccli) {
                ccli = String(number)
            } else {
                ccli = nil
            }
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            bpm = try? c.decodeIfPresent(Double.self, forKey: .bpm)
            arrangement = try c.decodeIfPresent(Arrangement.self, forKey: .arrangement)
        }

        /// The CCLI song number, digits only ("CCLI 7104200" → 7104200).
        public var ccliNumber: Int? {
            guard let ccli else { return nil }
            let digits = ccli.filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }
    }

    public struct Arrangement: Codable, Equatable, Sendable {
        public var id: String?
        public var name: String?
        public var sections: [Section]

        public init(id: String? = nil, name: String? = nil, sections: [Section]) {
            self.id = id
            self.name = name
            self.sections = sections
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var sectionId: String?
        public var name: String
        public var kind: String?
        /// 1-based count of this name so far in the performed order.
        public var occurrence: Int?
        public var lengthSeconds: Double?

        public init(
            sectionId: String? = nil, name: String, kind: String? = nil,
            occurrence: Int? = nil, lengthSeconds: Double? = nil
        ) {
            self.sectionId = sectionId
            self.name = name
            self.kind = kind
            self.occurrence = occurrence
            self.lengthSeconds = lengthSeconds
        }
    }

    public struct Status: Codable, Equatable, Sendable {
        public var setlistId: String?
        public var liveEntryId: String?
        public var cuedEntryId: String?
        public var playing: Bool?
        public var positionSeconds: Double?
        public var sectionIndex: Int?
        public var sectionName: String?

        public init(
            setlistId: String? = nil, liveEntryId: String? = nil, cuedEntryId: String? = nil,
            playing: Bool? = nil, positionSeconds: Double? = nil, sectionIndex: Int? = nil,
            sectionName: String? = nil
        ) {
            self.setlistId = setlistId
            self.liveEntryId = liveEntryId
            self.cuedEntryId = cuedEntryId
            self.playing = playing
            self.positionSeconds = positionSeconds
            self.sectionIndex = sectionIndex
            self.sectionName = sectionName
        }

        /// A song is live: poll status quickly only then.
        public var songIsLive: Bool { liveEntryId != nil || playing == true }
    }

    /// The setlist answer: a 404 means Anthem is up with nothing loaded,
    /// which is not an error worth showing.
    public enum SetlistAnswer: Equatable, Sendable {
        case setlist(Setlist)
        case none
    }

    public enum DecodeError: Error, Equatable {
        case status(Int)
        case notAnthem
    }

    public static func decodeInfo(_ data: Data) throws -> Info {
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.app.caseInsensitiveCompare("Anthem") == .orderedSame else { throw DecodeError.notAnthem }
        return info
    }

    public static func decodeSetlist(_ data: Data, status: Int) throws -> SetlistAnswer {
        if status == 404 { return .none }
        guard (200..<300).contains(status) else { throw DecodeError.status(status) }
        return .setlist(try JSONDecoder().decode(Setlist.self, from: data))
    }

    public static func decodeStatus(_ data: Data, status: Int) throws -> Status {
        guard (200..<300).contains(status) else { throw DecodeError.status(status) }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    /// The plain HTTP request Screens sends. HTTP/1.0 so the answer comes
    /// whole and the connection closes when it is done.
    public static func request(path: String, host: String) -> Data {
        Data("GET \(path) HTTP/1.0\r\nHost: \(host)\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8)
    }

    /// Status and body of a whole HTTP response, chunked or not.
    public static func parseResponse(_ data: Data) -> (status: Int, body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: separator),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else { return nil }
        var body = Data(data[split.upperBound...])
        let chunked = lines.dropFirst().contains {
            let lower = $0.lowercased()
            return lower.hasPrefix("transfer-encoding:") && lower.contains("chunked")
        }
        if chunked {
            var decoded = Data()
            var rest = body[...]
            let lineEnd = Data("\r\n".utf8)
            while let end = rest.range(of: lineEnd),
                  let sizeLine = String(data: rest[..<end.lowerBound], encoding: .utf8),
                  let size = Int(sizeLine.split(separator: ";").first.map(String.init)?
                      .trimmingCharacters(in: .whitespaces) ?? "", radix: 16) {
                guard size > 0 else { break }
                let start = end.upperBound
                guard rest.distance(from: start, to: rest.endIndex) >= size else { return nil }
                let stop = rest.index(start, offsetBy: size)
                decoded.append(rest[start..<stop])
                rest = rest[stop...]
                if rest.starts(with: lineEnd) { rest = rest.dropFirst(lineEnd.count) }
            }
            body = decoded
        }
        return (status, body)
    }

    /// "host", "host:port" or "http://host:port/" as typed in Settings.
    public static func endpoint(fromManual text: String) -> (host: String, port: UInt16)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where trimmed.lowercased().hasPrefix(scheme) {
            trimmed = String(trimmed.dropFirst(scheme.count))
        }
        trimmed = trimmed.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        // A bare IPv6 address has several colons and no port.
        if trimmed.filter({ $0 == ":" }).count > 1 {
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                let rest = trimmed[trimmed.index(after: close)...]
                if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) { return (host, port) }
                return host.isEmpty ? nil : (host, defaultPort)
            }
            return (trimmed, defaultPort)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first.map(String.init), !host.isEmpty else { return nil }
        if parts.count == 2 {
            guard let port = UInt16(parts[1]), port > 0 else { return nil }
            return (host, port)
        }
        return (host, defaultPort)
    }
}
