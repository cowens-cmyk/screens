import AppKit
import Foundation
import PresenterCore

/// Slides for a plan song that has none. Shepherd first (the church's own
/// song list, by CCLI number, then title); failing that, SongSelect in the
/// browser, with the lyrics file picked up from Downloads as it arrives.
/// SongSelect has no API open to us, so the person downloads; Screens does
/// the rest.
@MainActor
@Observable
final class LyricsFetcher {
    static let shared = LyricsFetcher()

    /// The plan item waiting on a SongSelect download, and what to show.
    private(set) var waitingItemID: String?
    private(set) var status: String?

    private var watch: Task<Void, Never>?

    /// File types SongSelect and chord-chart tools download.
    nonisolated static let lyricExtensions: Set<String> = ["txt", "chordpro", "cho", "chopro", "crd", "pro6"]

    private init() {}

    func getLyrics(for item: ServiceItem, planID: String, model: AppModel) async {
        let title = item.mxuSongTitle ?? item.name
        status = "Looking in Shepherd…"
        waitingItemID = item.id
        switch await Self.importFromShepherd(item: item, title: title, planID: planID, model: model) {
        case .imported:
            finish("Imported “\(title)” from Shepherd")
            return
        case .alreadyLinked:
            finish("“\(title)” already has slides")
            return
        default:
            break
        }
        openSongSelect(ccli: item.mxuCcliNumber, title: title)
        status = "Download the lyrics in SongSelect; Screens picks them up from Downloads."
        watchDownloads(for: item.id, planID: planID, title: title, model: model)
    }

    func cancel() {
        watch?.cancel()
        watch = nil
        finish(nil)
    }

    // MARK: Shepherd

    /// What a Shepherd lookup for a planned song came to.
    enum ShepherdOutcome: Equatable {
        /// A new presentation from Shepherd's lyrics, with its id.
        case imported(String)
        /// The plan item got slides while Shepherd was asked; nothing was
        /// made. The presentation it has now.
        case alreadyLinked(String)
        case notConfigured
        case notFound
        /// Shepherd has the song but no lyrics or chord chart for it.
        case noWords
        case failed(String)
    }

    /// The Shepherd half of Get Lyrics on its own: finds the song (CCLI
    /// number, then title), builds a presentation from its lyrics in the
    /// plan's arrangement and key, adds it to the library and links it to
    /// the plan item. The Assistant uses this too, and never the SongSelect
    /// half. Shepherd takes a moment to answer, so the item is looked at
    /// again after: one that got slides meanwhile is left as it is, and no
    /// presentation is made for it.
    static func importFromShepherd(
        item: ServiceItem, title: String, planID: String, model: AppModel
    ) async -> ShepherdOutcome {
        let sync = ShepherdSync.shared
        guard sync.isConfigured else { return .notConfigured }
        let client = sync.client
        do {
            guard let match = try await ShepherdSongMatch.find(
                ccli: item.mxuCcliNumber.map(String.init), title: title, search: { try await client.searchSongs($0) })
            else { return .notFound }
            let detail = try await client.song(id: match.id)
            let arrangement = detail.arrangements.first { $0.name == item.mxuArrangementName }
                ?? detail.arrangements.first
            guard SongImport.hasText(song: detail, arrangement: arrangement),
                  var presentation = SongImport.presentation(
                      song: detail, arrangement: arrangement, playingKey: item.mxuSongKey,
                      themeId: model.slideBuilding.lyricsImportThemeId ?? "")
            else { return .noWords }
            if let now = linkedPresentation(item.id, planID: planID, model: model) { return .alreadyLinked(now) }
            presentation.folder = model.newPlacement.folder(for: .presentation)
            model.createInDrive(presentation)
            shared.link(item.id, planID: planID, to: presentation.id, model: model)
            return .imported(presentation.id)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: SongSelect

    private func openSongSelect(ccli: Int?, title: String) {
        var components = URLComponents(string: "https://songselect.ccli.com")!
        if let ccli {
            components.path = "/songs/\(ccli)"
        } else {
            components.path = "/search/results"
            components.queryItems = [URLQueryItem(name: "search", value: title)]
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Checks Downloads every two seconds for ten minutes for a lyrics file
    /// that arrived after the browser opened.
    private func watchDownloads(for itemID: String, planID: String, title: String, model: AppModel) {
        watch?.cancel()
        let started = Date()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        watch = Task { [weak self] in
            while !Task.isCancelled, Date().timeIntervalSince(started) < 600 {
                try? await Task.sleep(for: .seconds(2))
                guard let file = Self.newestLyricsFile(in: downloads, since: started),
                      let text = Self.read(file)
                else { continue }
                guard let self else { return }
                if Self.linkedPresentation(itemID, planID: planID, model: model) != nil {
                    self.finish("“\(title)” already has slides")
                    return
                }
                let presentation = self.importText(text, title: title, model: model)
                self.link(itemID, planID: planID, to: presentation.id, model: model)
                self.finish("Imported “\(title)” from \(file.lastPathComponent)")
                return
            }
            if !Task.isCancelled { self?.finish("No lyrics file arrived in Downloads.") }
        }
    }

    nonisolated static func newestLyricsFile(in folder: URL, since: Date) -> URL? {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { lyricExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (URL, Date)? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = max(values?.creationDate ?? .distantPast, values?.contentModificationDate ?? .distantPast)
                return date > since ? (url, date) : nil
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: Files dropped on the plan

    /// A lyrics file dropped on a plan: fills in a flagged song with the same
    /// CCLI number or title, else is added where it was dropped.
    func importDropped(_ url: URL, planID: String, beforeItemID: String?, model: AppModel) {
        guard let text = Self.read(url) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let presentation = importText(text, title: title, model: model)
        let id = presentation.id
        let flagged = model.resident.services.value(planID)?.items.first { item in
            guard item.itemKind == .info, item.refId.isEmpty, item.mxuSongTitle != nil else { return false }
            if let ccli = item.mxuCcliNumber, ccli == presentation.ccli?.songNumber { return true }
            return (item.mxuSongTitle ?? item.name).caseInsensitiveCompare(presentation.name) == .orderedSame
        }
        if let flagged {
            link(flagged.id, planID: planID, to: id, model: model)
        } else {
            model.updateService(planID) { plan in
                let index = beforeItemID.flatMap { before in plan.items.firstIndex { $0.id == before } } ?? plan.items.count
                plan.items.insert(
                    ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: presentation.name, refId: id),
                    at: min(index, plan.items.count))
            }
        }
    }

    // MARK: Helpers

    /// SongSelect and ChordPro text, read as a song (sections, CCLI number).
    private func importText(_ text: String, title: String, model: AppModel) -> Presentation {
        var presentation = LyricTextImporter.makePresentation(
            LyricCleanup.clean(text), fallbackTitle: title,
            folder: model.newPlacement.folder(for: .presentation),
            themeId: model.slideBuilding.lyricsImportThemeId ?? "")
        presentation.presentationKind = .song
        presentation.category = PresentationTypes.worship
        model.createInDrive(presentation)
        return presentation
    }

    nonisolated static func read(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    /// The presentation a plan item has now; nil when it has none (or is gone).
    static func linkedPresentation(_ itemID: String, planID: String, model: AppModel) -> String? {
        guard let item = (try? model.service(planID))?.items.first(where: { $0.id == itemID }),
              !item.refId.isEmpty else { return nil }
        return item.refId
    }

    /// Gives a plan song its slides. Only an item that still has none is
    /// changed: one that got slides some other way keeps them. True when
    /// the item now shows `presentationID`.
    @discardableResult
    func link(_ itemID: String, planID: String, to presentationID: String, model: AppModel) -> Bool {
        if let now = Self.linkedPresentation(itemID, planID: planID, model: model) { return now == presentationID }
        guard (try? model.service(planID))?.items.contains(where: { $0.id == itemID }) == true else { return false }
        model.updateService(planID) { plan in
            guard let index = plan.items.firstIndex(where: { $0.id == itemID }), plan.items[index].refId.isEmpty else { return }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = presentationID
        }
        return true
    }

    private func finish(_ message: String?) {
        waitingItemID = nil
        status = message
    }
}
