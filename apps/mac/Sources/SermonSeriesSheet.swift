import AppKit
import PresenterCore
import SwiftUI

/// New Sermon Series. It opens on the drop zone: drop the series art (or a
/// Claude Design download) and the five message designs and four lower
/// thirds are built from it with nothing to choose, then Done. Without art,
/// Claude designs the series from its name instead. One theme per series.
struct SermonSeriesSheet: View {
    let model: AppModel
    /// Art or a download dropped before the sheet opened (on a plan or the
    /// Message & Series sheet); the build starts straight away.
    var dropped: [URL] = []
    /// The new series' theme id, once it's saved.
    var onCreated: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var fromName = false
    @State private var files: [URL] = []
    @State private var name = ""
    @State private var copied = false
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fromName ? "New Sermon Series from the Name" : "New Sermon Series").font(.headline)
            if fromName {
                nameForm
            } else {
                PhotoSeriesPane(model: model, kind: .sermonSeries, name: $name, files: $files,
                                alternatives: AnyView(alternatives),
                                onCancel: { dismiss() }, onCreated: finish)
            }
        }
        .padding(16)
        .frame(width: fromName ? 540 : 780)
        .dropDestination(for: URL.self) { urls, _ in
            guard PhotoSeries.accepts(urls) else { return false }
            fromName = false
            files = urls
            return true
        }
        .onAppear {
            if !dropped.isEmpty { files = dropped }
        }
    }

    /// Other ways in, kept out of the way of the drop.
    private var alternatives: some View {
        HStack(spacing: 14) {
            Button("No Art Yet? Design from the Name…") { fromName = true }
                .buttonStyle(.link)
            Button(copied ? "Prompt Copied" : "Copy Claude Design Prompt") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    SeriesExport.exportPrompt(series: name.isEmpty ? "New Series" : name), forType: .string)
                copied = true
            }
            .buttonStyle(.link)
            .help("Paste into Claude Design after the artwork is made; drop the ZIP it gives you here.")
        }
        .font(.callout)
    }

    @ViewBuilder
    private var nameForm: some View {
        Form {
            TextField("Series name", text: $name)
        }
        .formStyle(.grouped)
        Text("Claude designs the background, lower-third bar, fonts and colors from the series name. Takes about a minute.")
            .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
        HStack {
            Button("Use Art Instead") { fromName = false }
            Spacer()
            Button("Cancel") { dismiss() }
            Button(creating ? "Designing…" : "Create Series Theme") { Task { await create() } }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
        }
    }

    /// Makes the new series current for slide building and tells whoever
    /// opened the sheet (a plan applies it to its message).
    private func finish(_ themeID: String) {
        model.updateSlideBuilding { $0.sermonThemeId = themeID }
        onCreated(themeID)
        dismiss()
    }

    private func create() async {
        creating = true
        defer { creating = false }
        error = nil
        do {
            finish(try await SeriesGenerator.generate(series: name.trimmingCharacters(in: .whitespaces), hint: "", model: model))
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func postScript(_ family: String, bold: Bool) -> String {
        guard var font = NSFont(name: family, size: 72) ?? NSFontManager.shared.font(
            withFamily: family, traits: [], weight: 5, size: 72) else { return family }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return font.fontName
    }
}

/// Art dropped somewhere that opens a sheet to build from it.
struct SeriesArtDrop: Identifiable {
    let id = UUID()
    var files: [URL]
}

/// Library › Themes › New Theme from Image…: the same one-step build as a
/// sermon series, made into a general theme (Lyrics, Title, Announcements,
/// Bible and Sermon Points, with lower thirds) for anything outside the
/// message.
struct ThemeFromImageSheet: View {
    let model: AppModel
    /// An image or download dropped on the Themes library.
    var dropped: [URL] = []
    var onCreated: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Theme from Image").font(.headline)
            PhotoSeriesPane(model: model, kind: .general, name: $name, files: $files, alternatives: nil,
                            onCancel: { dismiss() },
                            onCreated: { id in
                                onCreated(id)
                                dismiss()
                            })
        }
        .padding(16)
        .frame(width: 780)
        .onAppear {
            if !dropped.isEmpty { files = dropped }
        }
    }
}

/// A font family, then one of its faces (Black, Book, Book Italic…), as the
/// face's PostScript name.
struct FontFacePicker: View {
    let title: String
    let families: [String]
    @Binding var postScript: String

    private var family: String { NSFont(name: postScript, size: 12)?.familyName ?? "" }

    private func faces(_ family: String) -> [(name: String, style: String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard let name = member.first as? String, let style = member.dropFirst().first as? String else { return nil }
            return (name, style)
        }
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Picker("", selection: Binding(
                    get: { family },
                    set: { picked in
                        let options = faces(picked)
                        postScript = options.first { $0.style == "Regular" }?.name ?? options.first?.name ?? postScript
                    }
                )) {
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Picker("", selection: $postScript) {
                    ForEach(faces(family), id: \.name) { Text($0.style).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }
}

/// Settings › Bible › Sermon import.
struct SermonImportSettingsForm: View {
    let model: AppModel
    @State private var creatingSeries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaudeKeyField()
            Text("From console.anthropic.com › API Keys. Reading a week's notes costs a few cents.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Current series theme", selection: model.slideBuildingBinding(\.sermonThemeId)) {
                Text("Choose…").tag("")
                ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
            }
            Button("New Sermon Series…") { creatingSeries = true }
        }
        .sheet(isPresented: $creatingSeries) { SermonSeriesSheet(model: model) }
    }
}
