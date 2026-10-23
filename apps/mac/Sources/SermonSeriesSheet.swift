import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// New Sermon Series: built from the series art (a photo of it), designed
/// by Claude from the series name, or imported from Claude Design. Each
/// becomes a theme with the five message designs and a matching lower third
/// for each but Title, already tied for the livestream. One theme per series.
struct SermonSeriesSheet: View {
    let model: AppModel
    /// Art dropped before the sheet opened (on the plan's series picker).
    var photo: URL?
    /// The new series' theme id, once it's saved.
    var onCreated: (String) -> Void = { _ in }

    enum Source: String, CaseIterable, Identifiable {
        case photo = "From a Photo"
        case name = "From the Name"
        case claudeDesign = "Claude Design"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.photo
    @State private var droppedPhoto: URL?
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
    @State private var error: String?
    @State private var importNote: String?

    private let families = NSFontManager.shared.availableFontFamilies

    private var ownArtwork: Bool { source == .claudeDesign }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Sermon Series").font(.headline)
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if source == .photo {
                PhotoSeriesPane(model: model, name: $name, photo: $droppedPhoto,
                                onCancel: { dismiss() }, onCreated: finish)
            } else {
                designForm
            }
        }
        .padding(16)
        .frame(width: source == .photo ? 780 : 540)
        .dropDestination(for: URL.self) { urls, _ in
            // A single picture is series art unless the Claude Design
            // import is open; a ZIP, folder or set of files is a download.
            if source != .claudeDesign, urls.count == 1, let url = urls.first, SeriesArt.accepts(url) {
                source = .photo
                droppedPhoto = url
            } else {
                load(urls)
            }
            return true
        }
        .onAppear {
            if let photo { droppedPhoto = photo }
        }
    }

    @ViewBuilder
    private var designForm: some View {
        Form {
            TextField("Series name", text: $name)
            if ownArtwork {
                HStack {
                    Button(copied ? "Copied" : "Copy Claude Design Prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            SeriesExport.exportPrompt(series: name.isEmpty ? "New Series" : name), forType: .string)
                        copied = true
                    }
                    Button("Import Claude Design Download…", action: chooseDownload)
                    Spacer()
                }
                if let importNote {
                    Text(importNote).font(.caption).foregroundStyle(.secondary)
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
             ? "Paste the prompt into Claude Design, download the ZIP it makes, and import or drop it here. Everything below fills in."
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

    /// Makes the new series current for slide building and tells whoever
    /// opened the sheet.
    private func finish(_ themeID: String) {
        model.updateSlideBuilding { $0.sermonThemeId = themeID }
        onCreated(themeID)
        dismiss()
    }

    private func chooseDownload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder, .png, .jpeg, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in load(urls) }
        }
    }

    /// Fills the form from a Claude Design download.
    private func load(_ urls: [URL]) {
        do {
            let found = try ClaudeDesignImport.read(urls)
            source = .claudeDesign
            error = nil
            if let series = found.series, name.trimmingCharacters(in: .whitespaces).isEmpty { name = series }
            if let url = found.background { background = url }
            if let url = found.lowerThird { lowerThird = url }
            if let font = found.headingFont { headingFont = font }
            if let font = found.bodyFont { bodyFont = font }
            if let font = found.scriptureFont { verseFont = font }
            if let caps = found.headingCaps { headingCaps = caps }
            if let hex = found.textColor { textColor = Self.color(hex) }
            if let hex = found.accentColor { accentColor = Self.color(hex) }
            if let hex = found.lowerThirdTextColor { barTextColor = Self.color(hex) }
            if let hex = found.lowerThirdAccentColor { barAccentColor = Self.color(hex) }
            var notes = ["Imported. Check the fields, then Create Series Theme."]
            if !found.missingFonts.isEmpty {
                notes.append("Not installed, using the fallback: \(found.missingFonts.joined(separator: ", ")).")
            }
            if found.background == nil { notes.append("No background found.") }
            if found.lowerThird == nil { notes.append("No transparent lower third found.") }
            importNote = notes.joined(separator: " ")
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func color(_ hex: String) -> Color {
        let digits = Array(hex.replacingOccurrences(of: "#", with: ""))
        func channel(_ at: Int) -> Double {
            guard digits.count >= at + 2, let value = Int(String(digits[at..<at + 2]), radix: 16) else { return 1 }
            return Double(value) / 255
        }
        return Color(.sRGB, red: channel(0), green: channel(2), blue: channel(4))
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
                finish(try await SeriesGenerator.generate(series: seriesName, hint: "", model: model))
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
        finish(theme.id)
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
