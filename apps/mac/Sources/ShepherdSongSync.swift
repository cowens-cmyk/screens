import Foundation
import PresenterCore
import SwiftUI

/// How lyrics come in, on this Mac: every import (Shepherd, SongSelect,
/// pasted lyrics, chord charts) reads it. Songs already in the library
/// aren't changed when it's switched.
enum LyricImportSettings {
    static let removePunctuationKey = "lyrics.removePunctuation"

    static var removePunctuation: Bool {
        UserDefaults.standard.object(forKey: removePunctuationKey) as? Bool ?? true
    }
}

/// A linked song whose Shepherd chart changed after it was edited in
/// Screens. Sync leaves it as it is and says so; Update brings Shepherd's in.
struct ShepherdNewerChart: Equatable, Sendable {
    var songID: String
    var arrangementID: String?
    /// "Chorus 1 changed, Tag added", when it can be told.
    var summary: String?
}

/// Lyrics and chords from Shepherd for planned songs. After plans load:
/// a planned song with no slides gets a song built from its Shepherd chart,
/// and a song imported from Shepherd is refreshed when its chart changed,
/// unless it was edited here. Shepherd is only read, never written.
extension ShepherdSync {

    static let importSongsKey = "shepherd.importSongs"

    func importOptions(playingKey: String?, model: AppModel) -> ShepherdSongImport.Options {
        ShepherdSongImport.Options(
            themeId: model.slideBuilding.lyricsImportThemeId ?? "",
            removePunctuation: LyricImportSettings.removePunctuation, playingKey: playingKey)
    }

    /// The song pass over these plans. Song details are fetched once per
    /// song per pass. Returns how many songs were imported and updated.
    func refreshSongs(inServices serviceIDs: [String], model: AppModel) async -> (imported: Int, updated: Int) {
        var details: [String: ShepherdClient.SongDetail] = [:]
        var checked = Set<String>()
        var imported = 0, updated = 0
        let client = client
        for serviceID in serviceIDs {
            guard let service = try? model.service(serviceID), service.mxuSyncPaused != true else { continue }
            for item in service.items where item.mxuSongTitle != nil {
                guard let songID = item.mxuSourceSongId, !songID.isEmpty else { continue }
                // Only presentations made from Shepherd are refreshed; a
                // song linked from elsewhere in the library is left alone.
                var linked: Presentation?
                if !item.refId.isEmpty {
                    guard item.itemKind == .presentation, !checked.contains(item.refId),
                          let presentation = try? await model.client.loadValue(Presentation.self, id: item.refId),
                          presentation.shepherdSongId == songID else { continue }
                    checked.insert(item.refId)
                    linked = presentation
                } else if item.itemKind != .info {
                    continue
                }
                let detail: ShepherdClient.SongDetail
                if let cached = details[songID] {
                    detail = cached
                } else {
                    guard let fetched = try? await client.song(id: songID) else { continue }
                    details[songID] = fetched
                    detail = fetched
                }
                let planned = ShepherdSongMatch.arrangement(
                    in: detail, id: item.mxuSourceArrangementId, name: item.mxuArrangementName)

                guard let linked else {
                    if importSong(detail, arrangement: planned, for: item, serviceID: serviceID, model: model) {
                        imported += 1
                    }
                    continue
                }
                if refresh(linked, from: detail, model: model) { updated += 1 }
                addPlanArrangement(planned, of: detail, to: linked, item: item, serviceID: serviceID, model: model)
            }
        }
        return (imported, updated)
    }

    /// A new library song for a planned song with no slides, linked to it.
    private func importSong(
        _ detail: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?,
        for item: ServiceItem, serviceID: String, model: AppModel
    ) -> Bool {
        guard var presentation = ShepherdSongImport.presentation(
            song: detail, arrangement: arrangement, options: importOptions(playingKey: item.mxuSongKey, model: model))
        else { return false }
        // Another Mac (or a person) may have linked it while Shepherd answered.
        guard let current = (try? model.service(serviceID))?.items.first(where: { $0.id == item.id }),
              current.refId.isEmpty else { return false }
        presentation.folder = model.newPlacement.folder(for: .presentation)
        model.createInDrive(presentation)
        return LyricsFetcher.shared.link(item.id, planID: serviceID, to: presentation.id, model: model)
    }

    /// Brings a linked song up to Shepherd's chart when it changed and the
    /// song is as it was imported; marks it when it was edited here.
    private func refresh(_ presentation: Presentation, from detail: ShepherdClient.SongDetail, model: AppModel) -> Bool {
        let arrangement = ShepherdSongImport.trackedArrangement(of: detail, id: presentation.shepherdArrangementId)
        let hash = ShepherdSongImport.chartHash(song: detail, arrangement: arrangement)
        switch ShepherdSongImport.decision(for: presentation, chartHash: hash) {
        case .upToDate:
            newerCharts[presentation.id] = nil
            return false
        case .update:
            guard let fresh = ShepherdSongImport.presentation(
                song: detail, arrangement: arrangement, options: importOptions(playingKey: nil, model: model))
            else { return false }
            newerCharts[presentation.id] = nil
            model.updatePresentation(presentation.id) { current in
                // Checked again as the write lands: an edit made meanwhile wins.
                guard ShepherdSongImport.decision(for: current, chartHash: hash) == .update else { return }
                current = ShepherdSongImport.replacing(current, with: fresh)
            }
            return true
        case .edited:
            let fresh = ShepherdSongImport.presentation(
                song: detail, arrangement: arrangement, options: importOptions(playingKey: nil, model: model))
            newerCharts[presentation.id] = ShepherdNewerChart(
                songID: detail.id, arrangementID: arrangement?.id,
                summary: fresh.flatMap { ShepherdSongImport.changeSummary(from: presentation, to: $0) })
            return false
        }
    }

    /// A plan that plays the song in another Shepherd arrangement gets that
    /// order as its own arrangement, picked for its item when nothing is.
    private func addPlanArrangement(
        _ planned: ShepherdClient.SongArrangement?, of detail: ShepherdClient.SongDetail,
        to presentation: Presentation, item: ServiceItem, serviceID: String, model: AppModel
    ) {
        guard let planned, planned.id != presentation.shepherdArrangementId,
              let extra = ShepherdSongImport.extraArrangement(planned, of: detail, for: presentation)
        else { return }
        if presentation.arrangements?.contains(where: { $0.id == extra.id }) != true {
            model.updatePresentation(presentation.id) { current in
                guard current.arrangements?.contains(where: { $0.id == extra.id }) != true else { return }
                current.arrangements = (current.arrangements ?? []) + [extra]
            }
        }
        if item.arrangementId == nil {
            let itemID = item.id, arrangementID = extra.id
            model.updateService(serviceID) { service in
                guard let index = service.items.firstIndex(where: { $0.id == itemID }),
                      service.items[index].arrangementId == nil else { return }
                service.items[index].arrangementId = arrangementID
            }
        }
    }

    /// Update (a newer chart) and Update from Shepherd: the song's Shepherd
    /// chart replaces its slides, edits or not. Nil when done, else why not.
    func updateFromShepherd(_ presentationID: String, model: AppModel) async -> String? {
        guard isConfigured else { return ShepherdError.notConfigured.errorDescription }
        guard let presentation = try? await model.client.loadValue(Presentation.self, id: presentationID),
              let songID = presentation.shepherdSongId else { return "This song isn't linked to Shepherd." }
        do {
            let detail = try await client.song(id: songID)
            let arrangement = ShepherdSongImport.trackedArrangement(of: detail, id: presentation.shepherdArrangementId)
            guard let fresh = ShepherdSongImport.presentation(
                song: detail, arrangement: arrangement, options: importOptions(playingKey: nil, model: model))
            else { return "Shepherd has no lyrics or chord chart for this song." }
            let task = model.updatePresentation(presentationID) { current in
                current = ShepherdSongImport.replacing(current, with: fresh)
            }
            _ = try? await task.value
            newerCharts[presentationID] = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Import from Shepherd… in the song editor: this song becomes the
    /// Shepherd song's, and stays linked to it.
    func importInto(
        _ presentationID: String, song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?,
        playingKey: String?, model: AppModel
    ) async {
        guard let fresh = ShepherdSongImport.presentation(
            song: song, arrangement: arrangement, options: importOptions(playingKey: playingKey, model: model))
        else { return }
        let task = model.updatePresentation(presentationID) { current in
            var updated = ShepherdSongImport.replacing(current, with: fresh)
            // A song taken over from elsewhere follows Shepherd's order.
            updated.defaultArrangementId = fresh.defaultArrangementId
            // A key picked for the import wins over the song's own.
            if playingKey != nil { updated.displayKey = fresh.displayKey }
            current = updated
        }
        _ = try? await task.value
        newerCharts[presentationID] = nil
    }
}

// MARK: Views

/// "Newer chart in Shepherd" on a song edited in Screens after Shepherd's
/// chart changed. Click to see what changed and update.
struct ShepherdNewerChartBadge: View {
    let model: AppModel
    let presentationID: String

    @State private var showing = false

    var body: some View {
        if let newer = ShepherdSync.shared.newerCharts[presentationID] {
            Button { showing.toggle() } label: {
                Label("Newer chart", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)
            .help("Shepherd has a newer chart" + (newer.summary.map { ": \($0)" } ?? ""))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ShepherdNewerChartPanel(model: model, presentationID: presentationID, newer: newer) { showing = false }
                    .padding(12)
                    .frame(width: 300)
            }
        }
    }
}

/// The song editor's Shepherd row: where the song came from, a newer chart
/// when there is one, Update from Shepherd, and Import from Shepherd….
struct ShepherdSongRow: View {
    let model: AppModel
    let presentationID: String
    /// Re-reads the editor's lyrics after an update.
    var reload: () -> Void

    @State private var searching = false
    @State private var updating = false
    @State private var error: String?
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let sync = ShepherdSync.shared
        let linked = model.presentation(presentationID)?.shepherdSongId != nil
        let newer = sync.newerCharts[presentationID]
        if sync.isConfigured || linked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if newer != nil {
                        Label("Shepherd has a newer chart", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    } else if linked {
                        Label("From Shepherd", systemImage: "link").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if linked {
                        Button(updating ? "Updating…" : newer == nil ? "Update from Shepherd" : "Update") { update() }
                            .disabled(updating || runOnly || !sync.isConfigured)
                            .help("Replaces this song's words, chords and order with Shepherd's chart")
                    }
                    Button("Import from Shepherd…") { searching = true }
                        .disabled(runOnly || !sync.isConfigured)
                        .help("Pick a Shepherd song for this one; it stays linked to it")
                }
                .font(.callout)
                if let summary = newer?.summary {
                    Text(summary + ". This song was edited here, so it wasn't updated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .sheet(isPresented: $searching) {
                SongSearchSheet(model: model, render: nil, replacing: presentationID) { _ in reload() }
            }
        }
    }

    private func update() {
        updating = true
        Task {
            error = await ShepherdSync.shared.updateFromShepherd(presentationID, model: model)
            updating = false
            if error == nil { reload() }
        }
    }
}

/// What changed and the Update button; the badge's popover and the song
/// editor's header.
struct ShepherdNewerChartPanel: View {
    let model: AppModel
    let presentationID: String
    let newer: ShepherdNewerChart
    var done: () -> Void = {}

    @State private var updating = false
    @State private var error: String?
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shepherd has a newer chart").font(.headline)
            if let summary = newer.summary { Text(summary).font(.callout) }
            Text("This song was edited in Screens, so it wasn't updated. Update replaces its words and chords with Shepherd's.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(updating ? "Updating…" : "Update") {
                    updating = true
                    Task {
                        error = await ShepherdSync.shared.updateFromShepherd(presentationID, model: model)
                        updating = false
                        if error == nil { done() }
                    }
                }
                .disabled(updating || runOnly)
            }
        }
    }
}
