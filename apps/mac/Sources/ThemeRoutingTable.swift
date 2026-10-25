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
            Text("Audience screens show these designs as they are. Choose what the livestream shows for each when Livestream is on Lower Third. A slide's own Livestream choice wins over these.")
                .font(.caption).foregroundStyle(.secondary)
            if let note = typeOverrideNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Text("Lower thirds").font(.callout).frame(width: 110, alignment: .leading)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Picker("", selection: Binding(
                    get: { model.streamLowerThirdThemeID },
                    set: { model.setStreamLowerThirdTheme($0) }
                )) {
                    Text(StreamWording.nothing).tag("")
                    Divider()
                    ForEach(appModel.entries(of: .theme), id: \.id) { Text("\($0.name) — lower thirds").tag($0.id) }
                }
                .labelsHidden()
            }
            Text("Lower Third, and any category not listed, uses these lower thirds.")
                .font(.caption).foregroundStyle(.tertiary)
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

    /// Screens by Type decides before this table for any type not left to
    /// each theme, which would otherwise look like this table being ignored.
    private var typeOverrideNote: String? {
        let settings = appModel.slideBuilding
        let types = PresentationTypes.screensTypes.filter { settings.screens(forType: $0).livestream != .theme }
        guard !types.isEmpty else { return nil }
        let names = types.map(PresentationTypes.screensTitle)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let series = types.contains(PresentationTypes.sermon)
            && settings.screens(forType: PresentationTypes.sermon).livestream == .series
            ? " The Message follows the plan's sermon series, which uses the series theme's table." : ""
        return "More › Lower Thirds sets the livestream for \(list) presentations, ahead of this table.\(series)"
    }

    private func designMenu(for category: String) -> some View {
        let current = model.streamDesigns.first { $0.category.caseInsensitiveCompare(category) == .orderedSame }
        return Menu {
            // The same three choices a slide's right-click › Livestream offers.
            // Lower Third is no entry of its own: it falls to the lower thirds
            // below, which a design picked further down replaces.
            Button(StreamWording.lowerThird) { model.setStreamDesign(nil, for: category) }
            Button(StreamWording.fullScreen) {
                model.setStreamDesign(.init(category: category, mode: .audience), for: category)
            }
            Button(StreamWording.nothing) { model.setStreamDesign(.init(category: category, mode: .clear), for: category) }
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
        guard let design else { return StreamWording.lowerThird }
        switch design.mode {
        case .clear: return StreamWording.nothing
        case .audience: return StreamWording.fullScreen
        case .design:
            let theme = design.themeId.flatMap { designs[$0] }
            let slide = theme?.slides.first { $0.id == design.slideId }
            return [theme?.name, slide?.name].compactMap { $0 }.joined(separator: " › ")
        }
    }
}
