import Foundation

/// The ProPresenter API shapes Screens answers with, so apps that drive
/// ProPresenter's slides over the network (Anthem) can drive Screens.
public enum ProPresenterCompat {
    /// Slides grouped by section, in the presentation's own order: trigger
    /// index N is the presentation's slide N.
    public static func describe(_ presentation: Presentation) -> [String: Any] {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        var groups: [[String: Any]] = []
        var current: (section: String?, slides: [[String: Any]])?
        for slide in presentation.slides {
            let text = slide.objects.first { $0.objectKind == .text }?.text ?? ""
            let entry: [String: Any] = ["text": text, "label": slide.name, "enabled": true]
            if let open = current, open.section == slide.sectionId {
                current?.slides.append(entry)
            } else {
                if let open = current {
                    groups.append(["name": open.section.flatMap { names[$0] } ?? "", "slides": open.slides])
                }
                current = (slide.sectionId, [entry])
            }
        }
        if let open = current {
            groups.append(["name": open.section.flatMap { names[$0] } ?? "", "slides": open.slides])
        }
        return ["id": ["uuid": presentation.id, "name": presentation.name, "index": 0], "groups": groups]
    }

    /// A presentation as the library listing knows it: id, name and its
    /// folder path ("Worship/Hymns", "" at the top).
    public struct LibraryItem: Equatable, Sendable {
        public var id: String
        public var name: String
        public var folder: String

        public init(id: String, name: String, folder: String) {
            self.id = id
            self.name = name
            self.folder = folder
        }
    }

    public static let libraryName = "Screens"

    /// The whole library first, then each top-level folder as a library of
    /// its own, so Anthem can be pointed at just the songs.
    public static func libraries(_ items: [LibraryItem]) -> [[String: Any]] {
        let folders = Set(items.compactMap { $0.folder.split(separator: "/").first.map(String.init) })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ([libraryName] + folders).enumerated().map { index, name in
            ["id": ["uuid": index == 0 ? "screens" : "folder:\(name)", "name": name, "index": index]]
        }
    }

    /// `/v1/library/{name}`: the presentations in that folder (and the
    /// folders under it) when the name is a folder, by name or by the uuid
    /// `libraries` gave it; every presentation for "Screens" or a name we
    /// don't know, so an old link in Anthem still finds its songs.
    public static func libraryItems(_ items: [LibraryItem], named name: String) -> [[String: Any]] {
        let wanted = name.hasPrefix("folder:") ? String(name.dropFirst("folder:".count)) : name
        let folders = Set(items.map(\.folder).filter { !$0.isEmpty })
        let match = folders.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? folders.compactMap { $0.split(separator: "/").first.map(String.init) }
                .first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        let chosen = match.map { path in items.filter { TeamDriveLogic.isUnder($0.folder, prefix: path) } } ?? items
        return chosen
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .enumerated().map { ["uuid": $1.id, "name": $1.name, "index": $0] }
    }

    /// A plan item as a ProPresenter playlist item. Presentations carry the
    /// arrangement the plan picked, so Anthem knows which order the slides
    /// will be in.
    public static func playlistItem(_ item: ServiceItem, index: Int, presentation: Presentation?) -> [String: Any] {
        var entry: [String: Any] = [
            "id": ["uuid": item.id, "name": item.name, "index": index],
            "type": item.itemKind == .presentation ? "presentation" : item.itemKind == .header ? "header" : "media",
            "is_hidden": item.hiddenInPresenter == true,
        ]
        if item.itemKind == .presentation {
            let arrangement = item.arrangementId.flatMap { id in presentation?.arrangements?.first { $0.id == id } }
            var info: [String: Any] = [
                "presentation_uuid": item.refId,
                "arrangement_name": arrangement?.name ?? "",
            ]
            if let arrangement { info["arrangement_uuid"] = arrangement.id }
            entry["presentation_info"] = info
            entry["arrangement_name"] = arrangement?.name ?? ""
        }
        return entry
    }
}
