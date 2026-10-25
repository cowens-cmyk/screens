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

    /// One lower third, as the pickers list it.
    struct Choice: Identifiable {
        let themeID: String
        let slideID: String
        let title: String
        var id: String { themeID + "|" + slideID }
    }

    var groups: [Group] = []
    var themes: [String: Theme] = [:]

    /// Every lower third outside the series, by name. Two with the same
    /// name say which theme each is from.
    var choices: [Choice] {
        let designs = groups.filter { !$0.isSeries }.flatMap { group in group.designs.map { (group.theme, $0) } }
        let names = designs.map { LowerThirdCatalog.shortName($0.1) }
        return designs.map { theme, design in
            let name = LowerThirdCatalog.shortName(design)
            let shared = names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.count > 1
            return Choice(themeID: theme.id, slideID: design.id, title: shared ? "\(name) (\(theme.name))" : name)
        }
    }

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

/// The livestream choices for a type, worded the same in the Lower Thirds
/// sheet, the song editor and the presentation inspector. Plain names: the
/// lower third itself, not where it's filed.
enum TypeStreamWording {
    static let theme = "Not set"
    static let series = "Sermon series"
    static let audience = "Full screen"
    static let clear = "Camera only"

    @MainActor
    static func title(_ stream: TypeStream, catalog: LowerThirdCatalog, model: AppModel) -> String {
        switch stream {
        case .theme: return theme
        case .series: return series
        case .audience: return audience
        case .clear: return clear
        case .design(let themeID, let slideID):
            let name = catalog.themes[themeID]?.name ?? model.entry(themeID)?.name ?? "Missing lower third"
            guard let slideID else { return name }
            return catalog.choices.first { $0.themeID == themeID && $0.slideID == slideID }?.title
                ?? catalog.themes[themeID]?.slides?.first { $0.id == slideID }.map(LowerThirdCatalog.shortName)
                ?? name
        }
    }
}

/// One type's lower third: "Not set" (or the sermon series, for the
/// Message), then each lower third in the library by name, then camera
/// only. Series lower thirds aren't listed; "Sermon series" covers them and
/// they change every few weeks.
struct TypeStreamPicker: View {
    let model: AppModel
    let type: String
    @Binding var selection: TypeStream
    let catalog: LowerThirdCatalog

    var body: some View {
        Picker("Lower third", selection: $selection) {
            if type == PresentationTypes.sermon {
                Text(TypeStreamWording.series).tag(TypeStream.series)
            } else {
                Text(TypeStreamWording.theme).tag(TypeStream.theme)
            }
            Divider()
            ForEach(catalog.choices) { choice in
                Text(choice.title).tag(TypeStream.design(themeId: choice.themeID, slideId: choice.slideID))
            }
            Divider()
            Text(TypeStreamWording.clear).tag(TypeStream.clear)
            // A choice the list doesn't offer (set before, or its lower
            // third was deleted) still shows what it is.
            if !offered(selection) {
                Text(TypeStreamWording.title(selection, catalog: catalog, model: model)).tag(selection)
            }
        }
        .labelsHidden()
    }

    private func offered(_ stream: TypeStream) -> Bool {
        switch stream {
        case .series: type == PresentationTypes.sermon
        case .theme: type != PresentationTypes.sermon
        case .clear: true
        case .audience: false
        case .design(let themeID, let slideID):
            catalog.choices.contains { $0.themeID == themeID && $0.slideID == slideID }
        }
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
                caption("Not set")
            case .series, .design:
                if let design = resolved {
                    LowerThirdImage(model: model, render: render, theme: design.theme, design: design.slide)
                } else {
                    caption(stream == .series ? "No series yet" : "Missing")
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

/// Settings › Show Setup › Lower Thirds, also a sheet from the toolbar's
/// More menu: for each part of the service, the lower third the
/// livestream puts over the camera, chosen once instead of song by song.
struct ScreensByTypeForm: View {
    let model: AppModel
    let render: RenderContext?

    @State private var catalog = LowerThirdCatalog()

    /// "Other" (no type, videos) stays on each theme's own lower third;
    /// listing it only raised questions.
    private let types = [PresentationTypes.worship, PresentationTypes.sermon, PresentationTypes.bible, PresentationTypes.announcements]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The lower third shown on the livestream for each part of the service.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(types, id: \.self) { type in
                    if type != types.first { Divider() }
                    HStack(spacing: 16) {
                        Text(PresentationTypes.screensTitle(type))
                            .font(.headline)
                            .frame(width: 120, alignment: .leading)
                        TypeStreamPicker(model: model, type: type, selection: binding(type), catalog: catalog)
                            .frame(width: 200, alignment: .leading)
                        Spacer(minLength: 0)
                        LowerThirdPreview(
                            model: model, render: render, type: type,
                            stream: model.slideBuilding.screens(forType: type).livestream, catalog: catalog)
                            .frame(width: 176)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .task(id: model.version(of: .theme)) { catalog = await LowerThirdCatalog.load(model) }
    }

    private func binding(_ type: String) -> Binding<TypeStream> {
        Binding(
            get: { model.slideBuilding.screens(forType: type).livestream },
            set: { value in model.updateSlideBuilding { $0.updateScreens(forType: type) { $0.livestream = value } } })
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
            Text("Lower Thirds").font(.title3.weight(.semibold))
            ScreensByTypeForm(model: model, render: render)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
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
