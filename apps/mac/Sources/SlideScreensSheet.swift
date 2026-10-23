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
    @State private var themes: [(id: String, name: String, slides: [Slide])] = []
    @State private var audience = ""
    @State private var stream = "default"
    @State private var stage = ""

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
                    designOptions(prefix: "design")
                }
                Picker("Stage", selection: $stage) {
                    Text("Keep current").tag("")
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
                if let own = first.streamDesign {
                    switch own.mode {
                    case .clear: stream = "clear"
                    case .audience: stream = "audience"
                    case .design where own.isThemeLowerThird: stream = "lowerThird"
                    case .design:
                        let name = themes.first { $0.id == own.themeId }?.slides.first { $0.id == own.slideId }?.name ?? ""
                        stream = "design|\(own.themeId ?? "")|\(name)"
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

    private func apply() {
        let ids = Set(slideIDs)
        let deckTheme = presentation.themeId
        let audienceParts = audience.split(separator: "|", maxSplits: 2).map(String.init)
        let streamParts = stream.split(separator: "|", maxSplits: 2).map(String.init)
        let streamSlideID = streamParts.count == 3
            ? themes.first { $0.id == streamParts[1] }?.slides.first { $0.name == streamParts[2] }?.id : nil
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
                switch streamParts.first {
                case "clear": deck.slides[index].streamDesign = .slideNothing
                case "audience": deck.slides[index].streamDesign = .slideFullScreen
                case "lowerThird": deck.slides[index].streamDesign = .slideLowerThird
                case "design" where streamParts.count == 3:
                    deck.slides[index].streamDesign = StreamDesign(
                        category: "", mode: .design, themeId: streamParts[1], slideId: streamSlideID)
                default: deck.slides[index].streamDesign = nil
                }
                deck.slides[index].stageLayoutId = stageID.isEmpty ? nil : stageID
            }
        }
        dismiss()
    }
}
