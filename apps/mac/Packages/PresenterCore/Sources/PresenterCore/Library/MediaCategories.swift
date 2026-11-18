import Foundation

/// The Media Library's own categories, made by the church beside the
/// built-in ones (MediaLibraryCategory). Like those, a category is a folder
/// at the top of Media of the same name; what's added here is its name and
/// the icon beside it, kept in the church-wide settings
/// (`SlideBuildingSettings.mediaCategories`) so every Mac shows the same
/// list.
///
/// Until the list has been changed once, it is Hope Students alone, with the
/// Students logo. Deleting Hope Students saves an empty list, so it stays
/// gone.
public enum MediaCategories {
    public static let hopeStudents = MediaCategoryDefinition(name: "Hope Students", icon: MediaCategoryIcon.studentsLogo)

    public static let defaults = [hopeStudents]

    /// What the Media Library lists after the built-in categories.
    public static func effective(_ saved: [MediaCategoryDefinition]?) -> [MediaCategoryDefinition] {
        saved ?? defaults
    }

    /// A name a category can have: it is a folder name, so a slash (or
    /// Finder's colon) would make a folder inside it.
    public static func cleanName(_ raw: String) -> String {
        String(raw.map { "/:".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum NameProblem: Equatable, Sendable {
        case empty
        /// A built-in category already has it (or All Media).
        case builtIn
        /// Another of the church's categories has it.
        case taken

        public var message: String {
            switch self {
            case .empty: "Give the category a name."
            case .builtIn: "That's one of the standard categories already."
            case .taken: "There's already a category with that name."
            }
        }
    }

    /// Why a name can't be used, if it can't. Names match without regard to
    /// case, as Finder's folders do. `renaming` is the category being
    /// renamed, which may keep its own name.
    public static func problem(
        with raw: String, in list: [MediaCategoryDefinition], renaming: String? = nil
    ) -> NameProblem? {
        let name = cleanName(raw)
        guard !name.isEmpty else { return .empty }
        if name.caseInsensitiveCompare("All Media") == .orderedSame
            || MediaLibraryCategory.allCases.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame })
            || MediaLibraryCategory.containing(folder: name) != nil {
            return .builtIn
        }
        let taken = list.contains { other in
            other.name.caseInsensitiveCompare(name) == .orderedSame
                && renaming.map { other.name.caseInsensitiveCompare($0) != .orderedSame } ?? true
        }
        return taken ? .taken : nil
    }

    /// The list with a new category at the end.
    public static func adding(name raw: String, icon: String, to list: [MediaCategoryDefinition]) -> [MediaCategoryDefinition] {
        guard problem(with: raw, in: list) == nil else { return list }
        return list + [MediaCategoryDefinition(name: cleanName(raw), icon: icon)]
    }

    /// The list with one category renamed and given an icon, in its place.
    public static func editing(
        _ old: String, name raw: String, icon: String, in list: [MediaCategoryDefinition]
    ) -> [MediaCategoryDefinition] {
        guard problem(with: raw, in: list, renaming: old) == nil else { return list }
        return list.map {
            $0.name.caseInsensitiveCompare(old) == .orderedSame
                ? MediaCategoryDefinition(name: cleanName(raw), icon: icon) : $0
        }
    }

    public static func removing(_ name: String, from list: [MediaCategoryDefinition]) -> [MediaCategoryDefinition] {
        list.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
    }

    /// The church category whose folder holds this path: the folder itself
    /// or one inside it. A built-in category's folder is never one, even if
    /// an old list carries its name.
    public static func containing(folder path: String?, in list: [MediaCategoryDefinition]) -> MediaCategoryDefinition? {
        guard let path, !path.isEmpty, MediaLibraryCategory.containing(folder: path) == nil else { return nil }
        let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        return list.first { $0.name.caseInsensitiveCompare(top) == .orderedSame }
    }

    /// Where something filed at `path` goes when its category is renamed:
    /// the top folder takes the new name and folders inside it are kept.
    public static func renamedFolder(_ path: String, to new: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 1)
        return parts.count > 1 ? new + "/" + parts[1] : new
    }
}

/// The icon beside one of the church's categories: the Hope Students or
/// Hope logo, or one of a set of symbols.
public enum MediaCategoryIcon {
    public static let studentsLogo = "logo:students"
    public static let hopeLogo = "logo:hope"

    /// The image asset a logo icon is, nil for a symbol.
    public static func logoAsset(_ icon: String) -> String? {
        switch icon {
        case studentsLogo: "StudentsLogo"
        case hopeLogo: "HopeLogo"
        default: nil
        }
    }

    /// What's offered when making or editing a category: the two logos, then
    /// symbols for the kinds of media a church keeps.
    public static let choices: [String] = [
        studentsLogo, hopeLogo,
        "folder", "star", "heart", "cross", "book", "music.mic", "person.3", "figure.and.child.holdinghands",
        "graduationcap", "sun.max", "moon.stars", "leaf", "gift", "snowflake",
        "calendar", "megaphone", "camera", "film", "photo", "sparkles",
        "hands.sparkles", "flame", "drop", "globe.americas", "house", "cup.and.saucer",
        "gamecontroller", "tent", "bus", "party.popper",
    ]

    public static let defaultChoice = "folder"
}
