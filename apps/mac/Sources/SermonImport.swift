import AppKit
import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

/// Import Sermon: drop the week's notes (PDF or Pages), Claude lists the
/// slides, you check them, and they're built with the series theme into the
/// presentation you choose.
struct SermonImportSheet: View {
    let model: AppModel
    var target: SlideTarget?
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fileName = ""
    @State private var outline: SermonOutline?
    @State private var reading = false
    @State private var building = false
    @State private var error: String?
    /// "" is a new presentation; otherwise the presentation's id.
    @State private var destination = ""
    @State private var replaces = true
    @State private var addToService = true
    @State private var dropping = false
    /// The series theme being designed after the notes are read.
    @State private var designing: String?

    private var seriesThemeID: String { model.slideBuilding.sermonThemeId ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Sermon").font(.headline)
            if outline == nil {
                dropZone
            } else {
                slideList
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let designing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Designing the \(designing) theme…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                Picker("Series theme", selection: model.slideBuildingBinding(\.sermonThemeId)) {
                    Text("Choose…").tag("")
                    ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Put slides in", selection: $destination) {
                    Text("A new presentation").tag("")
                    Divider()
                    ForEach(model.entries(of: .presentation), id: \.id) { Text($0.name).tag($0.id) }
                }
                if !destination.isEmpty {
                    Toggle("Replace that presentation's slides", isOn: $replaces)
                } else {
                    AddToCurrentServiceToggle(model: model, isOn: $addToService)
                }
            }
            .formStyle(.grouped)
            .frame(height: destination.isEmpty && model.currentServiceID == nil ? 120 : 150)
            HStack {
                if outline != nil {
                    Button("Start Over") { outline = nil; fileName = "" }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(building ? "Building…" : "Build Slides") { Task { await build() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(outline?.slides.isEmpty != false || seriesThemeID.isEmpty || building || designing != nil)
            }
        }
        .padding(16)
        .frame(width: 640, height: 640)
        .onAppear { destination = target?.presentationID ?? "" }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(reading ? "Claude is reading \(fileName)…" : "Drop the sermon notes here (PDF or Pages)")
                .foregroundStyle(.secondary)
            if reading { ProgressView().controlSize(.small) } else {
                Button("Choose File…", action: choose)
            }
            if ClaudeClient.apiKey.isEmpty {
                Text("Add your Anthropic API key in Settings › Bible › Sermon import first.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(dropping ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await read(url) }
            return true
        } isTargeted: { dropping = $0 }
    }

    private var slideList: some View {
        List {
            Section(outline?.title ?? "Slides") {
                ForEach(Binding(get: { outline?.slides ?? [] }, set: { outline?.slides = $0 })) { $item in
                    HStack(alignment: .top) {
                        Picker("", selection: $item.kind) {
                            ForEach(SermonOutline.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        VStack(alignment: .leading, spacing: 4) {
                            if item.kind != .scripture {
                                TextField("Point", text: $item.text, axis: .vertical)
                            }
                            if item.kind != .point {
                                TextField("Reference, e.g. Romans 8:28", text: $item.reference)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            outline?.slides.removeAll { $0.id == item.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { from, to in outline?.slides.move(fromOffsets: from, toOffset: to) }
                Button("Add Slide") { outline?.slides.append(.init(kind: .point, text: "")) }
            }
        }
        .frame(minHeight: 300)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf] + ["pages"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await read(url) }
        }
    }

    private func read(_ url: URL) async {
        fileName = url.lastPathComponent
        reading = true
        defer { reading = false }
        do {
            let pdf = try await SermonFiles.pdfData(for: url)
            let read = try await ClaudeClient.outline(fromPDF: pdf, fileName: url.lastPathComponent)
            outline = read
            error = nil
            reading = false
            await useSeriesTheme(for: read)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Each series gets its own theme: reuse the one already made for the
    /// series the notes name, or have Claude design it now.
    private func useSeriesTheme(for outline: SermonOutline) async {
        let series = outline.series.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !series.isEmpty else { return }
        if let id = SeriesGenerator.existingTheme(for: series, model: model) {
            model.updateSlideBuilding { $0.sermonThemeId = id }
            return
        }
        designing = series
        defer { designing = nil }
        do {
            let id = try await SeriesGenerator.generate(series: series, hint: outline.title, model: model)
            model.updateSlideBuilding { $0.sermonThemeId = id }
        } catch {
            self.error = "Couldn't design the \(series) theme: \(error.localizedDescription) Pick a theme below instead."
        }
    }

    private func build() async {
        guard let outline, !seriesThemeID.isEmpty else { return }
        building = true
        defer { building = false }
        await model.themesFilled([seriesThemeID])
        let theme = model.theme(seriesThemeID)
        let slides = await SermonSlides.build(outline, theme: theme)
        guard !slides.isEmpty else { error = "No slides to build."; return }

        if destination.isEmpty {
            var presentation = Presentation(
                id: UUID().uuidString, name: outline.title.isEmpty ? "Message" : outline.title,
                presentationKind: .deck, themeId: seriesThemeID,
                folder: model.newPlacement.folder(for: .presentation), slides: slides)
            presentation.category = PresentationTypes.sermon
            model.createInDrive(presentation)
            AddToCurrentServiceToggle.add(presentation.id, model: model, if: addToService)
            dismiss()
            onCreated(presentation.id)
            return
        }
        let id = destination
        let deckTheme = (try? await model.client.loadValue(Presentation.self, id: id))?.themeId ?? ""
        let placed = slides.map { slide -> Slide in
            var slide = slide
            if deckTheme != seriesThemeID { slide.themeId = seriesThemeID }
            return slide
        }
        if replaces {
            model.updatePresentation(id) { $0.slides = placed }
        } else {
            let last = (try? await model.client.loadValue(Presentation.self, id: id))?.slides.last?.id
            model.insertSlides(id, slides: placed, afterSlideID: last)
        }
        dismiss()
        onCreated(id)
    }
}

/// Turns Claude's outline into slides laid out by the series theme.
enum SermonSlides {
    @MainActor
    static func build(_ outline: SermonOutline, theme: Theme?) async -> [Slide] {
        let settings = BibleSettings.shared
        if settings.translation == nil { await settings.refreshTranslations() }
        var slides: [Slide] = []
        for item in outline.slides {
            switch item.kind {
            case .point:
                slides.append(slide(SermonSeriesTheme.pointCategory, name: item.text, [("Point", item.text)]))
            case .scripture:
                let reference = item.reference.isEmpty ? item.text : item.reference
                if let passage = await passage(reference) {
                    slides += ScriptureSlideBuilder.slides(
                        for: passage, format: settings.format, theme: theme,
                        themeSlideName: SermonSeriesTheme.scriptureCategory)
                } else {
                    slides.append(slide(SermonSeriesTheme.scriptureCategory, name: reference,
                                        [("Verse", ""), ("Reference", reference)]))
                }
            case .pointScripture:
                let found = await passage(item.reference)
                let verse = found.map { passage in
                    passage.verses.map { ScriptureText.clean($0.text, keepsLineBreaks: false) }.joined(separator: " ")
                } ?? ""
                let label = found.map { "\($0.reference.display) \($0.translation.abbreviation)" } ?? item.reference
                slides.append(slide(SermonSeriesTheme.pointScriptureCategory, name: item.text,
                                    [("Point", item.text), ("Verse", verse), ("Reference", label)]))
            }
        }
        return slides
    }

    private static func slide(_ category: String, name: String, _ parts: [(String, String)]) -> Slide {
        var slide = Slide(
            id: UUID().uuidString, name: String(name.prefix(40)),
            objects: parts.map { SlideObject(id: UUID().uuidString, objectKind: .text, name: $0.0, text: $0.1) })
        slide.themeSlideName = category
        return slide
    }

    @MainActor
    private static func passage(_ reference: String) async -> BiblePassage? {
        let settings = BibleSettings.shared
        guard let translation = settings.translation, let parsed = BibleReference.parse(reference) else { return nil }
        return try? await settings.service.passage(parsed, translation: translation)
    }
}

/// PDFs go to Claude as they are; Pages documents are exported to PDF by
/// Pages first.
enum SermonFiles {
    static func pdfData(for url: URL) async throws -> Data {
        if url.pathExtension.lowercased() != "pages" { return try Data(contentsOf: url) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).pdf")
        let script = """
        tell application "Pages"
            set theDoc to open POSIX file "\(url.path.replacingOccurrences(of: "\"", with: "\\\""))"
            export theDoc to POSIX file "\(output.path.replacingOccurrences(of: "\"", with: "\\\""))" as PDF
            close theDoc saving no
        end tell
        """
        let failure: String? = await Task.detached {
            var info: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&info)
            return info.map { "\($0[NSAppleScript.errorMessage] ?? $0)" }
        }.value
        guard failure == nil, let data = try? Data(contentsOf: output) else {
            throw NSError(domain: "Screens", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Couldn't open the Pages file — Pages must be installed, and Screens needs permission to control it. \(failure ?? "")"])
        }
        try? FileManager.default.removeItem(at: output)
        return data
    }
}
