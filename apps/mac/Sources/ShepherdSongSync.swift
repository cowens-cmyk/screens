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
    /// song per pass. With `importing`, planned songs with no slides get
    /// one from Shepherd and Shepherd's songs follow chart changes; either
    /// way, every linked song plays the arrangement the plan chose in
    /// Shepherd (ShepherdArrangementSync). Returns how many songs were
    /// imported and updated, and how many got a Shepherd arrangement made
    /// or changed.
    func refreshSongs(
        inServices serviceIDs: [String], importing: Bool, model: AppModel
    ) async -> (imported: Int, updated: Int, arranged: Int) {
        var details: [String: ShepherdClient.SongDetail] = [:]
        var missing = Set<String>()
        var presentations: [String: Presentation] = [:]
        var refreshed = Set<String>()
        var imported = 0, updated = 0, arranged = 0
        let client = client

        func detail(_ songID: String) async -> ShepherdClient.SongDetail? {
            if let cached = details[songID] { return cached }
            guard !missing.contains(songID), let fetched = try? await client.song(id: songID) else {
                missing.insert(songID)
                return nil
            }
            details[songID] = fetched
            return fetched
        }

        for serviceID in serviceIDs {
            guard let service = try? model.service(serviceID), service.mxuSyncPaused != true else { continue }
            var picks: [ArrangementPick] = []
            for item in service.items where item.mxuSongTitle != nil {
                guard let songID = item.mxuSourceSongId, !songID.isEmpty else { continue }
                if item.refId.isEmpty {
                    guard importing, item.itemKind == .info, let detail = await detail(songID) else { continue }
                    let planned = ShepherdSongMatch.arrangement(
                        in: detail, id: item.mxuSourceArrangementId, name: item.mxuArrangementName)
                    if importSong(detail, arrangement: planned, for: item, serviceID: serviceID, model: model) {
                        imported += 1
                    }
                    continue
                }
                guard item.itemKind == .presentation else { continue }
                var presentation: Presentation
                if let cached = presentations[item.refId] {
                    presentation = cached
                } else {
                    guard let loaded = try? await model.client.loadValue(Presentation.self, id: item.refId) else { continue }
                    presentation = loaded
                }
                guard let detail = await detail(songID) else { continue }
                let planned = ShepherdSongMatch.arrangement(
                    in: detail, id: item.mxuSourceArrangementId, name: item.mxuArrangementName)

                // Only presentations made from Shepherd follow its chart; a
                // song linked from elsewhere in the library keeps its words.
                if importing, presentation.shepherdSongId == songID, refreshed.insert(presentation.id).inserted,
                   refresh(presentation, from: detail, model: model) {
                    updated += 1
                }

                let outcome = ShepherdArrangementSync.reconcile(presentation, song: detail, arrangement: planned)
                if let arrangements = outcome.arrangements {
                    // Worked out again as the write lands, on the song as it
                    // is then: an edit or a refresh made meanwhile counts.
                    model.updatePresentation(presentation.id) { current in
                        if let again = ShepherdArrangementSync.reconcile(current, song: detail, arrangement: planned)
                            .arrangements {
                            current.arrangements = again
                        }
                    }
                    presentation.arrangements = arrangements
                    arranged += 1
                }
                presentations[presentation.id] = presentation

                let pick = ShepherdArrangementSync.pick(
                    current: item.arrangementId, lastSynced: item.mxuSyncedArrangementId,
                    target: outcome.arrangementId, defaultId: presentation.defaultArrangementId,
                    available: Set((presentation.arrangements ?? []).map(\.id)),
                    anthemLeads: Self.anthemLeads(serviceID: serviceID, itemID: item.id, model: model))
                let warnings = outcome.warnings.isEmpty ? nil : outcome.warnings
                if pick != nil || warnings != item.mxuArrangementWarnings {
                    picks.append(ArrangementPick(
                        itemID: item.id, refID: item.refId, was: item.arrangementId, pick: pick, warnings: warnings))
                }
            }
            guard !picks.isEmpty else { continue }
            let changes = picks
            model.updateService(serviceID) { service in
                for change in changes {
                    guard let index = service.items.firstIndex(where: { $0.id == change.itemID }),
                          service.items[index].refId == change.refID else { continue }
                    service.items[index].mxuArrangementWarnings = change.warnings
                    // Someone picked another while Shepherd answered: theirs stays.
                    guard let pick = change.pick, service.items[index].arrangementId == change.was else { continue }
                    service.items[index].arrangementId = pick.arrangementId
                    service.items[index].mxuSyncedArrangementId = pick.syncedArrangementId
                }
            }
        }
        return (imported, updated, arranged)
    }

    private struct ArrangementPick: Sendable {
        var itemID: String
        var refID: String
        var was: String?
        var pick: ShepherdArrangementSync.Pick?
        var warnings: [String]?
    }

    /// Anthem decides this plan item's order: its setlist is this plan's,
    /// the song is in it, and Match Anthem runs automatically. Shepherd's
    /// arrangement is still made, but Anthem's rule picks (AnthemFeed).
    /// With automatic matching off, Shepherd's pick stands and Anthem only
    /// marks a song the band plays differently.
    static func anthemLeads(serviceID: String, itemID: String, model: AppModel) -> Bool {
        let feed = AnthemFeed.shared
        guard feed.autoMatch, let result = feed.report(for: serviceID, model: model)?.result(forItem: itemID)
        else { return false }
        return result.entryID != nil && (result.status == .match || result.status == .mismatch)
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
