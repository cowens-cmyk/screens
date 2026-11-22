import Foundation
import UniformTypeIdentifiers

/// Pairs a picture made for the room with the pictures made for the other
/// screens by file name, so a folder exported as "Slide01_Wide",
/// "Slide01_LowerThird" and "Slide01_SideTVs" becomes slides that already
/// know what the livestream and the side TVs show, with no question to
/// answer for each one.
///
/// The names match on what's left once the ending is taken off: "_Wide"
/// on the room's picture (optional — "Slide01" pairs too), "_LowerThird"
/// on the stream's and "_SideTVs" (or "_SideTV") on the side TVs'. Case,
/// and a space or hyphen in place of the underscore, don't matter.
public enum LowerThirdPairing {

    /// Which screen a picture was made for.
    public enum Role: Equatable, Sendable {
        /// The room's: it becomes the slide.
        case room
        /// The livestream's lower third, over the camera.
        case lowerThird
        /// The side TVs', in place of the room's picture.
        case sideTVs
    }

    public struct Name: Equatable, Sendable {
        /// What the set has in common, lowercased: "slide01".
        public var key: String
        public var role: Role

        public var isLowerThird: Bool { role == .lowerThird }
        /// Made for another screen, so it goes on a slide, not in place of one.
        public var isPartner: Bool { role != .room }

        public init(key: String, role: Role) {
            self.key = key
            self.role = role
        }

        public init(key: String, isLowerThird: Bool) {
            self.init(key: key, role: isLowerThird ? .lowerThird : .room)
        }
    }

    private static let lowerThirdEnding = try! NSRegularExpression(
        pattern: #"^(.*?)[\s_.-]*lower[\s_-]?thirds?$"#, options: [.caseInsensitive])
    private static let sideTVsEnding = try! NSRegularExpression(
        pattern: #"^(.*?)[\s_.-]*side[\s_-]?tvs?$"#, options: [.caseInsensitive])
    private static let wideEnding = try! NSRegularExpression(
        pattern: #"^(.*?)[\s_.-]+wide$"#, options: [.caseInsensitive])

    /// A file or media name read for pairing; nil when nothing's left to
    /// pair on.
    public static func name(_ raw: String) -> Name? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let ext = (text as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext),
           type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
            text = (text as NSString).deletingPathExtension
        }
        var role = Role.room
        if let base = stem(text, lowerThirdEnding) {
            text = base
            role = .lowerThird
        } else if let base = stem(text, sideTVsEnding) {
            text = base
            role = .sideTVs
        } else if let base = stem(text, wideEnding) {
            text = base
        }
        let key = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "_.-"))).lowercased()
        return key.isEmpty ? nil : Name(key: key, role: role)
    }

    private static func stem(_ text: String, _ pattern: NSRegularExpression) -> String? {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var name: String
        /// Only a picture can go over the camera.
        public var isImage: Bool

        public init(id: String, name: String, isImage: Bool) {
            self.id = id
            self.name = name
            self.isImage = isImage
        }
    }

    public struct Plan: Equatable, Sendable {
        /// The dropped media that become slides, in the order dropped.
        public var slideMedia: [String] = []
        /// A new slide's media → its lower third's media.
        public var lowerThirds: [String: String] = [:]
        /// A new slide's media → its side TVs picture.
        public var sideTVs: [String: String] = [:]
        /// A slide already in the presentation → the lower third dropped
        /// for it.
        public var existingSlides: [String: String] = [:]
        /// A slide already in the presentation → the side TVs picture
        /// dropped for it.
        public var existingSideTVs: [String: String] = [:]
    }

    /// What a drop makes: each lower third or side TVs picture goes on the
    /// dropped picture with its name, else on a slide already in the
    /// presentation with its name, and only if neither is there does it
    /// become a slide of its own. `existing` is the presentation's slides
    /// as (id, name).
    public static func plan(dropped: [Item], existing: [(id: String, name: String)] = []) -> Plan {
        var plan = Plan()
        // Role → key → the first picture dropped for it.
        var partnerFor: [Role: [String: String]] = [:]
        for item in dropped where item.isImage {
            if let name = name(item.name), name.isPartner, partnerFor[name.role]?[name.key] == nil {
                partnerFor[name.role, default: [:]][name.key] = item.id
            }
        }
        func isPartner(_ item: Item, _ name: Name?) -> Bool {
            guard let name, name.isPartner else { return false }
            return partnerFor[name.role]?[name.key] == item.id
        }
        var used = Set<String>()
        for item in dropped {
            let name = name(item.name)
            if isPartner(item, name) { continue }
            plan.slideMedia.append(item.id)
            guard let name, !name.isPartner else { continue }
            if let lowerThird = partnerFor[.lowerThird]?[name.key] {
                plan.lowerThirds[item.id] = lowerThird
                used.insert(lowerThird)
            }
            if let side = partnerFor[.sideTVs]?[name.key] {
                plan.sideTVs[item.id] = side
                used.insert(side)
            }
        }
        for slide in existing {
            guard let name = name(slide.name), !name.isPartner else { continue }
            if let lowerThird = partnerFor[.lowerThird]?[name.key], !used.contains(lowerThird) {
                plan.existingSlides[slide.id] = lowerThird
            }
            if let side = partnerFor[.sideTVs]?[name.key], !used.contains(side) {
                plan.existingSideTVs[slide.id] = side
            }
        }
        // A partner picture with nothing to go on is an ordinary slide, in
        // the place it was dropped.
        let placed = used.union(plan.existingSlides.values).union(plan.existingSideTVs.values)
        let slides = Set(plan.slideMedia)
        let partners = Set(partnerFor.values.flatMap(\.values))
        plan.slideMedia = dropped.map(\.id).filter { id in
            slides.contains(id) || (partners.contains(id) && !placed.contains(id))
        }
        return plan
    }

    /// The dropped files plus the lower thirds and side TVs pictures beside
    /// them in their folders that weren't dropped, so dropping only the
    /// "_Wide" pictures still brings each one's partners. `contents` lists
    /// a folder.
    public static func addingPartners(
        to urls: [URL], contents: (URL) -> [URL] = { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
    ) -> [URL] {
        let dropped = Set(urls.map(\.standardizedFileURL))
        var wanted: [URL: Set<String>] = [:]
        for url in urls where !url.hasDirectoryPath {
            guard let name = name(url.lastPathComponent), !name.isPartner else { continue }
            wanted[url.deletingLastPathComponent().standardizedFileURL, default: []].insert(name.key)
        }
        var partners: [URL] = []
        for (folder, keys) in wanted.sorted(by: { $0.key.path < $1.key.path }) {
            for file in contents(folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = file.standardizedFileURL
                guard !dropped.contains(file),
                      UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
                      let name = name(file.lastPathComponent), name.isPartner, keys.contains(name.key)
                else { continue }
                partners.append(file)
            }
        }
        return urls + partners
    }
}
