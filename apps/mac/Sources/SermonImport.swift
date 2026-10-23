import AppKit
import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

/// Import Sermon: pick the series, drop the week's notes (PDF or Pages),
/// Claude lists the slides, you check them, and they're built with the
/// series' designs. Opened for a plan, the result becomes that plan's
/// message; otherwise it goes into the presentation you choose.
struct SermonImportSheet: View {
    let model: AppModel
    var target: SlideTarget?
    /// The plan the message is for; nil when imported from the library.
    var planID: String?
    let onCreated: (String) -> Void

    init(model: AppModel, target: SlideTarget? = nil, planID: String? = nil,
         onCreated: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.target = target
        self.planID = planID
        self.onCreated = onCreated
    }

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
    /// The series the slides are built with.
    @State private var seriesID = ""
    /// Set once someone picks a series (or the plan already has one), so
    /// the series named in the notes never overrides it.
    @State private var seriesPicked = false
    /// The series theme being designed from the notes.
    @State private var designing: String?
    @State private var seriesLoaded = false

    /// The picker's choice that designs a new series from the notes.
    private static let newSeries = "new-series-from-notes"

    private var plan: Service? { planID.flatMap { model.resident.services.value($0) } }

    /// Only series themes: the message designs live there.
    private var seriesEntries: [LibraryIndex.Entry] {
        model.entries(of: .theme).filter { entry in
            model.theme(entry.id).map(SermonSeriesTheme.isSeries) == true
        }
    }

    /// The series the notes name, when nothing in the library is called that.
    private var unknownSeries: String? {
        guard let name = outline?.series.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              matchingSeries(name) == nil else { return nil }
        return name
    }

    private var canBuild: Bool {
        outline?.slides.isEmpty == false && !seriesID.isEmpty && seriesID != Self.newSeries
            && !building && designing == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.map { "Import Message Notes for \($0.name)" } ?? "Import Message Notes").font(.headline)
            seriesRow
            if outline == nil {
                dropZone
            } else {
                slideList
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let designing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Designing the \(designing) series…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let plan {
                Text(planMessageID(in: plan) == nil
                     ? "The message goes at the end of \(plan.name)."
                     : "The message replaces the one in \(plan.name).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Form {
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
                .frame(height: destination.isEmpty && model.currentServiceID == nil ? 80 : 110)
            }
            HStack {
                if outline != nil {
                    Button("Start Over") { outline = nil; fileName = "" }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(building ? "Building…" : "Build Slides") { Task { await build() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBuild)
            }
        }
        .padding(16)
        .frame(width: 640, height: 660)
        .onAppear { destination = target?.presentationID ?? "" }
        .task { await loadSeries() }
    }

    private var seriesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Series", selection: Binding(get: { seriesID }, set: pickSeries)) {
                Text(seriesLoaded ? "Choose…" : "Loading…").tag("")
                ForEach(seriesEntries, id: \.id) { Text($0.name).tag($0.id) }
                if outline != nil {
                    Divider()
                    Text("New Series from These Notes").tag(Self.newSeries)
                }
            }
            .disabled(designing != nil)
            if seriesID.isEmpty, let unknownSeries {
                Text("The notes name the series “\(unknownSeries)”, which isn't in the library. Choose New Series from These Notes to design it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(reading ? "Claude is reading \(fileName)…" : "Drop the message notes here (PDF or Pages)")
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
                            ForEach(SermonOutline.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        VStack(alignment: .leading, spacing: 4) {
                            switch item.kind {
                            case .title:
                                TextField("Message title", text: $item.text, axis: .vertical)
                                TextField("Series or speaker", text: $item.reference)
                                    .foregroundStyle(.secondary)
                            case .point:
                                TextField("Point", text: $item.text, axis: .vertical)
                            case .scripture:
                                TextField("Reference, e.g. Romans 8:28", text: $item.reference)
                                    .foregroundStyle(.secondary)
                            case .pointScripture:
                                TextField("Point", text: $item.text, axis: .vertical)
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

    /// Fills the series list, then starts on the plan's series, else the
    /// last one used.
    private func loadSeries() async {
        await model.themesFilled(model.entries(of: .theme).map(\.id))
        seriesLoaded = true
        guard seriesID.isEmpty else { return }
        let isSeries = { (id: String) in model.theme(id).map(SermonSeriesTheme.isSeries) == true }
        if let id = plan?.sermonThemeId, isSeries(id) {
            seriesID = id
            seriesPicked = true
        } else if let id = model.slideBuilding.sermonThemeId, isSeries(id) {
            seriesID = id
        }
    }

    private func pickSeries(_ id: String) {
        seriesPicked = true
        seriesID = id
        if id == Self.newSeries, let outline { Task { await designSeries(for: outline) } }
    }

    private func matchingSeries(_ name: String) -> String? {
        let wanted = SeriesGenerator.normalized(name)
        guard !wanted.isEmpty else { return nil }
        return seriesEntries.first { SeriesGenerator.normalized($0.name) == wanted }?.id
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
            // The notes' series only fills in a choice nobody has made.
            if !seriesPicked, let id = matchingSeries(read.series) { seriesID = id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Has Claude design a series from the notes' series name (or the
    /// message title when they name none), then picks it.
    private func designSeries(for outline: SermonOutline) async {
        let named = outline.series.trimmingCharacters(in: .whitespacesAndNewlines)
        let series = named.isEmpty ? outline.title.trimmingCharacters(in: .whitespacesAndNewlines) : named
        guard !series.isEmpty else {
            error = "The notes don't name a series. Make one with New Series… in the plan's Message & Series."
            seriesID = ""
            return
        }
        designing = series
        defer { designing = nil }
        do {
            seriesID = try await SeriesGenerator.generate(series: series, hint: outline.title, model: model)
            error = nil
        } catch {
            seriesID = ""
            self.error = "Couldn't design the \(series) series: \(error.localizedDescription)"
        }
    }

    private func planMessageID(in plan: Service) -> String? {
        PlanMessage.itemIndex(in: plan) { id in
            model.presentation(id).map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true
        }.map { plan.items[$0].refId }
    }

    private func build() async {
        guard let outline, canBuild else { return }
        let seriesID = seriesID
        building = true
        defer { building = false }
        await model.themesFilled([seriesID])
        var theme = model.theme(seriesID)
        // A series that missed the launch upgrade (restored or synced in
        // later) gets its Title and Worship designs now.
        if let current = theme, let upgraded = SermonSeriesTheme.upgraded(current) {
            let designs = upgraded.slides
            let routes = upgraded.streamDesigns
            model.updateTheme(seriesID) { stored in
                stored.slides = designs
                stored.streamDesigns = routes
                stored.isSermonSeries = true
            }
            theme = upgraded
        }
        // The next import starts on this series.
        model.updateSlideBuilding { $0.sermonThemeId = seriesID }
        let slides = await SermonSlides.build(outline, theme: theme)
        guard !slides.isEmpty else { error = "No slides to build."; return }

        if let planID {
            await placeInPlan(planID, slides: slides, title: outline.title, seriesID: seriesID)
            return
        }
        if destination.isEmpty {
            var presentation = newMessage(slides: slides, title: outline.title, seriesID: seriesID)
            presentation.folder = model.newPlacement.folder(for: .presentation)
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
            if deckTheme != seriesID { slide.themeId = seriesID }
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

    private func newMessage(slides: [Slide], title: String, seriesID: String) -> Presentation {
        var presentation = Presentation(
            id: UUID().uuidString, name: title.isEmpty ? "Message" : title,
            presentationKind: .deck, themeId: seriesID, slides: slides)
        presentation.category = PresentationTypes.sermon
        return presentation
    }

    /// The new message takes the place of the plan's old one (keeping its
    /// sermon timer), and the plan follows the series.
    private func placeInPlan(_ planID: String, slides: [Slide], title: String, seriesID: String) async {
        let items = plan?.items.filter { $0.itemKind == .presentation }.map(\.refId) ?? []
        let loaded = await model.presentationsFilled(items)
        let oldID = plan.flatMap { plan in
            PlanMessage.itemIndex(in: plan) { id in
                loaded[id].map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true
            }.map { plan.items[$0].refId }
        }
        var presentation = newMessage(slides: slides, title: title, seriesID: seriesID)
        presentation.sermonTimerSeconds = oldID.flatMap { loaded[$0]?.sermonTimerSeconds }
        model.createInDrive(presentation)
        let id = presentation.id
        model.updateService(planID) { plan in
            PlanMessage.place(id, name: "Message", series: seriesID, in: &plan) { $0 == oldID }
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
            case .title:
                slides.append(slide(SermonSeriesTheme.titleCategory, name: item.text,
                                    [("Title", item.text), ("Subtitle", item.reference)]))
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
