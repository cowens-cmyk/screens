import PresenterCore
import SwiftUI

/// Edit › a song, slide by slide: each card is one slide and says exactly
/// what that slide shows. Above each line of words is an optional chord
/// line for the stage display, typed where the chord is played (the two
/// lines are monospaced so they line up), so a chord is never mistaken for
/// a word. The right side sets the song order and what each screen uses.
struct SongEditorView: View {
    let model: AppModel
    let presentationID: String
    var openSlideEditor: () -> Void = {}

    @State private var title = ""
    @State private var key = ""
    @State private var cards: [SongSlides.Card] = []
    @State private var saved: [SongSlides.Card] = []
    @State private var sequence: [String] = []   // section names, in play order
    @State private var loaded = false
    @State private var lowerThirds = LowerThirdCatalog()
    @State private var pasting = false
    @State private var pastedText = ""
    @State private var pasteLinesPerSlide = 2
    /// The stored slides the cards were made from, to tell when the song
    /// changed underneath unsaved cards (an undo, a Shepherd update).
    @State private var base: [Slide] = []
    /// The title and key as loaded (or last saved), so only a field the
    /// operator changed is written back over the song.
    @State private var baseTitle = ""
    @State private var baseKey = ""
    @State private var changedUnderneath = false

    private var presentation: Presentation? { model.presentation(presentationID) }
    private var sections: [PresentationSection] { presentation?.sections ?? [] }
    private var unsaved: Bool { loaded && cards != saved }
    private var detailsChanged: Bool { loaded && (editedTitle != nil || editedKey != nil) }
    /// The title, when the operator changed it.
    private var editedTitle: String? {
        let title = title.trimmingCharacters(in: .whitespaces)
        return !title.isEmpty && title != baseTitle ? title : nil
    }
    /// The key, when the operator changed it ("" takes it off).
    private var editedKey: String? {
        let key = key.trimmingCharacters(in: .whitespaces)
        return key != baseKey ? key : nil
    }
    /// The stored slides changed since the cards were made from them.
    private var storedChanged: Bool {
        presentation.map { $0.slides != base } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // The window's title bar and mode switcher sit over the top.
            Color.clear.frame(height: ShellView.headerHeight)
            HSplitView {
                slidesPane.frame(minWidth: 380)
                VStack(alignment: .leading, spacing: 16) {
                    sequencePane
                    Divider()
                    screensPane
                }
                .padding(16)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .task(id: presentationID) { load() }
        .sheet(isPresented: $pasting) { pasteSheet }
        // The song changed in the library (an undo, a Shepherd update):
        // cards with nothing typed into them show the new slides.
        .onChange(of: presentation?.slides) { _, _ in
            if loaded, !unsaved, let presentation {
                loadCards(presentation)
                if !detailsChanged { loadDetails(presentation) }
            }
        }
        .onChange(of: cards) { _, _ in registerPending() }
        .onChange(of: title) { _, _ in registerPending() }
        .onChange(of: key) { _, _ in registerPending() }
        // Every other editor saves as you type, so leaving this one (the
        // Slide Editor, another item, Present) saves too rather than
        // dropping the cards. When the song's slides changed meanwhile (a
        // Shepherd update, another Mac) the cards are kept aside instead, and
        // opening the song here again asks which to keep.
        .onDisappear {
            if unsaved, storedChanged {
                SongEditorPending.keepAside(presentationID, cards: cards, base: base)
                if detailsChanged { saveDetails() }
            } else if unsaved {
                commitSlides(onlyOver: base)
            } else if detailsChanged {
                saveDetails()
            }
            SongEditorPending.clear(presentationID)
        }
        .confirmationDialog("This song's slides changed while you were editing.",
                            isPresented: $changedUnderneath) {
            Button("Save My Slides") { commitSlides() }
            Button("Use the New Slides", role: .destructive) {
                if let presentation { loadCards(presentation) }
            }
        } message: {
            Text("Saving puts these cards over the new slides.")
        }
    }

    // MARK: Slides

    private var slidesPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Song title", text: $title)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit(saveDetails)
                TextField("Key", text: $key)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveDetails)
                    .help("The key it's charted in, for the stage display")
            }
            ShepherdSongRow(model: model, presentationID: presentationID, reload: load)
            Text("Each card is one slide. The chord line over each line of words is optional and shows only on the stage display.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($cards) { $card in
                        SongSlideCard(
                            card: $card,
                            number: (cards.firstIndex { $0.id == card.id } ?? 0) + 1,
                            sectionNames: sectionSuggestions,
                            move: { offset in move(card.id, by: offset) },
                            duplicate: { duplicate(card.id) },
                            delete: { cards.removeAll { $0.id == card.id } })
                    }
                    Button { addSlide() } label: {
                        Label("Add Slide", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Paste Lyrics\u{2026}") { pasting = true }
                    .help("Type or paste the words; they're split into slides, keeping section names")
                Button("Slide Editor\u{2026}", action: openSlideEditor)
                Spacer()
                if unsaved {
                    Text("Not saved").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save Slides", action: saveSlides)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!unsaved && !detailsChanged)
            }
        }
        .padding(16)
    }

    /// Names offered for a card's section: the usual ones, then the ones
    /// this song already has.
    private var sectionSuggestions: [String] {
        var names = ["Intro", "Verse 1", "Verse 2", "Verse 3", "Pre-Chorus", "Chorus", "Bridge", "Tag", "Ending"]
        for name in cards.map(\.section) where !name.isEmpty && !names.contains(name) { names.append(name) }
        return names
    }

    private func addSlide() {
        let section = cards.last?.section ?? "Verse 1"
        cards.append(SongSlides.Card(section: section, lines: [SongSlides.Line(), SongSlides.Line()]))
    }

    private func move(_ id: String, by offset: Int) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard cards.indices.contains(target) else { return }
        cards.swapAt(index, target)
    }

    private func duplicate(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        var copy = cards[index]
        copy.id = UUID().uuidString
        copy.lines = copy.lines.map { SongSlides.Line(words: $0.words, chords: $0.chords) }
        cards.insert(copy, at: index + 1)
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Lyrics").font(.headline)
            Text("Put each section's name on its own line (Verse 1, Chorus, Bridge), then its words. A blank line starts a new slide.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $pastedText)
                .font(.body)
                .frame(minWidth: 460, minHeight: 320)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Stepper("\(pasteLinesPerSlide) line\(pasteLinesPerSlide == 1 ? "" : "s") per slide",
                        value: $pasteLinesPerSlide, in: 1...6)
                Spacer()
                Button("Cancel") { pasting = false }
                    .keyboardShortcut(.cancelAction)
                Button(cards.allSatisfy(Self.isEmpty) ? "Make Slides" : "Add Slides") { addPasted() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private static func isEmpty(_ card: SongSlides.Card) -> Bool {
        card.lines.allSatisfy { $0.words.isEmpty && $0.chords.isEmpty }
    }

    /// Pasted words split into cards the way an import splits them; they
    /// replace an empty song's cards, else they go after the last one. A
    /// section pasted again is its cards again, so the repeat is sung.
    private func addPasted() {
        let built = LyricTextImporter.makePresentation(
            LyricCleanup.clean(pastedText, removePunctuation: LyricImportSettings.removePunctuation),
            linesPerSlide: pasteLinesPerSlide)
        let new = SongSlides.cardsAsSung(from: built).filter { !Self.isEmpty($0) }
        if cards.allSatisfy(Self.isEmpty) { cards = new } else { cards += new }
        pastedText = ""
        pasting = false
    }

    // MARK: Sequence

    private var sequencePane: some View {
        SongOrderEditor(model: model, presentationID: presentationID)
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
            .help("Set for every song in More › Lower Thirds. A theme picked here wins for this song.")
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

    // MARK: Load and save

    private func load() {
        guard let presentation else { return }
        loadDetails(presentation)
        loadCards(presentation)
        // Cards kept aside when this song was left with the slides changed
        // under them: back in the editor, and the operator picks.
        if let kept = SongEditorPending.takeKeptAside(presentationID) {
            cards = kept.cards
            base = kept.base
            if presentation.slides != kept.base { changedUnderneath = true }
        }
    }

    private func loadDetails(_ presentation: Presentation) {
        title = presentation.name
        key = presentation.musicKey ?? ""
        baseTitle = title
        baseKey = key
    }

    private func loadCards(_ presentation: Presentation) {
        base = presentation.slides
        cards = SongSlides.cards(from: presentation)
        if cards.isEmpty { cards = [SongSlides.Card(section: "Verse 1", lines: [SongSlides.Line(), SongSlides.Line()])] }
        // A song made empty to type into has one blank slide and no section.
        if cards.count == 1, Self.isEmpty(cards[0]), cards[0].section.isEmpty {
            cards[0].section = "Verse 1"
            cards[0].lines = [SongSlides.Line(), SongSlides.Line()]
        }
        saved = cards
        sequence = Self.order(of: presentation)
        loaded = true
    }

    private static func order(of presentation: Presentation) -> [String] {
        let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
        let arrangement = presentation.arrangements?.first { $0.id == presentation.defaultArrangementId }
            ?? presentation.arrangements?.first
        return arrangement?.sectionIds.compactMap { names[$0] } ?? (presentation.sections ?? []).map(\.name)
    }

    private func saveDetails() {
        Self.write(nil, base: nil, title: editedTitle, key: editedKey, to: presentationID, model: model)
        detailsSaved()
    }

    private func detailsSaved() {
        if let editedTitle { baseTitle = editedTitle }
        if let editedKey { baseKey = editedKey }
    }

    /// Save Slides: the cards go over the stored song, unless the song's
    /// slides changed since the cards were made from them; then the
    /// operator picks which to keep.
    private func saveSlides() {
        if unsaved, storedChanged {
            changedUnderneath = true
            return
        }
        commitSlides()
    }

    /// The cards become the song's slides, sections and order (Save Slides,
    /// and Save My Slides when the operator chose theirs). With `onlyOver`,
    /// only while the stored slides are still those.
    private func commitSlides(onlyOver expected: [Slide]? = nil) {
        guard let built = Self.write(
            cards, base: expected, title: editedTitle, key: editedKey, to: presentationID, model: model)?.song
        else { return }
        detailsSaved()
        base = built.slides
        cards = SongSlides.cards(from: built)
        saved = cards
        sequence = Self.order(of: built)
    }

    /// Writes the cards (when given), title and key (when given) over the
    /// stored song. With `base`, the cards are written only while the
    /// stored slides are still the ones they were made from.
    @discardableResult
    private static func write(
        _ cards: [SongSlides.Card]?, base: [Slide]?, title: String?, key: String?, to id: String, model: AppModel
    ) -> (task: Task<LibraryBatch, any Error>, song: Presentation)? {
        guard var song = model.presentation(id) else { return nil }
        if let cards { SongSlides.apply(cards, to: &song) }
        let built = song
        let withSlides = cards != nil
        let task = model.updatePresentation(id) { current in
            // Checked again as the write lands: newer slides win over cards
            // made from older ones.
            if withSlides, base == nil || current.slides == base {
                current.slides = built.slides
                current.sections = built.sections
                current.arrangements = built.arrangements
                current.defaultArrangementId = built.defaultArrangementId
                current.reflowSource = built.reflowSource
                current.chordProSource = built.chordProSource
            }
            if let title, !title.isEmpty { current.name = title }
            if let key { current.musicKey = key.isEmpty ? nil : key }
        }
        return (task, built)
    }

    /// Hands quitting what's not saved yet, since onDisappear doesn't run
    /// when Screens quits.
    private func registerPending() {
        guard loaded, unsaved || detailsChanged else {
            SongEditorPending.clear(presentationID)
            return
        }
        // Quitting can't ask, so cards made from slides that have changed
        // since are not written over them.
        let cards: [SongSlides.Card]? = unsaved ? cards : nil
        let (base, title, key, id, model) = (base, editedTitle, editedKey, presentationID, model)
        SongEditorPending.pending = (id, {
            Self.write(cards, base: base, title: title, key: key, to: id, model: model)?.task
        })
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

/// One slide of a song: its section, then each line of words with an
/// optional chord line over it. Both lines are monospaced, so a chord
/// typed over a word lands on that word on the stage display.
private struct SongSlideCard: View {
    @Binding var card: SongSlides.Card
    let number: Int
    let sectionNames: [String]
    let move: (Int) -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    @FocusState private var focusedLine: String?

    private static let mono = Font.system(size: 14, design: .monospaced)
    private static let chordMono = Font.system(size: 12, weight: .semibold, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 18, alignment: .leading)
                TextField("Section", text: $card.section)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Menu {
                    ForEach(sectionNames, id: \.self) { name in
                        Button(name) { card.section = name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a section")
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .help("Move this slide up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .help("Move this slide down")
                Button(action: duplicate) { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate this slide")
                Button(action: delete) { Image(systemName: "trash") }
                    .help("Delete this slide")
            }
            .buttonStyle(.borderless)

            ForEach($card.lines) { $line in
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Chords (optional, stage only)", text: $line.chords)
                        .font(Self.chordMono)
                        .foregroundStyle(.orange)
                        .textFieldStyle(.plain)
                    HStack(spacing: 6) {
                        TextField("Words on the slide", text: $line.words)
                            .font(Self.mono)
                            .textFieldStyle(.plain)
                            .focused($focusedLine, equals: line.id)
                            .onSubmit { addLine(after: line.id) }
                        if card.lines.count > 1 {
                            Button { removeLine(line.id) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this line")
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Button { addLine(after: card.lines.last?.id) } label: {
                Label("Line", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Add a line to this slide (or press Return in the last line)")
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func addLine(after id: String?) {
        let index = id.flatMap { id in card.lines.firstIndex { $0.id == id } }.map { $0 + 1 } ?? card.lines.count
        let line = SongSlides.Line()
        card.lines.insert(line, at: index)
        focusedLine = line.id
    }

    private func removeLine(_ id: String) {
        card.lines.removeAll { $0.id == id }
    }
}

/// The song editor's cards and details that aren't saved yet, so quitting
/// can save them first.
@MainActor
enum SongEditorPending {
    static var pending: (id: String, save: () -> Task<LibraryBatch, any Error>?)?

    static func clear(_ id: String) {
        if pending?.id == id { pending = nil }
    }

    /// Cards left unsaved on a song whose slides changed under them, by
    /// song id, until the song is opened in the editor again.
    private static var keptAside: [String: (cards: [SongSlides.Card], base: [Slide])] = [:]

    static func keepAside(_ id: String, cards: [SongSlides.Card], base: [Slide]) {
        keptAside[id] = (cards, base)
    }

    static func hasKeptAside(_ id: String) -> Bool { keptAside[id] != nil }

    static func takeKeptAside(_ id: String) -> (cards: [SongSlides.Card], base: [Slide])? {
        keptAside.removeValue(forKey: id)
    }

    /// Saves them; returns the write to wait for, if there was one.
    static func save() -> Task<LibraryBatch, any Error>? {
        defer { pending = nil }
        return pending?.save()
    }
}
