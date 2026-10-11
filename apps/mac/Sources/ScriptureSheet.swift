import PresenterCore
import SlideScene
import SwiftUI

/// Type a reference, pick a translation, get slides built with the Bible
/// template. Line breaks are removed unless the box is checked, and every
/// slide starts at the beginning of a verse.
struct ScriptureSheet: View {
    let model: AppModel
    let render: RenderContext?
    var initialReference = ""
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = BibleSettings.shared
    @State private var reference = ""
    @State private var passage: BiblePassage?
    @State private var slides: [Slide] = []
    @State private var error: String?
    @State private var loading = false

    private var themeId: String { model.slideBuilding.scriptureThemeId ?? "" }
    private var parsed: BibleReference? { BibleReference.parse(reference) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scripture Slides").font(.headline)
            HStack {
                TextField("Reference — e.g. John 3:16-21, Ps 23, 1 Cor 13:4–7", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await load() } }
                Picker("", selection: $settings.translation) {
                    if settings.translations.isEmpty, let current = settings.translation {
                        Text(current.abbreviation).tag(Optional(current))
                    }
                    ForEach(settings.translations) { Text($0.abbreviation).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Button(loading ? "Loading…" : "Look Up") { Task { await load() } }
                    .disabled(parsed == nil || settings.translation == nil || loading)
            }
            if let parsed {
                Text(parsed.display).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Toggle("Keep line breaks", isOn: $settings.keepsLineBreaks)
                Toggle("Verse numbers", isOn: $settings.showsVerseNumbers)
                Spacer()
                LyricsThemeChooser(appModel: model, render: render, themeId: model.slideBuildingBinding(\.scriptureThemeId))
            }
            .onChange(of: settings.keepsLineBreaks) { _, _ in Task { await rebuild() } }
            .onChange(of: settings.showsVerseNumbers) { _, _ in Task { await rebuild() } }
            .onChange(of: themeId) { _, _ in Task { await rebuild() } }

            preview
                .frame(minHeight: 260)

            if !settings.hasAnyKey {
                Text("Add an API.Bible or ESV key in Settings › Bible to look up passages.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if let copyright = passage?.copyright {
                    Text(copyright).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create \(slides.count) Slides", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(slides.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 620)
        .task {
            reference = initialReference
            if settings.translations.isEmpty { await settings.refreshTranslations() }
            if parsed != nil { await load() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if slides.isEmpty {
            ContentUnavailableView(
                "No Passage Yet", systemImage: "book",
                description: Text("Look up a reference to preview its slides."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Slide \(index + 1) · \(slide.name)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(slide.objects.map(\.text).joined(separator: "\n"))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func load() async {
        guard let parsed, let translation = settings.translation else { return }
        loading = true
        defer { loading = false }
        do {
            passage = try await settings.service.passage(parsed, translation: translation)
            error = nil
            await rebuild()
        } catch {
            self.error = error.localizedDescription
            passage = nil
            slides = []
        }
    }

    private func rebuild() async {
        guard let passage else { return }
        await model.themesFilled([themeId])
        slides = ScriptureSlideBuilder.slides(
            for: passage, format: settings.format, theme: model.theme(themeId))
    }

    private func create() {
        guard let passage else { return }
        var presentation = ScriptureSlideBuilder.presentation(
            for: passage, format: settings.format, theme: model.theme(themeId))
        presentation.slides = slides.map { slide in
            var slide = slide
            slide.notes = passage.copyright
            return slide
        }
        presentation.folder = model.newPlacement.folder(for: .presentation)
        model.createInDrive(presentation)
        dismiss()
        onCreated(presentation.id)
    }
}
