import PresenterCore
import SwiftUI

/// The selected slides (or the current one), so a choice applies to every
/// slide picked in the editor.
@MainActor
private func targetSlideIDs(_ model: SlideEditorModel) -> [String] {
    let selected = model.presentation.slides.map(\.id).filter(model.selectedSlideIDs.contains)
    if !selected.isEmpty { return selected }
    return model.currentSlide.map { [$0.id] } ?? []
}

/// The livestream choices, worded the same on a slide's right-click menu, the
/// Screens sheet, the editor's Livestream picker and the theme's routing
/// table, so a slide and its theme read as the same three choices.
enum StreamWording {
    static let themeDefault = "Theme Default"
    static let lowerThird = "Lower Third"
    static let fullScreen = "Full Screen (takes over the stream)"
    static let nothing = "Nothing (camera only)"
}

extension StreamDesign {
    /// A slide's Lower Third names no design: it takes its theme's lower
    /// third for its category, so it follows theme edits.
    static let slideLowerThird = StreamDesign(category: "", mode: .design)
    static let slideFullScreen = StreamDesign(category: "", mode: .audience)
    static let slideNothing = StreamDesign(category: "", mode: .clear)

    /// Lower Third without a named design.
    var isThemeLowerThird: Bool { mode == .design && (themeId ?? "").isEmpty }
}

/// What the livestream shows for this slide.
struct SlideStreamPicker: View {
    let model: SlideEditorModel
    @State private var designs: [(id: String, name: String, slides: [Slide])] = []

    private var current: StreamDesign? { model.currentSlide?.streamDesign }

    var body: some View {
        LabeledContent("Livestream") {
            Menu {
                Button(StreamWording.themeDefault) { set(nil) }
                Divider()
                Button(StreamWording.lowerThird) { set(.slideLowerThird) }
                Button(StreamWording.fullScreen) { set(.slideFullScreen) }
                Button(StreamWording.nothing) { set(.slideNothing) }
                Divider()
                ForEach(designs, id: \.id) { theme in
                    Menu(theme.name) {
                        ForEach(lowerThirdsFirst(theme.slides), id: \.id) { design in
                            Button(title(design)) {
                                set(StreamDesign(category: "", mode: .design, themeId: theme.id, slideId: design.id))
                            }
                        }
                    }
                }
            } label: {
                Text(label).lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let entries = model.appModel.entries(of: .theme)
            await model.appModel.themesFilled(entries.map(\.id))
            designs = entries.map { ($0.id, $0.name, model.appModel.theme($0.id)?.slides ?? []) }
        }
    }

    private var label: String {
        guard let current else { return StreamWording.themeDefault }
        switch current.mode {
        case .clear: return StreamWording.nothing
        case .audience: return StreamWording.fullScreen
        case .design where current.isThemeLowerThird: return StreamWording.lowerThird
        case .design:
            let theme = designs.first { $0.id == current.themeId }
            let slide = theme?.slides.first { $0.id == current.slideId }
            return [theme?.name, slide?.name].compactMap { $0 }.joined(separator: " › ")
        }
    }

    private func set(_ design: StreamDesign?) {
        for id in targetSlideIDs(model) {
            model.updateSlide(id) { $0.streamDesign = design }
        }
    }

    private func lowerThirdsFirst(_ slides: [Slide]) -> [Slide] {
        let thirds = slides.filter { ($0.folder ?? "").lowercased().contains("third") }
        return thirds + slides.filter { !thirds.contains($0) }
    }

    private func title(_ slide: Slide) -> String {
        if let folder = slide.folder, !folder.isEmpty { return "\(slide.name)  ·  \(folder)" }
        return slide.name
    }
}

/// Which stage display layout comes up with this slide.
struct SlideStagePicker: View {
    let model: SlideEditorModel

    var body: some View {
        Picker("Stage", selection: Binding(
            get: { model.currentSlide?.stageLayoutId ?? "" },
            set: { value in
                for id in targetSlideIDs(model) {
                    model.updateSlide(id) { $0.stageLayoutId = value.isEmpty ? nil : value }
                }
            }
        )) {
            Text("Keep current").tag("")
            Divider()
            ForEach(model.appModel.entries(of: .confidenceLayout), id: \.id) { Text($0.name).tag($0.id) }
        }
    }
}
