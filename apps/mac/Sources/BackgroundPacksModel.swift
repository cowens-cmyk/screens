import Foundation
import PresenterCore

/// Packs in the media bin's Worship Backgrounds (see BackgroundPacks): what
/// the bin asks of the library to show, fill, rename and empty them. A pack
/// is a folder inside Worship Backgrounds, so each change here is a refile of
/// the backgrounds in it and syncs like any other move between folders.
extension AppModel {
    /// The worship backgrounds, split into packs and the ones in no pack,
    /// each pack's by name so its tile shows the same four every time.
    func backgroundPacks(_ entries: [LibraryIndex.Entry]) -> BackgroundPacks.Grouped {
        BackgroundPacks.group(
            entries
                .filter { MediaLibraryCategory.containing(folder: $0.subkind) == .worshipBackgrounds }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            id: \.id, folder: \.subkind)
    }

    /// Puts backgrounds in a pack, or at the top of Worship Backgrounds when
    /// `pack` is nil. Media from other categories comes along and becomes a
    /// worship background, as a drop on the category would make it.
    func moveToPack(_ entries: [LibraryIndex.Entry], pack: String?) {
        let folder = BackgroundPacks.folder(forPack: pack)
        file(entries.filter { $0.kind == .media && $0.subkind != folder }.compactMap {
            refile($0, folder: folder, area: area($0.kind, $0.id))
        })
    }

    /// Renames a pack by refiling each background in it. Given the name of
    /// another pack, the two become one.
    func renamePack(_ pack: BackgroundPacks.Pack, to name: String) {
        guard let clean = BackgroundPacks.cleanName(name), clean != pack.name else { return }
        file(pack.memberIDs.compactMap(indexEntry).compactMap {
            refile($0, folder: BackgroundPacks.renamed(folder: $0.subkind, to: clean), area: area($0.kind, $0.id))
        })
    }

    /// Ends a pack. Its backgrounds go back to the top of Worship
    /// Backgrounds, or, with `deletingBackgrounds`, are deleted.
    func deletePack(_ pack: BackgroundPacks.Pack, deletingBackgrounds: Bool) {
        let entries = pack.memberIDs.compactMap(indexEntry)
        if deletingBackgrounds {
            delete(entries)
        } else {
            moveToPack(entries, pack: nil)
        }
    }

    /// Each Finder folder dropped on Worship Backgrounds becomes a pack named
    /// after it, holding every picture and video in it and the folders inside
    /// it. Dropped again, the folder fills the pack it made, adding only the
    /// files the pack doesn't have yet.
    func importBackgroundPacks(_ folders: [URL]) async {
        var notes: [String] = []
        for folder in folders {
            let existing = backgroundPacks(entries(in: .media)).packs.map(\.name)
            guard let name = BackgroundPacks.packName(forFolderNamed: folder.lastPathComponent, existing: existing)
            else { continue }
            notes.append(await fill(pack: name, from: [folder]))
        }
        if !notes.isEmpty { noteImportSummary(notes.joined(separator: " \u{00B7} ")) }
    }

    /// Files or folders dropped on a pack, or on the grid while a pack is
    /// open: their pictures and videos go into that pack.
    func importIntoPack(_ urls: [URL], pack name: String) async {
        noteImportSummary(await fill(pack: name, from: urls))
    }

    private func fill(pack name: String, from urls: [URL]) async -> String {
        let files = await Task.detached(priority: .userInitiated) {
            BackgroundPackImport.files(in: urls)
        }.value
        guard !files.isEmpty else {
            return "No pictures or videos in \(urls.map { "\u{201C}\($0.lastPathComponent)\u{201D}" }.joined(separator: ", "))"
        }
        // The hashes come from the media documents, which may still be
        // loading just after launch.
        await resident.ready([.media])
        let had = backgroundPacks(entries(in: .media)).pack(named: name)?.memberIDs ?? []
        let hashes = Set(had.compactMap { media($0)?.fileHash }.filter { !$0.isEmpty })
        let placement = LibraryHome.Placement.drive(
            viewing: LibraryHome.Viewed(kind: .media, area: .team, path: BackgroundPacks.folder(forPack: name)))
        await importFiles(files, placement: placement, skippingHashes: hashes)
        return "\u{201C}\(name)\u{201D}: \(lastImportSummary ?? "")"
    }
}
