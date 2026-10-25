import PresenterCore
import SwiftUI

/// Find a song in Shepherd's song library, pick the arrangement the band
/// plays, and bring it in with its sections, chords, key and song order.
struct SongSearchSheet: View {
    let model: AppModel
    let render: RenderContext?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var songs: [ShepherdClient.SongSummary] = []
    @State private var selectedSong: ShepherdClient.SongSummary?
    /// The chosen song with lyrics, charts, keys and arrangements.
    @State private var detail: ShepherdClient.SongDetail?
    @State private var arrangements: [ShepherdClient.SongArrangement] = []
    @State private var selectedArrangementID: String?
    @State private var keys: [String] = []
    @State private var playingKey = ""
    @State private var existingID: String?
    @State private var searching = false
    @State private var error: String?
    @State private var addToService = true

    private var sync: ShepherdSync { ShepherdSync.shared }
    private var client: ShepherdClient { sync.client }
    private var arrangement: ShepherdClient.SongArrangement? { arrangements.first { $0.id == selectedArrangementID } }
    private var canImport: Bool { detail != nil && SongImport.hasText(song: detail, arrangement: arrangement) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song Search").font(.headline)
            if !sync.isConfigured {
                Text("Add your Shepherd key in Settings › Integrations › Shepherd to search the song library.")
                    .foregroundStyle(.orange)
            }
            TextField("Search by title or CCLI number", text: $query)
                .textFieldStyle(.roundedBorder)
                .task(id: query) { await search() }
            HStack(alignment: .top, spacing: 12) {
                songList.frame(width: 260)
                arrangementPane.frame(maxWidth: .infinity)
            }
            .frame(height: 340)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            AddToCurrentServiceToggle(model: model, isOn: $addToService)
            HStack {
                LyricsThemeChooser(appModel: model, render: render, themeId: model.slideBuildingBinding(\.lyricsImportThemeId))
                Spacer()
                Button("Cancel") { dismiss() }
                if let existingID {
                    Button("Open Library Copy") { dismiss(); onCreated(existingID) }
                    Button("Replace Library Copy") { replace(existingID) }
                        .help("Re-import this song into the copy you already have — services using it keep it")
                        .disabled(!canImport)
                }
                Button(existingID == nil ? "Import Song" : "Import Again", action: importSong)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
            }
        }
        .padding(16)
        .frame(width: 760)
    }

    private var songList: some View {
        List(songs, id: \.id, selection: Binding(
            get: { selectedSong?.id },
            set: { id in
                selectedSong = songs.first { $0.id == id }
                Task { await loadArrangements() }
            }
        )) { song in
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text([song.author, song.ccliNumber.map { "CCLI \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .overlay {
            if songs.isEmpty {
                Text(searching ? "Searching…" : query.isEmpty ? "Type a song title" : "No songs found")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var arrangementPane: some View {
        if selectedSong == nil {
            ContentUnavailableView("Choose a Song", systemImage: "music.note.list")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !arrangements.isEmpty {
                    Picker("Arrangement", selection: $selectedArrangementID) {
                        ForEach(arrangements, id: \.id) { arrangement in
                            Text(label(arrangement)).tag(Optional(arrangement.id))
                        }
                    }
                }
                if !keys.isEmpty {
                    Picker("Key", selection: $playingKey) {
                        Text("Chart key").tag("")
                        ForEach(keys, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let detail {
                    let order = arrangement?.sequence.isEmpty == false ? arrangement!.sequence : detail.sequence
                    if !order.isEmpty {
                        Text("Order: " + order.joined(separator: " → "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(preview(detail))
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    if !canImport {
                        Text("No lyrics or chord chart came back. The Shepherd key needs the songs:lyrics scope, or this song has no lyrics in Shepherd yet.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if existingID != nil {
                    Text("This song is already in your library.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ arrangement: ShepherdClient.SongArrangement) -> String {
        var parts = [arrangement.name.isEmpty ? "Arrangement" : arrangement.name]
        if let tempo = arrangement.tempo { parts.append("\(Int(tempo)) BPM") }
        return parts.joined(separator: " · ")
    }

    private func preview(_ song: ShepherdClient.SongDetail) -> String {
        let chart = [arrangement?.chordChart, song.chordChart]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return chart ?? song.lyrics ?? ""
    }

    private func search() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, sync.isConfigured,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            songs = try await client.searchSongs(query).filter { $0.archived != true }
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func loadArrangements() async {
        guard let song = selectedSong else { return }
        detail = nil
        arrangements = []
        selectedArrangementID = nil
        keys = []
        playingKey = ""
        existingID = await libraryCopy(of: song)
        do {
            let loaded = try await client.song(id: song.id)
            detail = loaded
            arrangements = loaded.arrangements
            selectedArrangementID = arrangements.first?.id
            keys = loaded.keys.map(\.key)
            playingKey = loaded.defaultKey ?? keys.first ?? ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func libraryCopy(of song: ShepherdClient.SongSummary) async -> String? {
        let candidates = ((try? await model.client.presentationMatchKeys()) ?? []).map {
            ServiceLinkLogic.Candidate(id: $0.id, name: $0.name, ccliNumber: $0.ccliNumber, ccliSongTitle: $0.ccliTitle)
        }
        var probe = ServiceItem(id: "", itemKind: .info, name: song.title, refId: "")
        probe.mxuSongTitle = song.title
        probe.mxuCcliNumber = song.ccliNumber.flatMap(Int.init)
        if case .link(_, let id) = ServiceLinkLogic.resolve(
            item: probe, serviceTypeName: nil, rules: ServiceLinkRules(id: "", rules: []), candidates: candidates) {
            return id
        }
        return nil
    }

    private func built() -> Presentation? {
        guard let detail else { return nil }
        return SongImport.presentation(
            song: detail, arrangement: arrangement,
            playingKey: playingKey.isEmpty ? nil : playingKey,
            themeId: model.slideBuilding.lyricsImportThemeId ?? "")
    }

    private func replace(_ id: String) {
        guard let fresh = built() else { return }
        model.updatePresentation(id) { presentation in
            presentation.slides = fresh.slides
            presentation.sections = fresh.sections
            presentation.arrangements = fresh.arrangements
            presentation.defaultArrangementId = fresh.defaultArrangementId
            presentation.reflowSource = fresh.reflowSource
            presentation.chordProSource = fresh.chordProSource
            presentation.musicKey = fresh.musicKey
            presentation.displayKey = fresh.displayKey
            presentation.ccli = fresh.ccli
            presentation.presentationKind = .song
        }
        dismiss()
        onCreated(id)
    }

    private func importSong() {
        guard var presentation = built() else { return }
        presentation.folder = model.newPlacement.folder(for: .presentation)
        model.createInDrive(presentation)
        AddToCurrentServiceToggle.add(presentation.id, model: model, if: addToService)
        // Link it to any Shepherd service that flagged this song.
        Task { await ShepherdSync.shared.relinkFlaggedSongs() }
        dismiss()
        onCreated(presentation.id)
    }
}
