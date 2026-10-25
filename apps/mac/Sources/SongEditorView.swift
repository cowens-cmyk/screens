import PresenterCore
import SwiftUI

/// Edit › a song: type or paste the lyrics with section names on their own
/// line ("Verse 1", "Chorus"), set how many lines go on a slide, drag the
/// sections into the order the band plays them, and choose what each screen
/// uses. Slides rebuild from the lyrics; the slide editor stays a click away
/// for fine-tuning.
struct SongEditorView: View {
    let model: AppModel
    let presentationID: String
    var openSlideEditor: () -> Void = {}

    @State private var title = ""
    @State private var key = ""
    @State private var lyrics = ""
    @State private var linesPerSlide = 2
    @State private var sequence: [String] = []   // section names, in play order
    @State private var loaded = false
    @State private var lowerThirds = LowerThirdCatalog()

    private var presentation: Presentation? { model.presentation(presentationID) }
    private var sections: [PresentationSection] { presentation?.sections ?? [] }

    var body: some View {
        HSplitView {
            lyricsPane.frame(minWidth: 320)
            VStack(alignment: .leading, spacing: 16) {
                sequencePane
                Divider()
                screensPane
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
        }
        .task(id: presentationID) { load() }
    }

    // MARK: Lyrics

    private var lyricsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Song title", text: $title)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit(save)
                TextField("Key", text: $key)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .help("The key it's charted in, for the stage display")
            }
            Text("Put each section's name on its own line (Verse 1, Chorus, Bridge), then its lyrics.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $lyrics)
                .font(.system(.body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Stepper("\(linesPerSlide) line\(linesPerSlide == 1 ? "" : "s") per slide", value: $linesPerSlide, in: 1...6)
                Spacer()
                Button("Slide Editor…", action: openSlideEditor)
                Button("Update Slides", action: rebuild)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    // MARK: Sequence

    private var sequencePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Song Order").font(.headline)
            Text("Drag to reorder. Click a section below to add it again.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(sequence.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 8) {
                        Circle().fill(color(for: name)).frame(width: 10, height: 10)
                        Text(name)
                        Spacer()
                        Button { sequence.remove(at: index); saveSequence() } label: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from the order")
                    }
                }
                .onMove { from, to in
                    sequence.move(fromOffsets: from, toOffset: to)
                    saveSequence()
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 180)
            FlowChips(names: sections.map(\.name), color: color(for:)) { name in
                sequence.append(name)
                saveSequence()
            }
        }
    }

    private func color(for name: String) -> Color {
        GroupColor.fill(sections.first { $0.name == name }, palette: model.groupColors) ?? .secondary
    }

    // MARK: Screens

    private var screensPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screens").font(.headline)
            Picker("Audience", selection: binding(\.themeId, empty: "")) {
                ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Livestream", selection: optionalBinding(\.streamThemeId)) {
                // Left empty, the song follows its type, so the label says
                // what that is.
                Text(presentation.map { InheritedLivestreamLabel.text(for: $0, model: model, catalog: lowerThirds) } ?? "Type default")
                    .tag("")
                Divider()
                ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
            }
            .help("Set for every song in More › Lower Thirds & Themes. A theme picked here wins for this song.")
            .task(id: model.version(of: .theme)) { lowerThirds = await LowerThirdCatalog.load(model) }
            Picker("Stage", selection: optionalBinding(\.stageLayoutId)) {
                Text("Worship (chords, current, next, key, time)").tag("")
                ForEach(model.entries(of: .confidenceLayout), id: \.id) { Text($0.name).tag($0.id) }
            }
        }
    }

    private func binding(_ path: WritableKeyPath<Presentation, String>, empty: String) -> Binding<String> {
        Binding(
            get: { presentation?[keyPath: path] ?? empty },
            set: { value in model.updatePresentation(presentationID) { $0[keyPath: path] = value } })
    }

    private func optionalBinding(_ path: WritableKeyPath<Presentation, String?>) -> Binding<String> {
        Binding(
            get: { presentation?[keyPath: path] ?? "" },
            set: { value in model.updatePresentation(presentationID) { $0[keyPath: path] = value.isEmpty ? nil : value } })
    }

    // MARK: Load, rebuild, save

    private func load() {
        guard let presentation else { return }
        title = presentation.name
        key = presentation.musicKey ?? ""
        lyrics = presentation.reflowSource ?? Self.lyrics(from: presentation)
        let sectionNames = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        let arrangement = presentation.arrangements?.first { $0.id == presentation.defaultArrangementId }
            ?? presentation.arrangements?.first
        sequence = arrangement?.sectionIds.compactMap { sectionNames[$0] } ?? (presentation.sections ?? []).map(\.name)
        loaded = true
    }

    /// Lyrics written back out from slides, for songs made before the editor.
    static func lyrics(from presentation: Presentation) -> String {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        var lastSection: String?
        var lines: [String] = []
        for slide in presentation.slides {
            if let section = slide.sectionId, section != lastSection, let name = names[section] {
                if !lines.isEmpty { lines.append("") }
                lines.append(name)
                lastSection = section
            }
            if let text = slide.objects.first(where: { $0.objectKind == .text })?.text, !text.isEmpty {
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func save() {
        let title = title.trimmingCharacters(in: .whitespaces)
        let key = key.trimmingCharacters(in: .whitespaces)
        model.updatePresentation(presentationID) { song in
            if !title.isEmpty { song.name = title }
            song.musicKey = key.isEmpty ? nil : key
        }
    }

    /// New slides from the lyrics, keeping the song's theme and its order.
    private func rebuild() {
        guard let current = presentation,
              let built = SongAssembly.presentation(
                  lyrics: lyrics, chordChart: nil, title: title.isEmpty ? current.name : title,
                  themeId: current.themeId, linesPerSlide: linesPerSlide)
        else { return }
        let newNames = (built.sections ?? []).map(\.name)
        // Keep the order the operator set where those sections still exist.
        let kept = sequence.filter(newNames.contains)
        sequence = kept.isEmpty ? newNames : kept
        let order = sequence
        let lyricsText = lyrics
        let title = title
        model.updatePresentation(presentationID) { song in
            song.slides = built.slides
            song.sections = built.sections
            song.reflowSource = lyricsText
            song.chordProSource = built.chordProSource
            if !title.isEmpty { song.name = title }
            Self.applyOrder(order, to: &song)
        }
        save()
    }

    private func saveSequence() {
        let order = sequence
        model.updatePresentation(presentationID) { Self.applyOrder(order, to: &$0) }
    }

    /// The song's default arrangement becomes `order` (section names).
    static func applyOrder(_ order: [String], to song: inout Presentation) {
        let byName = Dictionary((song.sections ?? []).map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let ids = order.compactMap { byName[$0] }
        let arrangementID = song.defaultArrangementId ?? UUID().uuidString
        var arrangements = song.arrangements ?? []
        if let index = arrangements.firstIndex(where: { $0.id == arrangementID }) {
            arrangements[index].sectionIds = ids
        } else {
            arrangements.append(Arrangement(id: arrangementID, name: "Default", sectionIds: ids))
        }
        song.arrangements = arrangements
        song.defaultArrangementId = arrangementID
    }
}

/// Section chips that wrap onto new lines; clicking one adds it to the order.
private struct FlowChips: View {
    let names: [String]
    let color: (String) -> Color
    let add: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button { add(name) } label: {
                    Label(name, systemImage: "plus")
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(color(name).opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
