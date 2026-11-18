import Foundation

/// The media a plan uses that can't play on this Mac, found when the plan is
/// opened so it's known before the service rather than when a cue goes up
/// black. Two ways a piece goes missing:
///
/// - **File missing**: the item is in the library but its file isn't in the
///   media folder (not downloaded yet, deleted from the folder, or on a drive
///   that's unplugged).
/// - **Deleted**: a slide or the plan still points at media that was deleted
///   from the library, or that never came in (a ProPresenter import whose
///   file wasn't found).
///
/// Files dropped into Screens are copied into its media folder, so cleaning
/// out Downloads or the Desktop never makes anything here.
public enum PlanMissingMedia {
    public enum Problem: Equatable, Sendable {
        case fileMissing
        case deleted
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public var id: String { mediaID }
        public var mediaID: String
        /// The media's name, or its name before it was deleted when known.
        public var name: String
        public var problem: Problem
        /// The plan items it's used in, in plan order.
        public var usedIn: [String]
        /// Music (the Audio library) rather than a picture or video.
        public var isAudio: Bool

        public init(mediaID: String, name: String, problem: Problem, usedIn: [String], isAudio: Bool = false) {
            self.mediaID = mediaID
            self.name = name
            self.problem = problem
            self.usedIn = usedIn
            self.isAudio = isAudio
        }
    }

    /// What one plan item uses: media and audio ids, from the item itself and
    /// from the presentation or playlist it points at.
    public struct ItemUse: Sendable {
        public var itemName: String
        public var mediaIDs: [String]
        public var audioIDs: [String]

        public init(itemName: String, mediaIDs: [String], audioIDs: [String] = []) {
            self.itemName = itemName
            self.mediaIDs = mediaIDs
            self.audioIDs = audioIDs
        }
    }

    /// The plan's presentations, for `uses`: every version's items, once.
    public static func presentationIDs(in service: Service) -> [String] {
        var seen = Set<String>()
        return ServiceVersions.allItems(service)
            .filter { $0.itemKind == .presentation && !$0.refId.isEmpty }
            .map(\.refId)
            .filter { seen.insert($0).inserted }
    }

    /// What each plan item uses, given the media ids in each presentation
    /// (MediaReferences) and the playlists.
    public static func uses(
        of service: Service,
        presentationMedia: (String) -> Set<String>?,
        playlist: (String) -> Playlist?
    ) -> [ItemUse] {
        var seenItems = Set<String>()
        var out: [ItemUse] = []
        for item in ServiceVersions.allItems(service) where seenItems.insert(item.id).inserted {
            guard !item.refId.isEmpty else { continue }
            switch item.itemKind {
            case .media:
                out.append(ItemUse(itemName: item.name, mediaIDs: [item.refId]))
            case .audio:
                out.append(ItemUse(itemName: item.name, mediaIDs: [], audioIDs: [item.refId]))
            case .presentation:
                guard let ids = presentationMedia(item.refId), !ids.isEmpty else { continue }
                out.append(ItemUse(itemName: item.name, mediaIDs: ids.sorted()))
            case .playlist:
                guard let list = playlist(item.refId) else { continue }
                out.append(ItemUse(
                    itemName: item.name,
                    mediaIDs: list.entries.filter { $0.refKind == .media }.map(\.refId),
                    audioIDs: list.entries.filter { $0.refKind == .audio }.map(\.refId)))
            case .header, .info:
                continue
            }
        }
        return out
    }

    /// The findings, in the order the plan first uses each. `media` and
    /// `audio` give an item's name and file hash; `fileExists` says whether a
    /// file is in the media folder; `deletedName` gives a deleted item's old
    /// name when it's remembered.
    public static func findings(
        uses: [ItemUse],
        media: (String) -> MediaItem?,
        audio: (String) -> AudioItem?,
        fileExists: (String) -> Bool,
        deletedName: (String) -> String?
    ) -> [Finding] {
        var order: [String] = []
        var byID: [String: Finding] = [:]

        func note(_ id: String, name: String, problem: Problem, item: String, isAudio: Bool = false) {
            if var found = byID[id] {
                if !found.usedIn.contains(item) { found.usedIn.append(item) }
                byID[id] = found
            } else {
                order.append(id)
                byID[id] = Finding(mediaID: id, name: name, problem: problem, usedIn: [item], isAudio: isAudio)
            }
        }

        for use in uses {
            for id in use.mediaIDs where !id.isEmpty && !id.contains("::") {
                if let item = media(id) {
                    if item.fileHash.isEmpty || !fileExists(item.fileHash) {
                        note(id, name: item.name, problem: .fileMissing, item: use.itemName)
                    }
                } else if let sound = audio(id) {
                    // A slide action can play audio by the same kind of id.
                    if sound.fileHash.isEmpty || !fileExists(sound.fileHash) {
                        note(id, name: sound.name, problem: .fileMissing, item: use.itemName, isAudio: true)
                    }
                } else {
                    note(id, name: deletedName(id) ?? "Deleted media", problem: .deleted, item: use.itemName)
                }
            }
            for id in use.audioIDs where !id.isEmpty {
                if let sound = audio(id) {
                    if sound.fileHash.isEmpty || !fileExists(sound.fileHash) {
                        note(id, name: sound.name, problem: .fileMissing, item: use.itemName, isAudio: true)
                    }
                } else {
                    note(id, name: deletedName(id) ?? "Deleted audio", problem: .deleted, item: use.itemName, isAudio: true)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// A stamp for one set of findings, so the popup shows once per plan
    /// until something else goes missing.
    public static func stamp(_ findings: [Finding]) -> String {
        findings.map { "\($0.mediaID):\($0.problem == .deleted ? "d" : "f")" }.sorted().joined(separator: ",")
    }
}
