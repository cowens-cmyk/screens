import Foundation

/// Reads the setlists out of an Anthem session file (`Sunday.anthem`), the
/// one file the band uses to move a whole session between Macs. Screens
/// needs only what Anthem's network feed would have said about each
/// setlist: the songs in order and the sections each one plays. The file
/// carries no lyrics; those still come from the library or Shepherd.
///
/// The file is a ZIP64 archive with every entry stored (Anthem decision
/// 0060): `session.json` first, each song at `songs/<id>/song.json`, then
/// the audio. Only the JSON entries are read, so a session of several GB
/// opens as fast as a small one.
///
/// The section order is worked out as Anthem's show feed does it
/// (`ShowFeedMapping.arrangement` there): the entry's layout, else the
/// song's default; section IDs the song no longer has are skipped; an
/// empty order plays every section once by start beat.
public enum AnthemSessionFile {
    /// The newest session format this reader understands.
    public static let formatVersion = 2
    public static let fileExtension = "anthem"

    public struct SetlistInfo: Equatable, Sendable {
        public var setlist: AnthemShow.Setlist
        /// The Shepherd plan's start, when Anthem made the setlist from one.
        public var planDate: Date?
        public var shepherdPlanID: String?

        public init(setlist: AnthemShow.Setlist, planDate: Date? = nil, shepherdPlanID: String? = nil) {
            self.setlist = setlist
            self.planDate = planDate
            self.shepherdPlanID = shepherdPlanID
        }
    }

    public enum ReadError: Error, Equatable, LocalizedError {
        case notASession
        case newerFormat(Int, app: String)
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .notASession:
                "This isn't an Anthem session file."
            case let .newerFormat(version, app):
                "This session was saved by Anthem \(app.isEmpty ? "" : "\(app) ")(format \(version)). Update Screens to read it."
            case let .damaged(detail):
                "The session file is incomplete or damaged (\(detail)). Copy it again."
            }
        }
    }

    /// Every setlist in the file, the one Anthem had open first.
    public static func read(_ url: URL) throws -> [SetlistInfo] {
        let archive = try StoredArchive(url: url)
        guard let session = try archive.data(named: "session.json") else { throw ReadError.notASession }
        return try setlists(sessionJSON: session) { path in try? archive.data(named: path) }
    }

    /// The setlists from `session.json`, each song's document read through
    /// `song` by its path in the archive.
    public static func setlists(sessionJSON: Data, song: (String) throws -> Data?) throws -> [SetlistInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(lenientDate)
        guard let session = try? decoder.decode(SessionDoc.self, from: sessionJSON) else { throw ReadError.notASession }
        guard session.formatVersion >= 1 else { throw ReadError.notASession }
        guard session.formatVersion <= formatVersion else {
            throw ReadError.newerFormat(session.formatVersion, app: session.appVersion ?? "")
        }
        var songs: [String: SongDoc.Song] = [:]
        for listed in session.songs ?? [] {
            let key = listed.id.uppercased()
            guard songs[key] == nil, let data = try song(listed.document),
                  let document = try? JSONDecoder().decode(SongDoc.self, from: data) else { continue }
            songs[key] = document.song
        }
        let links = session.shepherdLinks ?? []
        return ([session.setlist] + (session.additionalSetlists ?? [])).map { setlist in
            let link = links.first { $0.setlistID?.uppercased() == setlist.id.uppercased() }
            return SetlistInfo(
                setlist: AnthemShow.Setlist(
                    id: setlist.id, name: setlist.name ?? "",
                    entries: (setlist.entries ?? []).map { entry($0, song: songs[$0.songID.uppercased()]) }),
                planDate: link?.planDate, shepherdPlanID: link?.planID)
        }
    }

    // MARK: - One entry, as Anthem's show feed sends it

    static func entry(_ entry: SessionDoc.Entry, song: SongDoc.Song?) -> AnthemShow.Entry {
        if let placeholder = entry.placeholder {
            return AnthemShow.Entry(entryId: entry.id, songId: nil, title: placeholder.title,
                                    ccli: clean(placeholder.ccliNumber),
                                    key: placeholder.planKey.flatMap { Key(parsing: $0) }?.name(.conventional))
        }
        guard let song else {
            return AnthemShow.Entry(entryId: entry.id, songId: entry.songID, title: "Missing song")
        }
        let offset = max(-12, min(12, entry.keyOffsetOverride ?? song.playbackKeyOffsetSemitones ?? 0))
        let key = song.originalKey.flatMap { Key(parsing: $0) }?
            .transposed(by: offset).name(Spelling(rawValue: song.accidentalPreference ?? "") ?? .conventional)
        return AnthemShow.Entry(entryId: entry.id, songId: entry.songID, title: song.title ?? "",
                                ccli: clean(song.ccliNumber), key: key,
                                arrangement: arrangement(of: song, layoutID: entry.arrangementID))
    }

    static func arrangement(of song: SongDoc.Song, layoutID: String?) -> AnthemShow.Arrangement {
        let defaultID = song.defaultArrangementID ?? song.id
        let saved = layoutID.flatMap { id in
            id.uppercased() == defaultID.uppercased() ? nil
                : song.savedArrangements?.first { $0.id.uppercased() == id.uppercased() }
        }
        let layout = saved.map { (id: $0.id, name: $0.name ?? "", order: $0.order ?? []) }
            ?? (id: defaultID, name: song.defaultArrangementName ?? "Main", order: song.arrangement ?? [])
        let sections = song.sections ?? []
        var byID: [String: SongDoc.Section] = [:]
        for section in sections { byID[section.id.uppercased()] = section }
        var performed = layout.order.compactMap { byID[$0.uppercased()] }
        if performed.isEmpty {
            performed = sections.enumerated()
                .sorted { ($0.element.startBeat ?? 0, $0.offset) < ($1.element.startBeat ?? 0, $1.offset) }
                .map(\.element)
        }
        var seen: [String: Int] = [:]
        return AnthemShow.Arrangement(id: layout.id, name: layout.name, sections: performed.map { section in
            let name = section.displayName
            let nameKey = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let occurrence = (seen[nameKey] ?? 0) + 1
            seen[nameKey] = occurrence
            return AnthemShow.Section(sectionId: section.id, name: name, kind: section.kind, occurrence: occurrence)
        })
    }

    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Anthem writes ISO 8601 without fractional seconds; take either.
    private static func lenientDate(_ decoder: Decoder) throws -> Date {
        let text = try decoder.singleValueContainer().decode(String.self)
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
    }

    // MARK: - Keys, spelled as Anthem spells them

    enum Spelling: String { case conventional, sharps, flats }

    struct Key: Equatable {
        var pitchClass: Int
        var minor: Bool

        /// "Bb", "F#m", "C♯ minor", "Ebmaj".
        init?(parsing text: String) {
            var rest = Substring(text.trimmingCharacters(in: .whitespaces))
            guard let letter = rest.first?.uppercased(),
                  let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter] else { return nil }
            rest = rest.dropFirst()
            var shift = 0
            for _ in 0..<2 {
                if let mark = rest.first, "#♯".contains(mark) { shift += 1; rest = rest.dropFirst() }
                else if let mark = rest.first, "b♭".contains(mark) { shift -= 1; rest = rest.dropFirst() }
            }
            // "M" is major and "m" minor, so case matters only for those.
            let mode = rest.trimmingCharacters(in: .whitespaces)
            switch mode == "M" ? "maj" : mode.lowercased() {
            case "", "maj", "major": minor = false
            case "m", "-", "min", "minor": minor = true
            default: return nil
            }
            pitchClass = ((base + shift) % 12 + 12) % 12
        }

        init(pitchClass: Int, minor: Bool) {
            self.pitchClass = pitchClass
            self.minor = minor
        }

        func transposed(by semitones: Int) -> Key {
            Key(pitchClass: ((pitchClass + semitones) % 12 + 12) % 12, minor: minor)
        }

        func name(_ spelling: Spelling) -> String {
            let sharp = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][pitchClass]
            let flat = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"][pitchClass]
            let root: String
            switch spelling {
            case .sharps: root = sharp
            case .flats: root = flat
            case .conventional:
                // Major keys are spelled with flats but F#; minor keys with
                // sharps but Eb and Bb.
                root = minor ? ([3, 10].contains(pitchClass) ? flat : sharp) : (pitchClass == 6 ? sharp : flat)
            }
            return minor ? root + "m" : root
        }
    }

    // MARK: - The JSON, only what is read

    struct SessionDoc: Decodable {
        var formatVersion: Int
        var appVersion: String?
        var setlist: Setlist
        var additionalSetlists: [Setlist]?
        var songs: [ListedSong]?
        var shepherdLinks: [ShepherdLink]?

        struct Setlist: Decodable {
            var id: String
            var name: String?
            var entries: [Entry]?
        }

        struct Entry: Decodable {
            var id: String
            var songID: String
            var keyOffsetOverride: Int?
            var arrangementID: String?
            var placeholder: Placeholder?

            enum CodingKeys: String, CodingKey { case id, songID, keyOffsetOverride, arrangementID, placeholder }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                songID = try c.decode(String.self, forKey: .songID)
                keyOffsetOverride = try? c.decodeIfPresent(Int.self, forKey: .keyOffsetOverride)
                arrangementID = try? c.decodeIfPresent(String.self, forKey: .arrangementID)
                // Anthem reads a malformed placeholder as none; so does this.
                placeholder = try? c.decodeIfPresent(Placeholder.self, forKey: .placeholder)
            }
        }

        struct Placeholder: Decodable {
            var title: String
            var ccliNumber: String?
            var planKey: String?
        }

        struct ListedSong: Decodable {
            var id: String
            var document: String
        }

        struct ShepherdLink: Decodable {
            var planID: String?
            var setlistID: String?
            var planDate: Date?

            enum CodingKeys: String, CodingKey { case planID, setlistID, planDate }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                planID = try? c.decodeIfPresent(String.self, forKey: .planID)
                setlistID = try? c.decodeIfPresent(String.self, forKey: .setlistID)
                planDate = try? c.decodeIfPresent(Date.self, forKey: .planDate)
            }
        }
    }

    struct SongDoc: Decodable {
        var song: Song

        struct Song: Decodable {
            var id: String
            var title: String?
            var ccliNumber: String?
            var originalKey: String?
            var playbackKeyOffsetSemitones: Int?
            var accidentalPreference: String?
            var sections: [Section]?
            var arrangement: [String]?
            var savedArrangements: [Layout]?
            var defaultArrangementID: String?
            var defaultArrangementName: String?
        }

        struct Section: Decodable {
            var id: String
            var name: String?
            var kind: String?
            var startBeat: Double?

            /// A section with no name is called by its kind, as in Anthem.
            var displayName: String {
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
                return [
                    "intro": "Intro", "verse": "Verse", "preChorus": "Pre-Chorus", "chorus": "Chorus",
                    "postChorus": "Post-Chorus", "bridge": "Bridge", "instrumental": "Instrumental",
                    "interlude": "Interlude", "tag": "Tag", "vamp": "Vamp", "turnaround": "Turnaround",
                    "breakdown": "Breakdown", "outro": "Outro",
                ][kind ?? ""] ?? "Section"
            }
        }

        struct Layout: Decodable {
            var id: String
            var name: String?
            var order: [String]?
        }
    }

    // MARK: - The archive

    /// A ZIP with stored entries, read one entry at a time. Anthem always
    /// writes ZIP64 records; a plain ZIP (an archive rezipped by hand) is
    /// read too.
    struct StoredArchive {
        private let handle: FileHandle
        private let length: UInt64
        private var entries: [String: (offset: UInt64, size: UInt64, method: UInt16)] = [:]
        /// Larger than any session or song document; a bigger entry under
        /// those names is not one Anthem wrote.
        static let documentLimit: UInt64 = 64 << 20

        init(url: URL) throws {
            do { handle = try FileHandle(forReadingFrom: url) } catch { throw ReadError.notASession }
            length = (try? handle.seekToEnd()) ?? 0
            guard length >= 22 else { throw ReadError.notASession }
            let tailLength = min(length, 66_000)
            let tail = try read(at: length - tailLength, count: Int(tailLength))
            // The end record is the last "PK\5\6" whose comment reaches the end.
            var eocd: Int?
            var index = tail.count - 22
            while index >= 0 {
                if tail.u32(index) == 0x0605_4b50, index + 22 + Int(tail.u16(index + 20)) == tail.count {
                    eocd = index
                    break
                }
                index -= 1
            }
            guard let eocd else { throw ReadError.notASession }
            var count = UInt64(tail.u16(eocd + 10))
            var directorySize = UInt64(tail.u32(eocd + 12))
            var directoryOffset = UInt64(tail.u32(eocd + 16))
            if eocd >= 20, tail.u32(eocd - 20) == 0x0706_4b50 {
                let recordOffset = tail.u64(eocd - 20 + 8)
                let record = try read(at: recordOffset, count: 56)
                guard record.u32(0) == 0x0606_4b50 else { throw ReadError.damaged("end record") }
                count = record.u64(32)
                directorySize = record.u64(40)
                directoryOffset = record.u64(48)
            }
            guard directoryOffset + directorySize <= length, directorySize < 256 << 20 else {
                throw ReadError.damaged("directory")
            }
            let directory = try read(at: directoryOffset, count: Int(directorySize))
            var at = 0
            for _ in 0..<count {
                guard at + 46 <= directory.count, directory.u32(at) == 0x0201_4b50 else {
                    throw ReadError.damaged("directory")
                }
                let method = directory.u16(at + 10)
                var size = UInt64(directory.u32(at + 20))
                var uncompressed = UInt64(directory.u32(at + 24))
                let nameLength = Int(directory.u16(at + 28))
                let extraLength = Int(directory.u16(at + 30))
                let commentLength = Int(directory.u16(at + 32))
                var offset = UInt64(directory.u32(at + 42))
                guard at + 46 + nameLength + extraLength <= directory.count else { throw ReadError.damaged("directory") }
                let name = String(decoding: directory[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
                // ZIP64 extra: the values whose field is 0xFFFFFFFF, in order.
                var extra = at + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd {
                    let id = directory.u16(extra)
                    let fieldLength = Int(directory.u16(extra + 2))
                    if id == 0x0001 {
                        var field = extra + 4
                        if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd { uncompressed = directory.u64(field); field += 8 }
                        if size == 0xFFFF_FFFF, field + 8 <= extraEnd { size = directory.u64(field); field += 8 }
                        if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = directory.u64(field) }
                    }
                    extra += 4 + fieldLength
                }
                if method == 0, size != uncompressed { throw ReadError.damaged(name) }
                entries[name] = (offset, size, method)
                at += 46 + nameLength + extraLength + commentLength
            }
        }

        /// The entry's bytes, nil when the archive has no such entry.
        func data(named name: String) throws -> Data? {
            guard let entry = entries[name] else { return nil }
            guard entry.method == 0 else { throw ReadError.damaged("\(name) is compressed") }
            guard entry.size <= Self.documentLimit else { throw ReadError.damaged("\(name) is too large") }
            let header = try read(at: entry.offset, count: 30)
            guard header.u32(0) == 0x0403_4b50 else { throw ReadError.damaged(name) }
            let start = entry.offset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
            guard start + entry.size <= length else { throw ReadError.damaged(name) }
            return try read(at: start, count: Int(entry.size))
        }

        private func read(at offset: UInt64, count: Int) throws -> Data {
            guard offset + UInt64(count) <= length else { throw ReadError.damaged("cut short") }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ReadError.damaged("cut short") }
            return data
        }
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        UInt32(u16(at)) | UInt32(u16(at + 2)) << 16
    }

    func u64(_ at: Int) -> UInt64 {
        UInt64(u32(at)) | UInt64(u32(at + 4)) << 32
    }
}
