import PresenterCore
import SwiftUI

/// In the theme editor: for each of this theme's designs, what the room sees
/// and exactly what the livestream shows when a slide using it is live.
struct ThemeRoutingTable: View {
    let model: SlideEditorModel

    /// Every theme's designs, read once — menus never open documents.
    @State private var designs: [String: (name: String, slides: [Slide])] = [:]

    private var appModel: AppModel { model.appModel }

    /// Full-screen designs — the ones slides pick by category.
    private var categories: [Slide] {
        model.presentation.slides.filter { slide in
            let folder = (slide.folder ?? "").lowercased()
            return !folder.contains("third")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audience screens show these designs as they are. Choose what the livestream shows for each (when Livestream is on Auto).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(categories, id: \.id) { category in
                HStack(alignment: .firstTextBaseline) {
                    Text(category.name)
                        .font(.callout.weight(category.id == model.currentSlide?.id ? .semibold : .regular))
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    designMenu(for: category.name)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Anything else").font(.callout).frame(width: 110, alignment: .leading)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Picker("", selection: Binding(
                    get: { model.streamLowerThirdThemeID },
                    set: { model.setStreamLowerThirdTheme($0) }
                )) {
                    Text("Camera clear").tag("")
                    Divider()
                    ForEach(appModel.entries(of: .theme), id: \.id) { Text("\($0.name) — lower thirds").tag($0.id) }
                }
                .labelsHidden()
            }
            Text("Stage displays follow the stage layout chosen in Show Setup, not the theme.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .task {
            let entries = appModel.entries(of: .theme)
            await appModel.themesFilled(entries.map(\.id))
            var loaded: [String: (name: String, slides: [Slide])] = [:]
            for entry in entries {
                loaded[entry.id] = (entry.name, appModel.theme(entry.id)?.slides ?? [])
            }
            designs = loaded
        }
    }

    private func designMenu(for category: String) -> some View {
        let current = model.streamDesigns.first { $0.category.caseInsensitiveCompare(category) == .orderedSame }
        return Menu {
            Button("Camera clear") { model.setStreamDesign(.init(category: category, mode: .clear), for: category) }
            Button("Same as audience (full screen)") {
                model.setStreamDesign(.init(category: category, mode: .audience), for: category)
            }
            Divider()
            ForEach(appModel.entries(of: .theme), id: \.id) { entry in
                Menu(entry.name) {
                    let slides = designs[entry.id]?.slides ?? []
                    ForEach(lowerThirdsFirst(slides), id: \.id) { design in
                        Button(designTitle(design)) {
                            model.setStreamDesign(
                                .init(category: category, mode: .design, themeId: entry.id, slideId: design.id),
                                for: category)
                        }
                    }
                    if slides.isEmpty { Text("Loading…") }
                }
            }
            Divider()
            Button("Use “Anything else”") { model.setStreamDesign(nil, for: category) }
        } label: {
            Text(label(current))
                .lineLimit(1)
                .foregroundStyle(current == nil ? .secondary : .primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lowerThirdsFirst(_ slides: [Slide]) -> [Slide] {
        let thirds = slides.filter { ($0.folder ?? "").lowercased().contains("third") }
        return thirds + slides.filter { !thirds.contains($0) }
    }

    private func designTitle(_ slide: Slide) -> String {
        if let folder = slide.folder, !folder.isEmpty { return "\(slide.name)  ·  \(folder)" }
        return slide.name
    }

    private func label(_ design: StreamDesign?) -> String {
        guard let design else { return "Anything else" }
        switch design.mode {
        case .clear: return "Camera clear"
        case .audience: return "Same as audience"
        case .design:
            let theme = design.themeId.flatMap { designs[$0] }
            let slide = theme?.slides.first { $0.id == design.slideId }
            return [theme?.name, slide?.name].compactMap { $0 }.joined(separator: " › ")
        }
    }
}
