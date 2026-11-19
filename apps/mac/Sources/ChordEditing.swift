import AppKit
import PresenterCore
import SlideScene
import SwiftUI

// MARK: Writing

extension AppModel {
    /// One line's chords, changed by `mutate` (columns along the line), and
    /// kept as the operator's (ChordEdits) so a rebuild from Shepherd or a
    /// refit puts them back. `text`: the line's words too (ChordPro typed
    /// with other words).
    func writeChordLine(
        presentationID: String, slideID: String, objectID: String, line: Int, text: String? = nil,
        _ mutate: @escaping @Sendable (inout [ChordPlacement]) -> Void
    ) {
        _ = updateSlide(presentationID: presentationID, slideID: slideID, undoLabel: "Edit Chords") { slide in
            guard let index = slide.objects.firstIndex(where: { $0.id == objectID }) else { return }
            var object = slide.objects[index]
            if let text {
                var lines = object.text.components(separatedBy: "\n")
                guard lines.indices.contains(line) else { return }
                lines[line] = text
                object.text = lines.joined(separator: "\n")
            }
            let all = object.chords ?? []
            var own = all.filter { $0.line == line }.sorted { $0.column < $1.column }
            mutate(&own)
            var chords = all.filter { $0.line != line }
            chords += own.map { ChordPlacement(line: line, column: $0.column, symbol: $0.symbol) }
            chords.sort { ($0.line, $0.column) < ($1.line, $1.column) }
            object.chords = chords.isEmpty ? nil : chords
            slide.objects[index] = object
        }
        recordChordEdits(presentationID: presentationID) { $0.slideID == slideID && $0.line == line }
    }

    /// Several lines' chords at once (Copy Chords From, Clear), then recorded.
    func writeChords(
        presentationID: String, undoLabel: String,
        _ change: @escaping @Sendable (Presentation) -> Presentation,
        touched: @escaping @Sendable (ChordEdits.LineRef) -> Bool
    ) {
        updateSlides(presentationID: presentationID, undoLabel: undoLabel) { presentation in
            presentation = change(presentation)
        }
        recordChordEdits(presentationID: presentationID, touched)
    }

    /// The lines `touched` picks, recorded as they now stand. A write of its
    /// own after the slides', so it reads the chords that write left.
    func recordChordEdits(presentationID: String, _ touched: @escaping @Sendable (ChordEdits.LineRef) -> Bool) {
        _ = updatePresentation(presentationID) { presentation in
            presentation.chordEdits = ChordEdits.recordingAll(in: presentation, where: touched)
        }
    }
}

// MARK: Session

/// What the chord editors share: which chord is being typed, the chord
/// picked from the palette to place with each click, and the lines shown.
@MainActor @Observable
final class ChordSession {
    let model: AppModel
    let presentationID: String

    enum Scope: Hashable {
        case all
        case slide(String)
        /// A section's slides; "" for slides in none.
        case section(String)
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var slideID: String
        var objectID: String
        var sectionID: String?
        var header: String?
        var line: Int
        var text: String
        var chords: [ChordPlacement]
    }

    struct Spot: Hashable {
        var rowID: String
        var column: Int
    }

    var scope: Scope
    /// The chord being typed, where it goes.
    var editing: Spot?
    var text = ""
    /// Picked in the palette: each click on a word places it.
    var armed: String?

    init(model: AppModel, presentationID: String, scope: Scope) {
        self.model = model
        self.presentationID = presentationID
        self.scope = scope
    }

    var presentation: Presentation? { model.presentation(presentationID) }

    var rows: [Row] {
        guard let presentation else { return [] }
        return Self.rows(of: presentation).filter { row in
            switch scope {
            case .all: true
            case .slide(let id): row.slideID == id
            case .section(let id): (row.sectionID ?? "") == id
            }
        }
    }

    static func rows(of presentation: Presentation) -> [Row] {
        let names = Dictionary(
            (presentation.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var rows: [Row] = []
        var slideNumber = 0
        for slide in presentation.slides {
            guard let object = ChordEdits.lyricObject(of: slide) else { continue }
            slideNumber += 1
            let byLine = Dictionary(grouping: object.chords ?? [], by: \.line)
            let section = slide.sectionId.flatMap { names[$0] }
            for (index, line) in object.text.components(separatedBy: "\n").enumerated() {
                rows.append(Row(
                    id: "\(slide.id)#\(index)", slideID: slide.id, objectID: object.id, sectionID: slide.sectionId,
                    header: index == 0
                        ? [section, "Slide \(slideNumber)"].compactMap(\.self).joined(separator: " \u{00B7} ") : nil,
                    line: index, text: line,
                    chords: (byLine[index] ?? []).sorted { $0.column < $1.column }))
            }
        }
        return rows
    }

    private func row(_ id: String) -> Row? {
        presentation.flatMap { Self.rows(of: $0).first { $0.id == id } }
    }

    // MARK: Actions

    /// A click on a line: the palette's chord goes straight there, else a
    /// chord is typed there (the one already there, to change it).
    func click(_ row: Row, column: Int) {
        commit()
        if let armed {
            set(armed, at: column, row: row)
        } else {
            open(row, column: column)
        }
    }

    func open(_ row: Row, column: Int) {
        let fresh = self.row(row.id) ?? row
        editing = Spot(rowID: row.id, column: column)
        text = fresh.chords.first { $0.column == column }?.symbol ?? ""
    }

    /// The chord typed is written; typed empty, the chord there goes.
    func commit() {
        guard let spot = editing else { return }
        editing = nil
        guard let row = row(spot.rowID) else { return }
        let symbol = text.trimmingCharacters(in: .whitespaces)
        let was = row.chords.first { $0.column == spot.column }?.symbol ?? ""
        guard symbol != was else { return }
        set(symbol, at: spot.column, row: row)
    }

    func cancel() {
        editing = nil
    }

    /// The chord being typed taken out.
    func removeEditing() {
        guard let spot = editing else { return }
        editing = nil
        if let row = row(spot.rowID) { set("", at: spot.column, row: row) }
    }

    func set(_ symbol: String, at column: Int, row: Row) {
        model.writeChordLine(
            presentationID: presentationID, slideID: row.slideID, objectID: row.objectID, line: row.line
        ) { chords in
            chords.removeAll { $0.column == column }
            if !symbol.isEmpty { chords.append(ChordPlacement(line: 0, column: column, symbol: symbol)) }
            chords.sort { $0.column < $1.column }
        }
    }

    func move(_ row: Row, from: Int, to: Int) {
        guard from != to else { return }
        model.writeChordLine(
            presentationID: presentationID, slideID: row.slideID, objectID: row.objectID, line: row.line
        ) { chords in
            guard let index = chords.firstIndex(where: { $0.column == from }) else { return }
            var chord = chords.remove(at: index)
            chords.removeAll { $0.column == to }
            chord.column = to
            chords.append(chord)
            chords.sort { $0.column < $1.column }
        }
    }

    /// ⌥← ⌥→ while typing: the chord one letter along.
    func nudge(_ step: Int) {
        guard let spot = editing, let row = row(spot.rowID) else { return }
        let to = min(max(0, spot.column + step), row.text.count)
        guard to != spot.column else { return }
        if row.chords.contains(where: { $0.column == spot.column }) { move(row, from: spot.column, to: to) }
        editing = Spot(rowID: spot.rowID, column: to)
    }

    /// Tab: the chord typed is written and the next word gets one, on to
    /// the next line with words. Shift-Tab goes back.
    func tab(forward: Bool) {
        guard let spot = editing else { return }
        let order = rows
        commit()
        guard let index = order.firstIndex(where: { $0.id == spot.rowID }) else { return }
        let row = order[index]
        if forward {
            if let next = ChordEdits.nextWordStart(in: row.text, after: spot.column) {
                return open(row, column: next)
            }
            for later in order[(index + 1)...] {
                if let first = ChordEdits.firstWordStart(in: later.text) { return open(later, column: first) }
            }
        } else {
            if let previous = ChordEdits.previousWordStart(in: row.text, before: spot.column) {
                return open(row, column: previous)
            }
            for earlier in order[..<index].reversed() {
                if let last = ChordEdits.lastWordStart(in: earlier.text) { return open(earlier, column: last) }
            }
        }
    }

    /// A palette chord: fills the chord being typed, else is picked to place
    /// with each click (picked again, it's put down).
    func pick(_ symbol: String) {
        if editing != nil {
            text = symbol
            tab(forward: true)
        } else {
            armed = armed == symbol ? nil : symbol
        }
    }
}

// MARK: Views

enum ChordInk {
    static let color = Color(red: 1.0, green: 0.72, blue: 0.15)
    static let nsColor = NSColor(red: 1.0, green: 0.72, blue: 0.15, alpha: 1)
}

/// One lyric line with its chords above. Click any letter to put a chord
/// over it (or the palette's chord, when one is picked); click a chord to
/// change it, drag it along, right-click to take it out.
struct ChordLineRow: View {
    @Bindable var session: ChordSession
    let row: ChordSession.Row
    let size: CGFloat

    @State private var drag: (from: Int, to: Int)?
    /// The letter under the pointer, kept here so moving over one line
    /// doesn't redraw every other.
    @State private var hover: Int?

    private var lyricFont: NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    private var chordFont: NSFont { .monospacedSystemFont(ofSize: size * 0.86, weight: .bold) }
    private var charWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: lyricFont]).width }
    private var stripHeight: CGFloat { size * 1.7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: stripHeight)
                ghost
                ForEach(row.chords, id: \.column) { chord in
                    if session.editing != ChordSession.Spot(rowID: row.id, column: chord.column) {
                        chip(chord)
                    }
                }
                if let spot = session.editing, spot.rowID == row.id {
                    field(spot)
                }
            }
            ZStack(alignment: .topLeading) {
                if let hover, session.editing == nil {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: charWidth, height: size * 1.25)
                        .offset(x: x(hover))
                }
                Text(row.text.isEmpty ? " " : row.text)
                    .font(Font(lyricFont))
                    .lineLimit(1)
                    .fixedSize()
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let column = column(at: point.x)
                if hover != column { hover = column }
            case .ended:
                hover = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            session.click(row, column: column(at: point.x))
        }
    }

    /// The letter under `x`, or the end of the line past its last letter.
    private func column(at x: CGFloat) -> Int {
        min(max(0, Int(x / charWidth)), row.text.count)
    }

    private func x(_ column: Int) -> CGFloat {
        CGFloat(min(column, row.text.count)) * charWidth
    }

    /// Where a click would put a chord: a + or the palette's chord, faint.
    @ViewBuilder
    private var ghost: some View {
        if let hover, session.editing == nil, !row.chords.contains(where: { $0.column == hover }) {
            Text(session.armed ?? "+")
                .font(Font(chordFont))
                .foregroundStyle(ChordInk.color.opacity(0.45))
                .offset(x: x(hover), y: stripHeight * 0.18)
                .allowsHitTesting(false)
        }
    }

    private func chip(_ chord: ChordPlacement) -> some View {
        let column = (drag?.from == chord.column ? drag?.to : nil) ?? chord.column
        return Text(chord.symbol.isEmpty ? "\u{2022}" : chord.symbol)
            .font(Font(chordFont))
            .foregroundStyle(ChordInk.color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(ChordInk.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { session.click(row, column: chord.column) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        drag = (chord.column, snapped(chord.column, value.translation.width))
                    }
                    .onEnded { value in
                        let to = snapped(chord.column, value.translation.width)
                        drag = nil
                        session.move(row, from: chord.column, to: to)
                    }
            )
            .contextMenu {
                Button("Change\u{2026}") { session.open(row, column: chord.column) }
                Button("Remove") { session.set("", at: chord.column, row: row) }
                let palette = ChordEdits.palette(musicKey: session.presentation?.musicKey, in: session.presentation)
                if !palette.isEmpty {
                    Divider()
                    ForEach(palette.prefix(12), id: \.self) { symbol in
                        Button(symbol) { session.set(symbol, at: chord.column, row: row) }
                    }
                }
            }
            .help("Click to change \u{00B7} drag to move \u{00B7} right-click to remove")
            .offset(x: x(column) - 3, y: stripHeight * 0.12)
    }

    private func snapped(_ base: Int, _ translation: CGFloat) -> Int {
        min(max(0, Int((CGFloat(base) + translation / charWidth).rounded())), row.text.count)
    }

    private func field(_ spot: ChordSession.Spot) -> some View {
        HStack(spacing: 2) {
            ChordField(
                text: $session.text, font: chordFont, color: ChordInk.nsColor,
                onCommit: { session.commit() },
                onCancel: { session.cancel() },
                onTab: { session.tab(forward: $0) },
                onDeleteEmpty: { session.removeEditing() },
                onNudge: { session.nudge($0) },
                onFocusLost: { if session.editing == spot { session.commit() } })
                .frame(width: max(size * 3.6, CGFloat(session.text.count + 2) * charWidth), height: size * 1.3)
            Button {
                session.removeEditing()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this chord")
        }
        .padding(.horizontal, 3)
        .background(ChordInk.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
        .id("field-" + row.id)
        .offset(x: x(spot.column) - 3, y: stripHeight * 0.06)
        .zIndex(1)
    }
}

/// The chord text box: Return writes it, Tab writes it and moves to the
/// next word, Esc leaves it, ⌫ on an empty box takes the chord out, ⌥← ⌥→
/// move it a letter.
struct ChordField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onTab: (Bool) -> Void
    var onDeleteEmpty: () -> Void
    var onNudge: (Int) -> Void
    var onFocusLost: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.placeholderString = "Chord"
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.handled = false
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChordField
        /// A key already ended this edit, so losing focus after it is no commit.
        var handled = false

        init(_ parent: ChordField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                handled = true
                parent.onCommit()
            case #selector(NSResponder.cancelOperation(_:)):
                handled = true
                parent.onCancel()
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(true)
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onTab(false)
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
                handled = true
                parent.onDeleteEmpty()
            case #selector(NSResponder.moveWordLeft(_:)):
                parent.onNudge(-1)
            case #selector(NSResponder.moveWordRight(_:)):
                parent.onNudge(1)
            default:
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if !handled { parent.onFocusLost() }
        }
    }
}

/// The key's chords and the song's own, one click each: with a chord being
/// typed it fills it in; otherwise it's picked, and every click on a word
/// places it until it's clicked again or Esc.
struct ChordPaletteBar: View {
    @Bindable var session: ChordSession

    var body: some View {
        let chords = ChordEdits.palette(musicKey: session.presentation?.musicKey, in: session.presentation)
        HStack(spacing: 8) {
            if chords.isEmpty {
                Text("Pick the song's key to get its chords here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(chords, id: \.self) { symbol in
                            let picked = session.armed == symbol
                            Button { session.pick(symbol) } label: {
                                Text(symbol)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundStyle(picked ? Color.black : ChordInk.color)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        picked ? ChordInk.color : ChordInk.color.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .help(picked ? "Click words to place \(symbol) \u{00B7} click again to stop"
                                         : "Click, then click words to place \(symbol)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if let armed = session.armed {
                Text("Placing \(armed)").font(.caption.weight(.semibold))
                Button("Stop") { session.armed = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Key picker shared by the chord sheet and window.
struct ChordKeyPicker: View {
    let model: AppModel
    let presentationID: String

    static let keyNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    var body: some View {
        Picker("Key", selection: binding) {
            Text("None").tag("")
            Divider()
            ForEach(Self.keyNames, id: \.self) { Text($0).tag($0) }
            ForEach(Self.keyNames, id: \.self) { Text($0 + "m").tag($0 + "m") }
        }
        .fixedSize()
        .help("The key these chords are written in \u{2014} display keys transpose from here")
    }

    private var binding: Binding<String> {
        Binding(
            get: { model.presentation(presentationID)?.musicKey ?? "" },
            set: { value in
                model.updatePresentationField(
                    presentationID, \.musicKey, key: "musicKey", to: value.isEmpty ? nil : value,
                    undoLabel: "Set Key")
                if value.isEmpty {
                    model.updatePresentationField(
                        presentationID, \.displayKey, key: "displayKey", to: nil, undoLabel: "Set Key")
                }
            })
    }
}

/// One line typed as ChordPro ("[G]Amazing [C]grace"), for those who'd
/// rather type than click.
struct ChordProLineField: View {
    let projected: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .onAppear { draft = projected }
            .onChange(of: projected) { _, value in
                if !focused { draft = value }
            }
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != projected { commit(draft) }
            }
    }

    static func projected(_ row: ChordSession.Row) -> String {
        ChordMath.bracketed(row.text, chords: row.chords.map {
            ChordPlacement(line: 0, column: $0.column, symbol: $0.symbol)
        })
    }

    static func write(_ text: String, row: ChordSession.Row, session: ChordSession) {
        let extracted = ChordMath.extractLine(text.components(separatedBy: "\n").first ?? text)
        let chords = extracted.chords
        session.model.writeChordLine(
            presentationID: session.presentationID, slideID: row.slideID, objectID: row.objectID,
            line: row.line, text: extracted.text
        ) { line in
            line = chords.map { ChordPlacement(line: 0, column: $0.column, symbol: $0.symbol) }
        }
    }
}

/// The lines of the session's scope, grouped under their slide headers.
struct ChordRowsList: View {
    @Bindable var session: ChordSession
    let size: CGFloat
    let showChordPro: Bool

    var body: some View {
        let _ = session.model.listVersion
        let rows = session.rows
        if rows.isEmpty {
            ContentUnavailableView(
                "No Lyrics", systemImage: "music.note.list",
                description: Text("Add words to the slides first; chords sit on lyric lines."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        if let header = row.header {
                            Text(header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, row.id == rows.first?.id ? 0 : 16)
                        }
                        HStack(alignment: .bottom, spacing: 16) {
                            ChordLineRow(session: session, row: row, size: size)
                            if showChordPro {
                                Divider()
                                ChordProLineField(projected: ChordProLineField.projected(row)) {
                                    ChordProLineField.write($0, row: row, session: session)
                                }
                                .frame(width: 320)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ChordHelpLine: View {
    var body: some View {
        Text("Click any letter to add a chord \u{00B7} Tab: next word \u{00B7} \u{2325}\u{2190} \u{2325}\u{2192}: move a letter \u{00B7} drag a chord to move it \u{00B7} saved with the song")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: Chords window

/// What Window › Chords opens: a song, at one of its sections.
struct ChordsWindowTarget: Codable, Hashable {
    var presentationID: String
    /// A section's id, "" for slides in none; nil for the whole song.
    var sectionID: String?
}

/// The whole song's chords in a window of their own: its sections down the
/// side, the chosen section's slides large on the right, the key's chords
/// along the top. Copy one section's chords onto another in one go.
struct ChordsWindowView: View {
    let model: AppModel
    let target: ChordsWindowTarget

    @State private var session: ChordSession
    @State private var selection: ChordSession.Scope
    @HotDefault("chords.showChordPro") private var showChordPro = false
    @HotDefault("chords.windowTextSize") private var textSize = 20.0

    init(model: AppModel, target: ChordsWindowTarget) {
        self.model = model
        self.target = target
        let scope: ChordSession.Scope = target.sectionID.map { .section($0) } ?? .all
        _session = State(initialValue: ChordSession(model: model, presentationID: target.presentationID, scope: scope))
        _selection = State(initialValue: scope)
    }

    struct SectionRow: Identifiable {
        var id: String
        var name: String
        var color: Color?
        var chordCount: Int
        var lineCount: Int
    }

    var body: some View {
        let _ = model.listVersion
        let presentation = model.presentation(target.presentationID)
        NavigationSplitView {
            List(selection: $selection) {
                Label("Whole Song", systemImage: "music.note.list").tag(ChordSession.Scope.all)
                Section("Sections") {
                    ForEach(sections(presentation)) { section in
                        HStack(spacing: 8) {
                            Circle().fill(section.color ?? Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                            Text(section.name)
                            Spacer()
                            Text(section.chordCount == 0 ? "no chords" : "\(section.chordCount)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(ChordSession.Scope.section(section.id))
                        .contextMenu { sectionMenu(section, in: presentation) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                toolbarRow(presentation)
                Divider()
                ChordPaletteBar(session: session)
                Divider()
                if presentation == nil {
                    ContentUnavailableView("Song not found", systemImage: "questionmark.square.dashed")
                        .frame(maxHeight: .infinity)
                } else {
                    ChordRowsList(session: session, size: textSize, showChordPro: showChordPro)
                }
            }
        }
        .navigationTitle(presentation.map { "Chords \u{2014} \($0.name)" } ?? "Chords")
        .frame(minWidth: 820, minHeight: 480)
        .onChange(of: selection) { _, scope in
            session.commit()
            session.scope = scope
        }
        .onExitCommand {
            if session.editing != nil { session.cancel() } else { session.armed = nil }
        }
    }

    private func toolbarRow(_ presentation: Presentation?) -> some View {
        HStack(spacing: 12) {
            ChordKeyPicker(model: model, presentationID: target.presentationID)
            ChordHelpLine()
            Spacer()
            if case .section(let id) = selection, let presentation,
               let current = sections(presentation).first(where: { $0.id == id }) {
                Menu("Section") { sectionMenu(current, in: presentation) }
                    .fixedSize()
            }
            Toggle("ChordPro", isOn: $showChordPro)
                .toggleStyle(.button)
                .help("Type each line as ChordPro beside it: [G]Amazing [C]grace")
            Picker("Size", selection: $textSize) {
                Text("Small").tag(15.0)
                Text("Medium").tag(20.0)
                Text("Large").tag(26.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func sectionMenu(_ section: SectionRow, in presentation: Presentation?) -> some View {
        let others = sections(presentation).filter { $0.id != section.id && $0.chordCount > 0 }
        Menu("Copy Chords From") {
            ForEach(others) { other in
                Button(other.name) { copy(from: other.id, to: section.id) }
            }
        }
        .disabled(others.isEmpty)
        Button("Clear Chords in \(section.name)") { clear(section.id) }
            .disabled(section.chordCount == 0)
    }

    private func copy(from source: String, to target: String) {
        session.commit()
        let from = source.isEmpty ? nil : source
        let to = target.isEmpty ? nil : target
        let slides = Set(model.presentation(self.target.presentationID)?.slides.filter { $0.sectionId == to }.map(\.id) ?? [])
        model.writeChords(presentationID: self.target.presentationID, undoLabel: "Copy Chords") {
            ChordEdits.copyingChords(in: $0, from: from, to: to)
        } touched: { slides.contains($0.slideID) }
    }

    private func clear(_ section: String) {
        session.commit()
        let id = section.isEmpty ? nil : section
        let slides = Set(model.presentation(target.presentationID)?.slides.filter { $0.sectionId == id }.map(\.id) ?? [])
        model.writeChords(presentationID: target.presentationID, undoLabel: "Clear Chords") {
            ChordEdits.clearingChords(in: $0, section: id)
        } touched: { slides.contains($0.slideID) }
    }

    /// The song's sections in the order its slides first use them.
    private func sections(_ presentation: Presentation?) -> [SectionRow] {
        guard let presentation else { return [] }
        let defined = Dictionary(
            (presentation.sections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var chords: [String: Int] = [:]
        var lines: [String: Int] = [:]
        for slide in presentation.slides {
            guard let object = ChordEdits.lyricObject(of: slide) else { continue }
            let id = slide.sectionId ?? ""
            if !order.contains(id) { order.append(id) }
            chords[id, default: 0] += object.chords?.count ?? 0
            lines[id, default: 0] += object.text.components(separatedBy: "\n").count
        }
        return order.map { id in
            let section = defined[id]
            return SectionRow(
                id: id, name: section?.name ?? "No Section",
                color: section?.colorHex.flatMap(ColorHex.color).map {
                    Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
                },
                chordCount: chords[id] ?? 0, lineCount: lines[id] ?? 0)
        }
    }
}
