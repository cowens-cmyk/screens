import Observation
import PresenterCore
import SwiftUI

/// Every theme's lower thirds, read once when a picker appears, so menus
/// never open documents while they're open.
struct LowerThirdCatalog {
    struct Group: Identifiable {
        let theme: Theme
        let isSeries: Bool
        /// The theme's Lower Thirds designs.
        let designs: [Slide]
        var id: String { theme.id }
    }

    var groups: [Group] = []
    var themes: [String: Theme] = [:]

    @MainActor
    static func load(_ model: AppModel) async -> LowerThirdCatalog {
        let entries = model.entries(of: .theme)
        await model.themesFilled(entries.map(\.id))
        var catalog = LowerThirdCatalog()
        for entry in entries {
            guard let theme = model.theme(entry.id) else { continue }
            catalog.themes[theme.id] = theme
            let designs = (theme.slides ?? []).filter { ($0.folder ?? "").lowercased().contains("third") }
            guard !designs.isEmpty else { continue }
            catalog.groups.append(Group(theme: theme, isSeries: SermonSeriesTheme.isSeries(theme), designs: designs))
        }
        // Series last: they change every few weeks, the church's own
        // lower thirds don't.
        catalog.groups.sort { !$0.isSeries && $1.isSeries }
        return catalog
    }

    /// A design's name without the "(Lower Third)" its theme files it under.
    static func shortName(_ design: Slide) -> String {
        let lowered = design.name.lowercased()
        for suffix in [" (lower third)", " lower third"] where lowered.hasSuffix(suffix) {
            return String(design.name.dropLast(suffix.count))
        }
        return design.name
    }
}

/// The livestream choices for a type, worded the same in Screens by Type,
/// the song editor and the presentation inspector.
enum TypeStreamWording {
    static let theme = "Each theme's own lower third"
    static let series = "The plan's sermon series"
    static let audience = "Same as audience (full screen)"
    static let clear = "Nothing (camera only)"

    @MainActor
    static func title(_ stream: TypeStream, catalog: LowerThirdCatalog, model: AppModel) -> String {
        switch stream {
        case .theme: return theme
        case .series: return series
        case .audience: return audience
        case .clear: return clear
        case .design(let themeID, let slideID):
            let name = catalog.themes[themeID]?.name ?? model.entry(themeID)?.name ?? "Missing theme"
            guard let slideID else { return "\(name) — all lower thirds" }
            let design = catalog.themes[themeID]?.slides?.first { $0.id == slideID }
            return design.map { "\(name) › \(LowerThirdCatalog.shortName($0))" } ?? name
        }
    }
}

/// One type's livestream choice: the type's own options, then every lower
/// third in the library, grouped by theme.
struct TypeStreamPicker: View {
    let type: String
    @Binding var selection: TypeStream
    let catalog: LowerThirdCatalog

    var body: some View {
        Picker("Livestream", selection: $selection) {
            if type == PresentationTypes.sermon { Text(TypeStreamWording.series).tag(TypeStream.series) }
            Text(TypeStreamWording.theme).tag(TypeStream.theme)
            if type != PresentationTypes.sermon { Text(TypeStreamWording.series).tag(TypeStream.series) }
            Text(TypeStreamWording.audience).tag(TypeStream.audience)
            Text(TypeStreamWording.clear).tag(TypeStream.clear)
            ForEach(catalog.groups) { group in
                Section(group.isSeries ? "\(group.theme.name) (series)" : group.theme.name) {
                    Text("All \(group.theme.name) lower thirds").tag(TypeStream.design(themeId: group.theme.id, slideId: nil))
                    ForEach(group.designs, id: \.id) { design in
                        Text(LowerThirdCatalog.shortName(design))
                            .tag(TypeStream.design(themeId: group.theme.id, slideId: design.id))
                    }
                }
            }
            // A choice whose theme is gone still shows what it was.
            if case .design(let themeID, _) = selection, catalog.themes[themeID] == nil {
                Text("Missing theme").tag(selection)
            }
        }
        .labelsHidden()
    }
}

/// The lower third a type's choice puts over the camera, drawn on a
/// stand-in for the camera so it reads as it will on the stream.
struct LowerThirdPreview: View {
    let model: AppModel
    let render: RenderContext?
    let type: String
    let stream: TypeStream
    let catalog: LowerThirdCatalog

    var body: some View {
        ZStack {
            CameraBackdrop()
            switch stream {
            case .audience:
                Color.black.opacity(0.75)
                caption("Full screen")
            case .clear:
                caption("Camera only")
            case .theme:
                caption("Follows each slide's theme")
            case .series, .design:
                if let design = resolved {
                    LowerThirdImage(model: model, render: render, theme: design.theme, design: design.slide)
                } else {
                    caption(stream == .series ? "No series chosen" : "No lower third")
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.separator.opacity(0.6)))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: Capsule())
    }

    /// The category this type's slides usually ask for, so the preview
    /// shows the design they'd get.
    private var sampleCategory: String {
        switch type {
        case PresentationTypes.worship: "Lyrics"
        case PresentationTypes.sermon: "Sermon Points"
        case PresentationTypes.bible: "Bible"
        case PresentationTypes.announcements: "Announcements"
        default: "Lower Third"
        }
    }

    private var seriesID: String? {
        let plan = model.currentServiceID.flatMap { model.resident.services.value($0) }
        return [plan?.sermonThemeId, model.slideBuilding.sermonThemeId].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var resolved: (theme: Theme, slide: Slide)? {
        switch stream {
        case .design(let themeID, let slideID?):
            guard let theme = catalog.themes[themeID], let slide = theme.slides?.first(where: { $0.id == slideID }) else { return nil }
            return (theme, slide)
        case .design(let themeID, nil):
            return catalog.themes[themeID].flatMap(routed)
        case .series:
            return seriesID.flatMap { catalog.themes[$0] }.flatMap(routed)
        default:
            return nil
        }
    }

    /// What a theme carrying the stream gives this type's slides, in the
    /// livestream's order: its tie for the category, its lower-third theme,
    /// then its own lower thirds.
    private func routed(_ theme: Theme) -> (theme: Theme, slide: Slide)? {
        let full = (theme.slides ?? []).filter { !($0.folder ?? "").lowercased().contains("third") }
        let category = ThemeCategories.match(sampleCategory, in: full)?.name ?? sampleCategory
        if let pick = theme.streamDesigns?.first(where: { $0.category.caseInsensitiveCompare(category) == .orderedSame }),
           pick.mode == .design, let source = pick.themeId.flatMap({ catalog.themes[$0] }),
           let slide = source.slides?.first(where: { $0.id == pick.slideId }) {
            return (source, slide)
        }
        // A theme set up for the livestream keeps its gaps, as on the stream.
        let carrier: Theme
        if let lowerThird = theme.streamLowerThirdThemeId.flatMap({ catalog.themes[$0] }) {
            carrier = lowerThird
        } else if (theme.streamDesigns ?? []).isEmpty {
            carrier = theme
        } else {
            return nil
        }
        guard carrier.hasSlideFolder(BasicTemplates.lowerThirds) else { return nil }
        let thirds = ThemeCategories.lowerThirds(of: carrier).slides ?? []
        guard let slide = ThemeCategories.match(category, in: thirds) ?? thirds.first else { return nil }
        return (carrier, slide)
    }
}

/// A design drawn on its own, transparent where it has nothing.
private struct LowerThirdImage: View {
    let model: AppModel
    let render: RenderContext?
    let theme: Theme
    let design: Slide

    var body: some View {
        let stamp = model.entry(theme.id)?.updatedAt.timeIntervalSince1970 ?? 0
        let key = "lower-third-preview|\(theme.id)|\(design.id)|\(stamp)"
        if let image = ThumbnailStore.shared.slideContent(
            slide: design, theme: nil, render: render, model: model, legibleText: false,
            cacheKey: key, identity: key,
            mediaEffects: { model.mediaSceneEffects(id: $0) }) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

/// A stand-in for the camera: a dim room with stage light, so a lower third
/// is judged against something like the real picture, not a checkerboard.
struct CameraBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.14, blue: 0.20), Color(red: 0.32, green: 0.24, blue: 0.20)],
                startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                let size = proxy.size
                Ellipse().fill(Color(red: 0.95, green: 0.78, blue: 0.55).opacity(0.35))
                    .frame(width: size.width * 0.5, height: size.height * 0.6)
                    .position(x: size.width * 0.3, y: size.height * 0.2)
                    .blur(radius: size.width * 0.06)
                Ellipse().fill(Color(red: 0.45, green: 0.55, blue: 0.95).opacity(0.25))
                    .frame(width: size.width * 0.45, height: size.height * 0.5)
                    .position(x: size.width * 0.78, y: size.height * 0.3)
                    .blur(radius: size.width * 0.06)
                // Someone at the front, in silhouette.
                Capsule().fill(Color.black.opacity(0.45))
                    .frame(width: size.width * 0.11, height: size.height * 0.55)
                    .position(x: size.width * 0.52, y: size.height * 0.78)
                Circle().fill(Color.black.opacity(0.45))
                    .frame(width: size.width * 0.07)
                    .position(x: size.width * 0.52, y: size.height * 0.42)
            }
        }
    }
}

/// Settings › Show Setup › Screens by Type, also a sheet from the toolbar's
/// More menu: one row per presentation type, with the theme new ones start
/// in and the lower third the livestream puts over the camera for all of
/// them, so worship gets its lower third once instead of song by song.
struct ScreensByTypeForm: View {
    let model: AppModel
    let render: RenderContext?

    @State private var catalog = LowerThirdCatalog()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Type")
                    Text("Audience")
                    Text("Livestream")
                    Text("")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(PresentationTypes.screensTypes, id: \.self) { type in
                    GridRow(alignment: .center) {
                        Text(PresentationTypes.screensTitle(type))
                            .frame(minWidth: 90, alignment: .leading)
                        audience(type)
                            .frame(minWidth: 160, maxWidth: 220, alignment: .leading)
                        TypeStreamPicker(type: type, selection: binding(type), catalog: catalog)
                            .frame(minWidth: 200, maxWidth: 260, alignment: .leading)
                        LowerThirdPreview(
                            model: model, render: render, type: type,
                            stream: model.slideBuilding.screens(forType: type).livestream, catalog: catalog)
                            .frame(width: 128)
                    }
                }
            }
            Text("Audience: the theme new songs, messages and scripture start in. Presentations already made keep their own.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Livestream: what goes over the camera for every presentation of that type while Livestream is on Lower Third. A presentation's own Livestream theme, or a slide's own choice, wins over it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: model.version(of: .theme)) { catalog = await LowerThirdCatalog.load(model) }
    }

    private func binding(_ type: String) -> Binding<TypeStream> {
        Binding(
            get: { model.slideBuilding.screens(forType: type).livestream },
            set: { value in model.updateSlideBuilding { $0.updateScreens(forType: type) { $0.livestream = value } } })
    }

    /// The theme new presentations of a type start in. These are the same
    /// settings the song, scripture and series pickers write, so there's one
    /// answer wherever it's asked.
    @ViewBuilder
    private func audience(_ type: String) -> some View {
        switch type {
        case PresentationTypes.worship:
            themePicker(model.slideBuildingBinding(\.lyricsImportThemeId), none: "None")
        case PresentationTypes.sermon:
            themePicker(model.slideBuildingBinding(\.sermonThemeId), none: "Each plan's series")
                .help("The series for plans that haven't picked their own. Change a plan's series in More › Message & Series.")
        case PresentationTypes.bible:
            themePicker(model.slideBuildingBinding(\.scriptureThemeId), none: "The presentation's own theme")
        default:
            Text("Each presentation's own").foregroundStyle(.secondary)
        }
    }

    private func themePicker(_ selection: Binding<String>, none: String) -> some View {
        Picker("Audience", selection: selection) {
            Text(none).tag("")
            Divider()
            ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
    }
}

/// Opens Screens by Type as a sheet over the main window, from the
/// toolbar's More menu.
@MainActor
@Observable
final class ScreensByTypeRouter {
    static let shared = ScreensByTypeRouter()
    var shown = false
}

struct ScreensByTypeSheet: View {
    let model: AppModel
    let render: RenderContext?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lower Thirds & Themes").font(.title3.weight(.semibold))
            ScreensByTypeForm(model: model, render: render)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720)
    }
}

/// "Worship default: Worship › Lyrics" — what a presentation's Livestream
/// gets when it leaves the choice to its type, for the song editor and the
/// presentation inspector.
struct InheritedLivestreamLabel {
    @MainActor
    static func text(for presentation: Presentation, model: AppModel, catalog: LowerThirdCatalog) -> String {
        let type = PresentationTypes.screensType(of: presentation)
        let stream = model.slideBuilding.screens(forType: type).livestream
        return "\(PresentationTypes.screensTitle(type)) default: \(TypeStreamWording.title(stream, catalog: catalog, model: model))"
    }
}
