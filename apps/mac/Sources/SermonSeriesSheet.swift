import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// New Sermon Series: Claude designs the artwork from the series name (or
/// staff pick their own images) and it becomes a theme with Point, Scripture
/// and Point + Scripture designs and a matching lower third for each,
/// already tied for the livestream. One theme per series.
struct SermonSeriesSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var background: URL?
    @State private var lowerThird: URL?
    // PostScript names of the exact faces (e.g. Gotham-Black).
    @State private var headingFont = "HelveticaNeue-Bold"
    @State private var bodyFont = "HelveticaNeue"
    @State private var verseFont = "HelveticaNeue-Italic"
    @State private var headingCaps = false
    @State private var textColor = Color.white
    @State private var accentColor = Color(red: 1, green: 0.7, blue: 0.12)
    @State private var barTextColor = Color.white
    @State private var barAccentColor = Color(red: 1, green: 0.7, blue: 0.12)
    @State private var copied = false
    @State private var creating = false
    @State private var ownArtwork = false
    @State private var error: String?

    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Sermon Series").font(.headline)
            Form {
                TextField("Series name", text: $name)
                Toggle("Use my own artwork", isOn: $ownArtwork)
                if ownArtwork {
                    HStack {
                        Button(copied ? "Copied" : "Copy Claude Design Prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                SermonSeriesTheme.claudeDesignPrompt(series: name.isEmpty ? "New Series" : name), forType: .string)
                            copied = true
                        }
                        Spacer()
                    }
                    imageRow("Background (1920×1080)", $background, types: [.jpeg, .png, .heic])
                    imageRow("Lower third (transparent PNG)", $lowerThird, types: [.png])
                    FontFacePicker(title: "Heading font", families: families, postScript: $headingFont)
                    Toggle("Headings in all caps", isOn: $headingCaps)
                    FontFacePicker(title: "Body font", families: families, postScript: $bodyFont)
                    FontFacePicker(title: "Scripture font", families: families, postScript: $verseFont)
                    ColorPicker("Text on background", selection: $textColor, supportsOpacity: false)
                    ColorPicker("Accent on background", selection: $accentColor, supportsOpacity: false)
                    ColorPicker("Text on lower third", selection: $barTextColor, supportsOpacity: false)
                    ColorPicker("Accent on lower third", selection: $barAccentColor, supportsOpacity: false)
                }
            }
            .formStyle(.grouped)
            Text(ownArtwork
                 ? "Makes Point, Scripture and Point + Scripture slides from your images, each with a matching lower third."
                 : "Claude designs the background, lower-third bar, fonts and colors from the series name. Takes about a minute.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(creating ? (ownArtwork ? "Creating…" : "Designing…") : "Create Series Theme") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .padding(16)
        .frame(width: 540)
    }

    private func imageRow(_ title: String, _ url: Binding<URL?>, types: [UTType]) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.wrappedValue?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = types
                    panel.begin { response in
                        if response == .OK, let picked = panel.url { url.wrappedValue = picked }
                    }
                }
            }
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        error = nil
        let seriesName = name.trimmingCharacters(in: .whitespaces)
        if !ownArtwork {
            do {
                let id = try await SeriesGenerator.generate(series: seriesName, hint: "", model: model)
                model.updateSlideBuilding { $0.sermonThemeId = id }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        var mediaIDs: [URL: String] = [:]
        for url in [background, lowerThird].compactMap({ $0 }) {
            if let id = await model.importFiles([url]).first { mediaIDs[url] = id }
        }
        let style = SermonSeriesStyle(
            name: seriesName,
            backgroundMediaID: background.flatMap { mediaIDs[$0] },
            lowerThirdMediaID: lowerThird.flatMap { mediaIDs[$0] },
            font: bodyFont, boldFont: headingFont,
            textColor: Self.hex(textColor), accentColor: Self.hex(accentColor),
            verseFont: verseFont,
            lowerThirdTextColor: Self.hex(barTextColor), lowerThirdAccentColor: Self.hex(barAccentColor),
            headingCaps: headingCaps)
        let theme = SermonSeriesTheme.make(style)
        model.createInDrive(theme)
        model.updateSlideBuilding { $0.sermonThemeId = theme.id }
        dismiss()
    }

    static func postScript(_ family: String, bold: Bool) -> String {
        guard var font = NSFont(name: family, size: 72) ?? NSFontManager.shared.font(
            withFamily: family, traits: [], weight: 5, size: 72) else { return family }
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return font.fontName
    }

    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02XFF",
                      Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
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
    @State private var key = ClaudeClient.apiKey
    @State private var creatingSeries = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Anthropic API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { _, value in ClaudeClient.apiKey = value }
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
