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
        if let id = await fromShepherd(item: item, title: title, model: model) {
            link(item.id, planID: planID, to: id, model: model)
            finish("Imported “\(title)” from Shepherd")
            return
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

    private func fromShepherd(item: ServiceItem, title: String, model: AppModel) async -> String? {
        let sync = ShepherdSync.shared
        guard sync.isConfigured else { return nil }
        let client = sync.client
        let ccli = item.mxuCcliNumber.map(String.init)
        do {
            var found: [ShepherdClient.SongSummary] = []
            if let ccli { found = try await client.searchSongs(ccli).filter { $0.archived != true } }
            var match = found.first { ccli != nil && $0.ccliNumber == ccli }
            if match == nil {
                let byTitle = try await client.searchSongs(title).filter { $0.archived != true }
                match = byTitle.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
            }
            guard let match else { return nil }
            let detail = try await client.song(id: match.id)
            let arrangement = detail.arrangements.first { $0.name == item.mxuArrangementName }
                ?? detail.arrangements.first
            guard SongImport.hasText(song: detail, arrangement: arrangement),
                  var presentation = SongImport.presentation(
                      song: detail, arrangement: arrangement, playingKey: item.mxuSongKey,
                      themeId: model.slideBuilding.lyricsImportThemeId ?? "")
            else { return nil }
            presentation.folder = model.newPlacement.folder(for: .presentation)
            model.createInDrive(presentation)
            return presentation.id
        } catch {
            return nil
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

    private func link(_ itemID: String, planID: String, to presentationID: String, model: AppModel) {
        model.updateService(planID) { plan in
            guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
            plan.items[index].itemKind = .presentation
            plan.items[index].refId = presentationID
        }
    }

    private func finish(_ message: String?) {
        waitingItemID = nil
        status = message
    }
}
