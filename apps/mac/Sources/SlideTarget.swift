import PresenterCore
import SwiftUI

/// Where built slides (scripture, sermon points) go: the presentation open
/// in the editor (after its selected slide), or the presentation selected
/// in the library (at the end) — e.g. the sermon deck edited every week.
struct SlideTarget {
    let presentationID: String
    let name: String
    let themeId: String
    let insert: @MainActor ([Slide]) -> Void

    @MainActor
    static func current(model: AppModel, editor: SlideEditorModel?) -> SlideTarget? {
        if let editor, !editor.isThemeEditor,
           model.libraryEntry(editor.presentation.id)?.kind == .presentation {
            let deck = editor.presentation
            return SlideTarget(
                presentationID: deck.id, name: deck.name, themeId: deck.themeId,
                insert: { editor.insertBuiltSlides($0) })
        }
        guard let id = model.selectedEntryID else { return nil }
        return library(id, model: model)
    }

    @MainActor
    static func library(_ id: String, model: AppModel) -> SlideTarget? {
        guard let entry = model.libraryEntry(id), entry.kind == .presentation else { return nil }
        return SlideTarget(
            presentationID: id, name: entry.name, themeId: model.presentation(id)?.themeId ?? "",
            insert: { slides in
                let after = model.presentation(id)?.slides.last?.id
                model.insertSlides(id, slides: slides, afterSlideID: after)
            })
    }

    /// Slides built with another theme keep that theme, so they stay in
    /// their own design inside this presentation.
    func adopting(_ slides: [Slide], builtWith themeID: String) -> [Slide] {
        guard !themeID.isEmpty, themeID != themeId else { return slides }
        return slides.map { slide in
            var slide = slide
            slide.themeId = themeID
            return slide
        }
    }
}

/// Sermon point slides: one per paragraph, laid out by the theme's
/// "Sermon Points" category.
struct PointSlidesSheet: View {
    let model: AppModel
    let render: RenderContext?
    let target: SlideTarget?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var addToTarget = true
    @State private var addToService = true

    static let themeSlideName = "Sermon Points"

    private var points: [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var themeId: String {
        let chosen = model.slideBuilding.pointsThemeId ?? ""
        return chosen.isEmpty ? (target?.themeId ?? "") : chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Point Slides").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 460, minHeight: 200)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Type or paste the points — a blank line starts the next slide")
                            .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            DestinationPicker(target: target, addToTarget: $addToTarget)
            if !(addToTarget && target != nil) {
                AddToCurrentServiceToggle(model: model, isOn: $addToService)
            }
            HStack {
                LyricsThemeChooser(appModel: model, render: render, themeId: model.slideBuildingBinding(\.pointsThemeId))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(points.count == 1 ? "Add 1 Slide" : "Add \(points.count) Slides", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(points.isEmpty)
            }
            Text("Uses the theme's “Sermon Points” category.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 540)
    }

    private func create() {
        let slides = points.map { point in
            var slide = Slide(
                id: UUID().uuidString, name: String(point.prefix(40)),
                objects: [SlideObject(id: UUID().uuidString, objectKind: .text, name: "Point", text: point)])
            slide.themeSlideName = Self.themeSlideName
            return slide
        }
        if addToTarget, let target {
            target.insert(target.adopting(slides, builtWith: model.slideBuilding.pointsThemeId ?? ""))
            dismiss()
            return
        }
        var presentation = Presentation(
            id: UUID().uuidString, name: "Sermon Points", presentationKind: .deck,
            themeId: themeId, folder: model.newPlacement.folder(for: .presentation), slides: slides)
        presentation.category = PresentationTypes.sermon
        model.createInDrive(presentation)
        AddToCurrentServiceToggle.add(presentation.id, model: model, if: addToService)
        dismiss()
        onCreated(presentation.id)
    }
}

struct DestinationPicker: View {
    let target: SlideTarget?
    @Binding var addToTarget: Bool

    var body: some View {
        if let target {
            Picker("Put slides in", selection: $addToTarget) {
                Text("Add to “\(target.name)”").tag(true)
                Text("A new presentation").tag(false)
            }
            .pickerStyle(.radioGroup)
        }
    }
}
