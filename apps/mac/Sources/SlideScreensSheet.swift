import PresenterCore
import SwiftUI

struct SlideScreensTarget: Identifiable {
    let id = UUID()
    let slideIDs: [String]
}

/// Right-click › Screens… in the show view: what the chosen slides put on
/// the audience screens, the livestream and the stage display.
struct SlideScreensSheet: View {
    let model: AppModel
    let presentation: Presentation
    let slideIDs: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.actionRouter) private var actionRouter
    @State private var themes: [(id: String, name: String, slides: [Slide])] = []
    @State private var audience = ""
    @State private var stream = "default"
    @State private var stage = ""
    /// The lower-third picture on offer: the slide's own, or one just picked.
    @State private var imageID: String?

    private var first: Slide? { presentation.slides.first { slideIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(slideIDs.count == 1 ? "Screens for “\(first?.name.isEmpty == false ? first!.name : "Slide")”" : "Screens for \(slideIDs.count) Slides")
                .font(.headline)
            Form {
                Picker("Audience", selection: $audience) {
                    Text(StreamWording.themeDefault).tag("")
                    designOptions(prefix: "design")
                }
                Picker("Livestream", selection: $stream) {
                    Text(StreamWording.themeDefault).tag("default")
                    Text(StreamWording.lowerThird).tag("lowerThird")
                    Text(StreamWording.fullScreen).tag("audience")
                    Text(StreamWording.nothing).tag("clear")
                    if let imageID {
                        Text(model.media(imageID)?.name ?? "Lower-Third Image").tag("image|\(imageID)")
                    }
                    // The slide's own design when its theme or design has
                    // gone: still shown, so Apply keeps it rather than
                    // quietly putting the slide back on its theme's.
                    if stream.hasPrefix("design|"), !knownStreamTags.contains(stream) {
                        Text("Its Own Design").tag(stream)
                    }
                    streamDesignOptions
                }
                LabeledContent("") {
                    HStack {
                        Button(StreamWording.lowerThirdImage) {
                            LowerThirdImagePicker.choose(model) { id in
                                imageID = id
                                stream = "image|\(id)"
                            }
                        }
                        if stream.hasPrefix("image|") {
                            Button(StreamWording.removeLowerThirdImage) { stream = "default" }
                        }
                    }
                }
                Picker("Stage", selection: $stage) {
                    Text("Keep current").tag("")
                    Text(StageWording.audience).tag(StageLayouts.audienceID)
                    ForEach(model.entries(of: .confidenceLayout), id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .task {
            let entries = model.entries(of: .theme)
            await model.themesFilled(entries.map(\.id))
            themes = entries.map { ($0.id, $0.name, model.theme($0.id)?.slides ?? []) }
            if let first {
                if let name = first.themeSlideName, !name.isEmpty {
                    audience = "design|\(first.themeId ?? presentation.themeId)|\(name)"
                }
                if let own = first.streamDesign, let image = own.lowerThirdImageID {
                    imageID = image
                    stream = "image|\(image)"
                } else if let own = first.streamDesign {
                    switch own.mode {
                    case .clear: stream = "clear"
                    case .audience: stream = "audience"
                    case .design where own.isThemeLowerThird: stream = "lowerThird"
                    case .design:
                        stream = Self.tag(own)
                    }
                }
                stage = first.stageLayoutId ?? ""
            }
        }
    }

    @ViewBuilder
    private func designOptions(prefix: String) -> some View {
        ForEach(themes, id: \.id) { theme in
            Section(theme.name) {
                ForEach(theme.slides, id: \.id) { design in
                    Text(design.folder.map { "\(design.name) · \($0)" } ?? design.name)
                        .tag("\(prefix)|\(theme.id)|\(design.name)")
                }
            }
        }
    }

    /// Every theme's designs for the livestream, its lower thirds first.
    /// Chosen by the design itself, not its name: a theme's full-screen
    /// design and its lower third are often named alike.
    @ViewBuilder
    private var streamDesignOptions: some View {
        ForEach(themes, id: \.id) { theme in
            Section(theme.name) {
                ForEach(StreamWording.lowerThirdsFirst(theme.slides), id: \.id) { design in
                    Text(design.folder.map { "\(design.name) · \($0)" } ?? design.name)
                        .tag("design|\(theme.id)|\(design.id)")
                }
            }
        }
    }

    private static func tag(_ design: StreamDesign) -> String {
        "design|\(design.themeId ?? "")|\(design.slideId ?? "")"
    }

    private var knownStreamTags: Set<String> {
        Set(themes.flatMap { theme in theme.slides.map { "design|\(theme.id)|\($0.id)" } })
    }

    private func apply() {
        let ids = Set(slideIDs)
        let deckTheme = presentation.themeId
        let audienceParts = audience.split(separator: "|", maxSplits: 2).map(String.init)
        // Empty parts kept: a design that names a theme but no slide in it
        // is "design|<theme>|", and must not read as no choice at all.
        let streamParts = stream.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let streamSlideID = streamParts.count == 3 && !streamParts[2].isEmpty ? streamParts[2] : nil
        let chosen: StreamDesign? = switch streamParts.first {
        case "clear": .slideNothing
        case "audience": .slideFullScreen
        case "lowerThird": .slideLowerThird
        case "image" where streamParts.count == 2: .lowerThirdImage(streamParts[1])
        case "design" where streamParts.count == 3:
            // Left on the design it already had: that design, untouched.
            if let own = first?.streamDesign, own.mode == .design, stream == Self.tag(own) {
                own
            } else {
                StreamDesign(category: "", mode: .design, themeId: streamParts[1], slideId: streamSlideID)
            }
        default: nil
        }
        let stageID = stage
        model.updateSlides(presentationID: presentation.id, undoLabel: "Screens") { deck in
            for index in deck.slides.indices where ids.contains(deck.slides[index].id) {
                if audienceParts.count == 3 {
                    deck.slides[index].themeSlideName = audienceParts[2]
                    deck.slides[index].themeId = audienceParts[1] == deckTheme ? nil : audienceParts[1]
                } else {
                    deck.slides[index].themeSlideName = nil
                    deck.slides[index].themeId = nil
                }
                deck.slides[index].streamDesign = chosen
                deck.slides[index].stageLayoutId = stageID.isEmpty ? nil : stageID
            }
        }
        // A slide that is on screen takes the choice now, not the next
        // time it goes up.
        actionRouter?.noteStreamDesign(chosen, forSlides: ids)
        dismiss()
    }
}

struct PresentationScreensTarget: Identifiable {
    let id: String
}

/// The tags beside a presentation's name in Present, clicked: what the
/// presentation is (its type, which decides its screens unless it says
/// otherwise) and what it puts on the livestream and the stage. A slide can
/// still choose for itself with right-click › Screens…, so a lower third can
/// change partway through.
struct PresentationScreensSheet: View {
    let model: AppModel
    let presentationID: String

    @Environment(\.dismiss) private var dismiss
    @State private var type = ""
    @State private var streamTheme = ""
    @State private var stage = ""
    @State private var resetSlides = false
    @State private var loaded = false

    private var presentation: Presentation? { model.presentation(presentationID) }

    /// Slides that make their own livestream or stage choice.
    private var slidesWithOwn: Int {
        presentation?.slides.filter { $0.streamDesign != nil || ($0.stageLayoutId ?? "").isEmpty == false }.count ?? 0
    }

    private var types: [String] {
        var all = PresentationTypes.builtIn
        if !type.isEmpty, !all.contains(type) { all.append(type) }
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screens for \u{201C}\(presentation?.name ?? "Presentation")\u{201D}").font(.headline)
            Form {
                Picker("Type", selection: $type) {
                    Text("None").tag("")
                    ForEach(types, id: \.self) { Text($0 == PresentationTypes.sermon ? "Message" : $0).tag($0) }
                }
                .help("Its type picks its livestream lower third and stage display, set for each type in Settings › Livestream › Lower Thirds")
                Picker("Livestream", selection: $streamTheme) {
                    Text("From its type").tag("")
                    ForEach(model.entries(of: .theme).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.id) {
                        Text($0.name).tag($0.id)
                    }
                }
                .help("A theme whose lower third this presentation uses on the livestream")
                Picker("Stage", selection: $stage) {
                    Text("From its type").tag("")
                    Text(StageWording.audience).tag(StageLayouts.audienceID)
                    ForEach(model.entries(of: .confidenceLayout), id: \.id) { Text($0.name).tag($0.id) }
                }
                if slidesWithOwn > 0 {
                    Toggle(isOn: $resetSlides) {
                        Text("\(slidesWithOwn) slide\(slidesWithOwn == 1 ? " chooses its" : "s choose their") own. Use these for every slide")
                    }
                }
            }
            .formStyle(.grouped)
            Text("To change one slide, right-click it › Screens….")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            guard !loaded, let presentation else { return }
            loaded = true
            type = PresentationTypes.category(of: presentation) ?? ""
            streamTheme = presentation.streamThemeId ?? ""
            stage = presentation.stageLayoutId ?? ""
        }
    }

    private func apply() {
        let type = self.type, streamTheme = self.streamTheme, stage = self.stage, reset = resetSlides
        _ = model.updatePresentation(presentationID) { deck in
            deck.category = type.isEmpty ? nil : type
            deck.streamThemeId = streamTheme.isEmpty ? nil : streamTheme
            deck.stageLayoutId = stage.isEmpty ? nil : stage
            if reset {
                for index in deck.slides.indices {
                    deck.slides[index].streamDesign = nil
                    deck.slides[index].stageLayoutId = nil
                }
            }
        }
        dismiss()
    }
}
