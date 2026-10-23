import AppKit
import PresenterCore
import SwiftUI

/// New Sermon Series › From a Photo: drop the series graphic, Claude reads
/// it, and all nine designs appear to check, recolor and keep.
struct PhotoSeriesPane: View {
    let model: AppModel
    @Binding var name: String
    /// Set by a drop anywhere on the sheet (or the plan's series picker).
    @Binding var photo: URL?
    let onCancel: () -> Void
    let onCreated: (String) -> Void

    private enum Phase: Equatable {
        case empty
        case working(String)
        case ready
        case failed(String)
    }

    private struct Run: Equatable {
        var photo: URL?
        var generation = 0
    }

    @State private var phase = Phase.empty
    @State private var run = Run()
    @State private var draft: PhotoSeriesDraft?
    @State private var preview: Theme?
    @State private var overrides = PhotoSeriesOverrides()
    @State private var adjusting = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var dropTargeted = false
    /// The name last filled in from the art, so a new read replaces it but
    /// never a name someone typed.
    @State private var filledName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .empty: dropZone(error: nil)
            case .failed(let message): dropZone(error: message)
            case .working(let stage): working(stage)
            case .ready: ready
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                if phase == .ready {
                    Button("Regenerate") { run.generation += 1 }
                        .help(draft?.readByClaude == true ? "Ask Claude for another take on the art" : "Try another accent from the art")
                    Button("Choose Another…", action: choose)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button(saving ? "Saving…" : "Use This Series") { Task { await use() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase != .ready || saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: SeriesArt.accepts) else { return false }
            open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { run.photo = photo }
        .onChange(of: photo) { _, url in
            // Colors picked for other art don't carry over.
            overrides = PhotoSeriesOverrides()
            run = Run(photo: url, generation: 0)
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
            Text("Drop the series art here").font(.title3.weight(.semibold))
            Text("The series title graphic, as a JPG, PNG, HEIC or PDF. Screens builds the five designs and four lower thirds to match it.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose File…", action: choose)
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.45)))
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.08) : .clear))
    }

    private func working(_ stage: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(stage).font(.headline)
            Text(photo?.lastPathComponent ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    @ViewBuilder
    private var ready: some View {
        if let draft, let preview {
            TextField("Series name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            if !draft.analysis.rationale.isEmpty, draft.readByClaude {
                Text(draft.analysis.rationale).font(.caption).foregroundStyle(.secondary)
            }
            if let note = draft.note {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Full screen").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(Self.fullScreen) { item in
                            tile(preview.slides?.first { $0.name == item.category && $0.folder == nil },
                                 label: item.label, images: draft.previewImages, overCamera: false)
                        }
                    }
                    Text("Livestream lower thirds").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(Self.lowerThirds) { item in
                            tile(preview.slides?.first { $0.name == "\(item.category) (Lower Third)" },
                                 label: item.label, images: draft.previewImages, overCamera: true)
                        }
                    }
                    Text("The Title slide leaves the camera clear on the livestream.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 300, maxHeight: 470)
            DisclosureGroup("Adjust Colors", isExpanded: $adjusting) {
                HStack(spacing: 18) {
                    ColorPicker("Text", selection: colorBinding(\.text, resolved: \.text), supportsOpacity: false)
                    ColorPicker("Accent", selection: colorBinding(\.accent, resolved: \.accent), supportsOpacity: false)
                    ColorPicker("Lower-third bar", selection: colorBinding(\.bar, resolved: \.bar), supportsOpacity: false)
                    Spacer()
                    Button("Reset") { overrides = PhotoSeriesOverrides() }
                        .disabled(overrides == PhotoSeriesOverrides())
                }
                .padding(.top, 6)
                Text("Lower-third text stays readable on the bar whatever you pick.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ design: Slide?, label: String, images: [String: CGImage], overCamera: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let design {
                    SeriesDesignPreview(design: design, images: images, overCamera: overCamera)
                } else {
                    Color.secondary.opacity(0.1).aspectRatio(16 / 9, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private struct Slot: Identifiable {
        var category: String
        var label: String
        var id: String { category }
    }

    private static let fullScreen = [
        Slot(category: SermonSeriesTheme.titleCategory, label: "Title"),
        Slot(category: SermonSeriesTheme.scriptureCategory, label: "Bible"),
        Slot(category: SermonSeriesTheme.pointCategory, label: "Sermon Points"),
        Slot(category: SermonSeriesTheme.pointScriptureCategory, label: "Point + Scripture"),
        Slot(category: SermonSeriesTheme.worshipCategory, label: "Worship"),
    ]

    private static let lowerThirds = [
        Slot(category: SermonSeriesTheme.scriptureCategory, label: "Bible"),
        Slot(category: SermonSeriesTheme.pointCategory, label: "Points"),
        Slot(category: SermonSeriesTheme.pointScriptureCategory, label: "Point + Scripture"),
        Slot(category: SermonSeriesTheme.worshipCategory, label: "Worship"),
    ]

    // MARK: Colors

    private var resolved: PhotoSeriesTheme.Colors? {
        draft.map { PhotoSeriesTheme.colors(for: $0.input(name: name, titleArtID: nil, backgroundID: nil, overrides: overrides)) }
    }

    private func colorBinding(_ key: WritableKeyPath<PhotoSeriesOverrides, SeriesColor?>,
                              resolved field: KeyPath<PhotoSeriesTheme.Colors, SeriesColor>) -> Binding<Color> {
        Binding(
            get: {
                let color = overrides[keyPath: key] ?? resolved?[keyPath: field] ?? .white
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
            },
            set: { picked in
                guard let ns = NSColor(picked).usingColorSpace(.sRGB) else { return }
                overrides[keyPath: key] = SeriesColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
            })
    }

    // MARK: Work

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SeriesArt.types
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in open(url) }
        }
    }

    /// The same file again reads it again (after a failure, say).
    private func open(_ url: URL) {
        if url == photo { run.generation += 1 } else { photo = url }
    }

    private func read() async {
        guard let url = run.photo else {
            phase = .empty
            return
        }
        saveError = nil
        do {
            let made = try await PhotoSeries.draft(from: url, variant: run.generation) { stage in
                phase = .working(stage == .reading ? "Reading the art…" : "Building designs…")
            }
            guard !Task.isCancelled else { return }
            draft = made
            let suggested = made.suggestedName
            if !suggested.isEmpty, name.trimmingCharacters(in: .whitespaces).isEmpty || name == filledName {
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

    private func rebuildPreview() {
        preview = draft?.previewTheme(name: name, overrides: overrides)
    }

    private func use() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        saveError = nil
        do {
            let id = try await PhotoSeries.save(draft, name: name.trimmingCharacters(in: .whitespaces),
                                                overrides: overrides, model: model)
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
