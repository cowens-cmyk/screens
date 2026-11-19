import PresenterCore
import SwiftUI

/// Chords for one slide, from a slide's right-click › Edit Chords…: click
/// any letter to put a chord over it, or pick a chord in the palette and
/// click the words it goes on. Steps to the slides before and after it;
/// Chords Window opens the whole song (ChordsWindowView). Chords are saved
/// with the song and kept through updates from Shepherd (ChordEdits).
struct ChordEditorSheet: View {
    let model: AppModel
    let presentationID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @HotDefault("chords.showChordPro") private var showChordPro = false

    @State private var session: ChordSession

    /// `slideID` nil shows the whole song.
    init(model: AppModel, presentationID: String, slideID: String? = nil) {
        self.model = model
        self.presentationID = presentationID
        _session = State(initialValue: ChordSession(
            model: model, presentationID: presentationID, scope: slideID.map { .slide($0) } ?? .all))
    }

    var body: some View {
        let _ = model.listVersion
        VStack(spacing: 0) {
            header
            Divider()
            ChordPaletteBar(session: session)
            Divider()
            if model.presentation(presentationID) == nil {
                ContentUnavailableView("Presentation not found", systemImage: "questionmark.square.dashed")
                    .frame(maxHeight: .infinity)
            } else {
                ChordRowsList(session: session, size: 18, showChordPro: showChordPro)
            }
            Divider()
            ChordHelpLine().padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: showChordPro ? 980 : 720, minHeight: isOneSlide ? 320 : 560)
        .onExitCommand {
            if session.editing != nil {
                session.cancel()
            } else if session.armed != nil {
                session.armed = nil
            } else {
                dismiss()
            }
        }
    }

    private var isOneSlide: Bool {
        if case .slide = session.scope { return true }
        return false
    }

    /// The slides with lines, in order, for stepping one slide at a time.
    private var slidesWithLines: [String] {
        guard let presentation = model.presentation(presentationID) else { return [] }
        var seen = Set<String>()
        return ChordSession.rows(of: presentation).map(\.slideID).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private var slideStepper: some View {
        if case .slide(let slideID) = session.scope {
            let order = slidesWithLines
            let index = order.firstIndex(of: slideID)
            HStack(spacing: 4) {
                Button {
                    session.commit()
                    if let index, index > 0 { session.scope = .slide(order[index - 1]) }
                } label: { Image(systemName: "chevron.left") }
                .disabled((index ?? 0) == 0)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous slide (\u{2318}\u{2190})")
                Button {
                    session.commit()
                    if let index, index + 1 < order.count { session.scope = .slide(order[index + 1]) }
                } label: { Image(systemName: "chevron.right") }
                .disabled(index.map { $0 + 1 >= order.count } ?? true)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next slide (\u{2318}\u{2192})")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.presentation(presentationID)?.name ?? "Chords")
                .font(.headline)
            ChordKeyPicker(model: model, presentationID: presentationID)
            Spacer()
            slideStepper
            Toggle("ChordPro", isOn: $showChordPro)
                .toggleStyle(.button)
                .help("Type each line as ChordPro beside it: [G]Amazing [C]grace")
            Button("Chords Window") {
                session.commit()
                openWindow(
                    id: "chords", value: ChordsWindowTarget(presentationID: presentationID, sectionID: currentSection))
                dismiss()
            }
            .help("Every slide of the song in a window of its own, by section")
            // ⌘Return, not Return: Return writes the chord being typed.
            Button("Done") {
                session.commit()
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    /// The section of the slide shown, for the window to open at.
    private var currentSection: String? {
        guard case .slide(let slideID) = session.scope,
              let slide = model.presentation(presentationID)?.slides.first(where: { $0.id == slideID })
        else { return nil }
        return slide.sectionId ?? ""
    }
}
