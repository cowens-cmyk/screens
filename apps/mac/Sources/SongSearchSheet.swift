import PresenterCore
import SwiftUI

/// Find a song in the Planning Center library (where MultiTracks and
/// SongSelect charts already live), pick the arrangement the band plays,
/// and bring it in with its sections, chords, key and song order.
struct SongSearchSheet: View {
    let model: AppModel
    let render: RenderContext?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var songs: [PCOClient.Song] = []
    @State private var selectedSong: PCOClient.Song?
    @State private var arrangements: [PCOClient.Arrangement] = []
    @State private var selectedArrangementID: String?
    @State private var keys: [String] = []
    @State private var playingKey = ""
    @State private var existingID: String?
    @State private var searching = false
    @State private var error: String?

    private var client: PCOClient { PlanningCenterSync.shared.client }
    private var arrangement: PCOClient.Arrangement? { arrangements.first { $0.id == selectedArrangementID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Song Search").font(.headline)
            if !client.isConfigured {
                Text("Add your Planning Center token in Settings › Planning Center to search your song library.")
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
            HStack {
                LyricsThemeChooser(appModel: model, render: render, themeId: model.slideBuildingBinding(\.lyricsImportThemeId))
                Spacer()
                Button("Cancel") { dismiss() }
                if let existingID {
                    Button("Open Library Copy") { dismiss(); onCreated(existingID) }
                }
                Button(existingID == nil ? "Import Song" : "Import Again", action: importSong)
                    .keyboardShortcut(.defaultAction)
                    .disabled(arrangement == nil || !hasText(arrangement))
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
                Picker("Arrangement", selection: $selectedArrangementID) {
                    ForEach(arrangements, id: \.id) { arrangement in
                        Text(label(arrangement)).tag(Optional(arrangement.id))
                    }
                }
                .onChange(of: selectedArrangementID) { _, _ in Task { await loadKeys() } }
                if !keys.isEmpty {
                    Picker("Key", selection: $playingKey) {
                        Text("Chart key").tag("")
                        ForEach(keys, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let arrangement {
                    if !arrangement.sequence.isEmpty {
                        Text("Order: " + arrangement.sequence.joined(separator: " → "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(preview(arrangement))
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    if !hasText(arrangement) {
                        Text("This arrangement has no lyrics or chord chart in Planning Center.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if existingID != nil {
                    Text("This song is already in your library.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ arrangement: PCOClient.Arrangement) -> String {
        var parts = [arrangement.name.isEmpty ? "Arrangement" : arrangement.name]
        if let key = arrangement.chordChartKey, !key.isEmpty { parts.append(key) }
        if let bpm = arrangement.bpm { parts.append("\(Int(bpm)) BPM") }
        return parts.joined(separator: " · ")
    }

    private func hasText(_ arrangement: PCOClient.Arrangement?) -> Bool {
        guard let arrangement else { return false }
        return !(arrangement.chordChart ?? arrangement.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(arrangement.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func preview(_ arrangement: PCOClient.Arrangement) -> String {
        let chart = arrangement.chordChart ?? ""
        let text = chart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (arrangement.lyrics ?? "") : chart
        return text.replacingOccurrences(of: "COLUMN_BREAK", with: "").replacingOccurrences(of: "PAGE_BREAK", with: "")
    }

    private func search() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, client.isConfigured else { return }
        searching = true
        defer { searching = false }
        do {
            songs = try await client.searchSongs(query)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func loadArrangements() async {
        guard let song = selectedSong else { return }
        arrangements = []
        selectedArrangementID = nil
        keys = []
        playingKey = ""
        existingID = await libraryCopy(of: song)
        do {
            arrangements = try await client.arrangements(songID: song.id)
            selectedArrangementID = arrangements.first?.id
            await loadKeys()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadKeys() async {
        guard let song = selectedSong, let arrangement else { return }
        keys = (try? await client.keys(songID: song.id, arrangementID: arrangement.id)) ?? []
        playingKey = keys.first ?? ""
    }

    private func libraryCopy(of song: PCOClient.Song) async -> String? {
        let candidates = ((try? await model.client.presentationMatchKeys()) ?? []).map {
            ServiceLinkLogic.Candidate(id: $0.id, name: $0.name, ccliNumber: $0.ccliNumber, ccliSongTitle: $0.ccliTitle)
        }
        var probe = ServiceItem(id: "", itemKind: .info, name: song.title, refId: "")
        probe.mxuSongTitle = song.title
        probe.mxuCcliNumber = song.ccliNumber
        if case .link(_, let id) = ServiceLinkLogic.resolve(
            item: probe, serviceTypeName: nil, rules: ServiceLinkRules(id: "", rules: []), candidates: candidates) {
            return id
        }
        return nil
    }

    private func importSong() {
        guard let song = selectedSong, let arrangement,
              var presentation = PlanningCenterSync.importSong(
                  title: song.title, song: song, arrangement: arrangement,
                  playingKey: playingKey.isEmpty ? nil : playingKey,
                  themeId: model.slideBuilding.lyricsImportThemeId ?? "")
        else { return }
        presentation.folder = model.newPlacement.folder(for: .presentation)
        model.createInDrive(presentation)
        dismiss()
        onCreated(presentation.id)
    }
}
