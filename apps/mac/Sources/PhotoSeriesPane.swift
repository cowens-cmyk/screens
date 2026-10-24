import AppKit
import ImageIO
import PresenterCore
import SwiftUI

/// Designs from art in one step: drop a picture or a Claude Design download
/// and Claude reads it, picks the type, colors, backgrounds and bar, and
/// every design appears ready to use. Nothing needs choosing before Done;
/// Edit Colors & Fonts… is there for changing a pick, Try Again for
/// another read.
struct PhotoSeriesPane: View {
    let model: AppModel
    let kind: PhotoSeriesTheme.Kind
    @Binding var name: String
    /// What to build from: one picture, or a download's files. Set by a
    /// drop here or anywhere on the sheet, or before the sheet opened.
    @Binding var files: [URL]
    /// Other ways to start, shown under the drop zone.
    var alternatives: AnyView?
    /// Art dropped somewhere it might not have been meant for (a plan's
    /// list): it's shown with Build Designs, and nothing is read until
    /// that's pressed.
    var confirmFirst = false
    let onCancel: () -> Void
    let onCreated: (String) -> Void

    private enum Phase: Equatable {
        case empty
        case confirm
        case working(String)
        case ready
        case failed(String)
    }

    private struct Run: Equatable {
        var files: [URL] = []
        var generation = 0
    }

    @State private var phase = Phase.empty
    @State private var run = Run()
    @State private var draft: PhotoSeriesDraft?
    @State private var preview: Theme?
    @State private var overrides = PhotoSeriesOverrides()
    @State private var editing = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var dropTargeted = false
    /// The name last filled in from the art, so a new read replaces it but
    /// never a name someone typed.
    @State private var filledName = ""
    /// Build Designs pressed for art that needed confirming.
    @State private var confirmed = false
    /// The art shown for confirming, from a small thumbnail.
    @State private var thumbnail: CGImage?
    /// Whether this build asks Claude, read from the Keychain once as the
    /// build starts rather than each time the view draws.
    @State private var askingClaude = false
    /// Media this draft's save imported, kept for another try.
    @State private var imported = PhotoSeries.ImportedMedia()

    private let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .empty: dropZone(error: nil)
            case .confirm: confirmation
            case .failed(let message): dropZone(error: message)
            case .working(let stage): working(stage)
            case .ready: ready
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                if phase == .ready {
                    Button(editing ? "Hide Colors & Fonts" : "Edit Colors & Fonts…") { editing.toggle() }
                    if draft?.canTryAgain == true {
                        Button("Try Again") { run.generation += 1 }
                            .help(draft?.readByClaude == true ? "Ask Claude for another take on the art" : "Try another accent from the art")
                    }
                }
                Spacer()
                // A save can't be stopped part way, so Cancel waits for it.
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).disabled(saving)
                if phase == .confirm {
                    Button("Build Designs") {
                        confirmed = true
                        run.generation += 1
                    }
                    .keyboardShortcut(.defaultAction)
                }
                if phase == .ready {
                    Button(saving ? "Saving…" : "Done") { Task { await done() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .dropDestination(for: URL.self) { urls, _ in
            guard !saving, PhotoSeries.accepts(urls) else { return false }
            open(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear {
            run.files = files
            SeriesFonts.prepare()
        }
        .onChange(of: files) { _, files in
            // Picks made for other art don't carry over.
            overrides = PhotoSeriesOverrides()
            editing = false
            run = Run(files: files, generation: 0)
        }
        .task(id: run) { await read() }
        .onChange(of: overrides) { _, _ in rebuildPreview() }
    }

    // MARK: Phases

    private func dropZone(error: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(kind == .general ? "Drop an image here" : "Drop the series art here").font(.title3.weight(.semibold))
            Text(kind == .general
                 ? "A graphic (JPG, PNG, HEIC or PDF) or a Claude Design download. Screens picks the fonts, colors and backgrounds and builds Lyrics, Title, Announcements, Bible and Sermon Points designs with three lower thirds."
                 : "The series graphic (JPG, PNG, HEIC or PDF) or a Claude Design download. Screens picks the fonts, colors and backgrounds and builds the five designs and four lower thirds.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Choose File…", action: choose)
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
            if let alternatives { alternatives.padding(.top, 6) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45)))
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
    }

    /// The dropped art and one choice: build from it, or Cancel.
    private var confirmation: some View {
        VStack(spacing: 12) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if PhotoSeries.isDownload(run.files), let file = run.files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text(run.files.first?.lastPathComponent ?? "").font(.headline).lineLimit(1)
            Text(kind == .general
                 ? "Build a theme from this image?"
                 : "Build a sermon series from this art? It becomes this plan's series.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func working(_ stage: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(stage).font(.headline)
            Text(workingDetail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var workingDetail: String {
        let file = run.files.count == 1 ? run.files[0].lastPathComponent : "\(run.files.count) files"
        guard askingClaude else { return file }
        return "\(file)\nClaude is choosing fonts, colors and backgrounds. This usually takes under a minute."
    }

    @ViewBuilder
    private var ready: some View {
        if let draft, let preview {
            TextField(kind == .general ? "Theme name" : "Series name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            if !draft.analysis.rationale.isEmpty, draft.readByClaude || draft.source == .claudeDesign {
                Text(draft.analysis.rationale).font(.caption).foregroundStyle(.secondary)
            }
            if let note = draft.note {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if editing { editor(draft) }
                    let slides = preview.slides ?? []
                    Text("Full screen").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(slides.filter { $0.folder == nil }, id: \.id) { design in
                            tile(design, label: design.name, images: draft.previewImages, overCamera: false)
                        }
                    }
                    Text("Livestream lower thirds").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    let lower = slides.filter { $0.folder == BasicTemplates.lowerThirds }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(3, lower.count)),
                              spacing: 10) {
                        ForEach(lower, id: \.id) { design in
                            tile(design, label: design.name.replacingOccurrences(of: " (Lower Third)", with: ""),
                                 images: draft.previewImages, overCamera: true)
                        }
                    }
                    Text("The Title slide leaves the camera clear on the livestream. Drop different art to start over.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 300, maxHeight: 470)
        }
    }

    /// Everything chosen automatically, open to change: colors as hex or
    /// from the color well, the three faces and capitals.
    private func editor(_ draft: PhotoSeriesDraft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                HexColorField(label: "Text", hex: colorBinding(\.text, resolved: \.text), supportsOpacity: false)
                HexColorField(label: "Accent", hex: colorBinding(\.accent, resolved: \.accent), supportsOpacity: false)
                if draft.lowerThird == nil {
                    HexColorField(label: "Lower-third bar", hex: colorBinding(\.bar, resolved: \.bar), supportsOpacity: false)
                }
                Spacer()
            }
            FontFacePicker(title: "Heading font", families: families,
                           postScript: fontBinding(\.headingFont, chosen: draft.headingFont))
            FontFacePicker(title: "Body font", families: families,
                           postScript: fontBinding(\.bodyFont, chosen: draft.bodyFont))
            FontFacePicker(title: "Scripture font", families: families,
                           postScript: fontBinding(\.verseFont, chosen: draft.verseFont))
            HStack {
                Toggle("Headings in capitals", isOn: Binding(
                    get: { overrides.headingCaps ?? draft.analysis.headingAllCaps },
                    set: { overrides.headingCaps = $0 }))
                Spacer()
                Button("Use Automatic Choices") { overrides = PhotoSeriesOverrides() }
                    .disabled(overrides == PhotoSeriesOverrides())
            }
            Text("Lower-third text stays readable on the bar whatever you pick.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func tile(_ design: Slide, label: String, images: [String: CGImage], overCamera: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SeriesDesignPreview(design: design, images: images, overCamera: overCamera)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Picks

    private var resolved: PhotoSeriesTheme.Colors? {
        draft.map {
            PhotoSeriesTheme.colors(for: $0.input(name: name, titleArtID: nil, backgroundID: nil,
                                                  lowerThirdID: PhotoSeriesDraft.previewLowerThirdID, overrides: overrides))
        }
    }

    private func colorBinding(_ key: WritableKeyPath<PhotoSeriesOverrides, SeriesColor?>,
                              resolved field: KeyPath<PhotoSeriesTheme.Colors, SeriesColor>) -> Binding<String> {
        HexColorField.binding(Binding(
            get: { overrides[keyPath: key] ?? resolved?[keyPath: field] ?? .white },
            set: { overrides[keyPath: key] = $0 }))
    }

    private func fontBinding(_ key: WritableKeyPath<PhotoSeriesOverrides, String?>, chosen: String) -> Binding<String> {
        Binding(get: { overrides[keyPath: key] ?? chosen }, set: { overrides[keyPath: key] = $0 })
    }

    // MARK: Work

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoSeries.fileTypes
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in open(urls) }
        }
    }

    /// The same files again read them again (after a failure, say).
    private func open(_ urls: [URL]) {
        if urls == files { run.generation += 1 } else { files = urls }
    }

    private func read() async {
        guard !run.files.isEmpty else {
            phase = .empty
            return
        }
        saveError = nil
        let download = PhotoSeries.isDownload(run.files)
        if confirmFirst, !confirmed {
            let file = run.files[0]
            thumbnail = nil
            phase = .confirm
            guard !download else { return }
            let shown = await Task.detached { Self.thumbnail(of: file) }.value
            if !Task.isCancelled { thumbnail = shown }
            return
        }
        askingClaude = !download && !ClaudeClient.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            let made = try await PhotoSeries.draft(from: run.files, kind: kind, variant: run.generation) { stage in
                phase = .working(stage == .building ? "Building designs…"
                                 : download ? "Opening the download…" : "Reading the art…")
            }
            guard !Task.isCancelled else { return }
            draft = made
            imported = PhotoSeries.ImportedMedia()
            let suggested = made.suggestedName
            if name.trimmingCharacters(in: .whitespaces).isEmpty || name == filledName {
                name = suggested
                filledName = suggested
            }
            rebuildPreview()
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// A picture small enough to show, without decoding all of it.
    private nonisolated static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1040,
        ] as CFDictionary)
    }

    private func rebuildPreview() {
        preview = draft?.previewTheme(name: name, overrides: overrides)
    }

    private func done() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        saveError = nil
        let typed = name.trimmingCharacters(in: .whitespaces)
        do {
            let id = try await PhotoSeries.save(draft, name: typed.isEmpty ? draft.suggestedName : typed,
                                                overrides: overrides, model: model, imported: imported)
            onCreated(id)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A design drawn straight from its objects at thumbnail size, with the
/// series art held in memory: the preview shows before anything is
/// imported into the library, so it can't go through the slide renderer,
/// which draws only library media.
struct SeriesDesignPreview: View {
    let design: Slide
    let images: [String: CGImage]
    /// Lower thirds are shown over a stand-in for the camera shot.
    let overCamera: Bool

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 1920
            ZStack(alignment: .topLeading) {
                if overCamera {
                    cameraStandIn
                } else {
                    Color.black
                }
                ForEach(Array(design.objects.reversed().enumerated()), id: \.offset) { _, object in
                    if object.hidden != true {
                        let width = (object.width ?? 1920) * scale, height = (object.height ?? 1080) * scale
                        content(object, scale: scale)
                            .frame(width: width, height: height)
                            .opacity(object.opacity ?? 1)
                            .offset(x: (object.x ?? 0) * scale, y: (object.y ?? 0) * scale)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
    }

    /// A dim stage with a lit figure, enough to judge a see-through bar.
    private var cameraStandIn: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.75, green: 0.62, blue: 0.5).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.5, y: 0.45), startRadius: 2, endRadius: 140)
        }
    }

    @ViewBuilder
    private func content(_ object: SlideObject, scale: Double) -> some View {
        if object.objectKind == .text {
            text(object, scale: scale)
        } else {
            shape(object, scale: scale)
        }
    }

    private func text(_ object: SlideObject, scale: Double) -> some View {
        let style = object.textStyle ?? TextStyle()
        let shown = style.textTransform == .uppercase ? object.text.uppercased() : object.text
        let alignment: TextAlignment = switch style.horizontalAlignment {
        case .left: .leading
        case .right: .trailing
        default: .center
        }
        let frameAlignment: Alignment = switch style.horizontalAlignment {
        case .left: .leading
        case .right: .trailing
        default: .center
        }
        return Text(shown)
            .font(.custom(style.fontName ?? "HelveticaNeue", size: max(1, (style.fontSize ?? 72) * scale)))
            .tracking((style.tracking ?? 0) * scale)
            .foregroundStyle(Self.color(style.colorHex) ?? .white)
            .multilineTextAlignment(alignment)
            .minimumScaleFactor(0.3)
            .shadow(color: style.shadow.flatMap { Self.color($0.colorHex) } ?? .clear,
                    radius: (style.shadow?.blurRadius ?? 0) * scale / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private func shape(_ object: SlideObject, scale: Double) -> some View {
        let radius = object.shapeKind == .roundedRectangle ? (object.cornerRadius ?? 0) * scale : 0
        let outline = RoundedRectangle(cornerRadius: radius)
        ZStack {
            switch object.fill?.fillKind {
            case .media:
                if let id = object.fill?.mediaId, let image = images[id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(outline)
                } else {
                    outline.fill(Color.gray.opacity(0.3))
                }
            case .linearGradient:
                let stops = (object.fill?.gradientStops ?? []).compactMap { stop in
                    Self.color(stop.colorHex).map { Gradient.Stop(color: $0, location: stop.position) }
                }
                let angle = (object.fill?.gradientAngleDegrees ?? 0) * .pi / 180
                // Slides measure angles with y pointing down, as SwiftUI does.
                outline.fill(LinearGradient(
                    stops: stops,
                    startPoint: UnitPoint(x: 0.5 - cos(angle) / 2, y: 0.5 - sin(angle) / 2),
                    endPoint: UnitPoint(x: 0.5 + cos(angle) / 2, y: 0.5 + sin(angle) / 2)))
            case .solid:
                outline.fill(Self.color(object.fill?.colorHex) ?? .clear)
            default:
                Color.clear
            }
            if let stroke = object.stroke, let color = Self.color(stroke.colorHex) {
                outline.strokeBorder(color, lineWidth: max(0.5, stroke.width * scale))
            }
        }
    }

    /// "#RRGGBB" or "#RRGGBBAA".
    static func color(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        let digits = hex.replacingOccurrences(of: "#", with: "")
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let full = digits.count == 6 ? (value << 8) | 0xFF : value
        return Color(.sRGB,
                     red: Double((full >> 24) & 0xFF) / 255, green: Double((full >> 16) & 0xFF) / 255,
                     blue: Double((full >> 8) & 0xFF) / 255, opacity: Double(full & 0xFF) / 255)
    }
}
