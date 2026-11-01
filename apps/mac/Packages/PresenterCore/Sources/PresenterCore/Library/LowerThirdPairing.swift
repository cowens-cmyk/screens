import Foundation
import UniformTypeIdentifiers

/// Pairs a picture made for the room with the lower third made for the
/// livestream by file name, so a folder exported as "Slide01_Wide" and
/// "Slide01_LowerThird" becomes slides that already know what the stream
/// shows, with no question to answer for each one.
///
/// The names match on what's left once the ending is taken off: "_Wide"
/// on the room's picture (optional — "Slide01" pairs too) and
/// "_LowerThird" on the stream's. Case, and a space or hyphen in place of
/// the underscore, don't matter.
public enum LowerThirdPairing {

    public struct Name: Equatable, Sendable {
        /// What the pair has in common, lowercased: "slide01".
        public var key: String
        public var isLowerThird: Bool
    }

    private static let lowerThirdEnding = try! NSRegularExpression(
        pattern: #"^(.*?)[\s_.-]*lower[\s_-]?thirds?$"#, options: [.caseInsensitive])
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
        var isLowerThird = false
        if let base = stem(text, lowerThirdEnding) {
            text = base
            isLowerThird = true
        } else if let base = stem(text, wideEnding) {
            text = base
        }
        let key = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "_.-"))).lowercased()
        return key.isEmpty ? nil : Name(key: key, isLowerThird: isLowerThird)
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
        /// A slide already in the presentation → the lower third dropped
        /// for it.
        public var existingSlides: [String: String] = [:]
    }

    /// What a drop makes: each lower third goes on the dropped picture with
    /// its name, else on a slide already in the presentation with its name,
    /// and only if neither is there does it become a slide of its own.
    /// `existing` is the presentation's slides as (id, name).
    public static func plan(dropped: [Item], existing: [(id: String, name: String)] = []) -> Plan {
        var plan = Plan()
        var lowerThirdFor: [String: String] = [:]
        for item in dropped where item.isImage {
            if let name = name(item.name), name.isLowerThird, lowerThirdFor[name.key] == nil {
                lowerThirdFor[name.key] = item.id
            }
        }
        var used = Set<String>()
        for item in dropped {
            let name = name(item.name)
            if let name, name.isLowerThird, lowerThirdFor[name.key] == item.id { continue }
            plan.slideMedia.append(item.id)
            if let name, !name.isLowerThird, let lowerThird = lowerThirdFor[name.key] {
                plan.lowerThirds[item.id] = lowerThird
                used.insert(lowerThird)
            }
        }
        for slide in existing {
            guard let name = name(slide.name), !name.isLowerThird,
                  let lowerThird = lowerThirdFor[name.key], !used.contains(lowerThird)
            else { continue }
            plan.existingSlides[slide.id] = lowerThird
        }
        // A lower third with nothing to go on is an ordinary slide, in the
        // place it was dropped.
        let placed = used.union(plan.existingSlides.values)
        let slides = Set(plan.slideMedia)
        let lowerThirds = Set(lowerThirdFor.values)
        plan.slideMedia = dropped.map(\.id).filter { id in
            slides.contains(id) || (lowerThirds.contains(id) && !placed.contains(id))
        }
        return plan
    }

    /// The dropped files plus the lower thirds beside them in their folders
    /// that weren't dropped, so dropping only the "_Wide" pictures still
    /// brings each one's lower third. `contents` lists a folder.
    public static func addingPartners(
        to urls: [URL], contents: (URL) -> [URL] = { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
    ) -> [URL] {
        let dropped = Set(urls.map(\.standardizedFileURL))
        var wanted: [URL: Set<String>] = [:]
        for url in urls where !url.hasDirectoryPath {
            guard let name = name(url.lastPathComponent), !name.isLowerThird else { continue }
            wanted[url.deletingLastPathComponent().standardizedFileURL, default: []].insert(name.key)
        }
        var partners: [URL] = []
        for (folder, keys) in wanted.sorted(by: { $0.key.path < $1.key.path }) {
            for file in contents(folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = file.standardizedFileURL
                guard !dropped.contains(file),
                      UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
                      let name = name(file.lastPathComponent), name.isLowerThird, keys.contains(name.key)
                else { continue }
                partners.append(file)
            }
        }
        return urls + partners
    }
}
