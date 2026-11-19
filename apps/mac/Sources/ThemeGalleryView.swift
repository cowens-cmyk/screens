import PresenterCore
import SwiftUI

/// The top bar's Theme button: every theme on one page as a thumbnail.
/// WIDE themes (the room's screens) are split into Worship, Message and
/// Misc; LOWER THIRDS (the livestream's) come after. Each wide theme shows
/// the lower-third theme it is paired with: pick one from its menu, or drag
/// a lower third onto it. Click a theme to open it in the theme editor.
struct ThemeGalleryView: View {
    let model: AppModel
    let render: RenderContext?
    /// The open plan's series theme, marked "This plan".
    let planThemeID: String?
    let open: (String) -> Void
    let newTheme: () -> Void
    let newFromImage: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var looks: [ThemeLook]?
    @State private var dropTarget: String?

    private static let dragPrefix = "screens-theme::"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let looks {
                if looks.isEmpty {
                    ContentUnavailableView(
                        "No Themes", systemImage: "paintpalette",
                        description: Text("Make one with + or from an image."))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView { sections(looks).padding(14) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 620)
        .task(id: model.entries(of: .theme).map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)" }) {
            looks = await ThemeLook.load(model, firstThemeId: planThemeID ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Themes").font(.headline)
            Spacer()
            Button("From Image\u{2026}", systemImage: "photo") { dismiss(); newFromImage() }
                .help("Make a theme from a picture")
            Button("New Theme", systemImage: "plus") { dismiss(); newTheme() }
                .help("New Theme")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func sections(_ looks: [ThemeLook]) -> some View {
        let worship = model.slideBuilding.lyricsImportThemeId
        let grouped = ThemeGallery.grouped(looks.map(\.theme), worshipThemeId: worship)
        let wide = grouped.filter { $0.group.isWide }
        let lowerThirds = grouped.first { $0.group == .lowerThirds }?.themes ?? []
        return VStack(alignment: .leading, spacing: 18) {
            if !wide.isEmpty {
                bigTitle("WIDE")
                ForEach(wide, id: \.group) { entry in
                    smallTitle(entry.group.title)
                    grid {
                        ForEach(entry.themes, id: \.id) { theme in
                            if let look = look(theme.id, in: looks) { wideCard(look, lowerThirds: lowerThirds) }
                        }
                    }
                }
            }
            bigTitle("LOWER THIRDS")
            if lowerThirds.isEmpty {
                Text("No lower-third themes yet. Right-click a theme \u{203A} Show Under \u{203A} Lower Thirds, or make one with +.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                grid {
                    ForEach(lowerThirds, id: \.id) { theme in
                        if let look = look(theme.id, in: looks) { lowerThirdCard(look) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cards

    private func wideCard(_ look: ThemeLook, lowerThirds: [Theme]) -> some View {
        let pairedID = look.theme.streamLowerThirdThemeId ?? ""
        let paired = lowerThirds.first { $0.id == pairedID }
            ?? (pairedID.isEmpty ? nil : model.theme(pairedID))
        return VStack(alignment: .leading, spacing: 3) {
            thumbnail(look)
                .overlay {
                    if dropTarget == look.theme.id {
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(Self.draggedTheme) else { return false }
                    pair(look.theme.id, with: id)
                    return true
                } isTargeted: { dropTarget = $0 ? look.theme.id : (dropTarget == look.theme.id ? nil : dropTarget) }
            Text(look.theme.name).font(.callout).lineLimit(1)
            Menu {
                Button((pairedID.isEmpty ? "\u{2713} " : "") + "Its Own Lower Thirds") { pair(look.theme.id, with: nil) }
                if !lowerThirds.isEmpty { Divider() }
                ForEach(lowerThirds, id: \.id) { lower in
                    Button((lower.id == pairedID ? "\u{2713} " : "") + lower.name) { pair(look.theme.id, with: lower.id) }
                }
            } label: {
                Label(paired?.name ?? "Its own lower thirds", systemImage: "rectangle.bottomthird.inset.filled")
                    .font(.caption2)
                    .foregroundStyle(paired == nil ? .secondary : Color.accentColor)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The lower thirds the livestream uses with this theme")
        }
        .contextMenu { themeMenu(look.theme) }
    }

    private func lowerThirdCard(_ look: ThemeLook) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            thumbnail(look)
                .draggable(Self.dragPrefix + look.theme.id)
            Text(look.theme.name).font(.callout).lineLimit(1)
            let users = (looks ?? []).filter { $0.theme.streamLowerThirdThemeId == look.theme.id }.map(\.theme.name)
            Text(users.isEmpty ? "Drag onto a wide theme to pair" : "With " + users.joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .contextMenu { themeMenu(look.theme) }
    }

    private func thumbnail(_ look: ThemeLook) -> some View {
        Button { dismiss(); open(look.theme.id) } label: {
            Group {
                if let design = ThemeGallery.coverDesign(of: look.theme), let slide = look.previews[design.id] {
                    SlideThumbnailView(
                        model: model, render: render,
                        slide: slide, presentation: look.deck, theme: look.theme,
                        arrangementId: nil, hideScopedBackgrounds: false, legibleText: false,
                        contentStamp: look.stamp)
                } else {
                    Color.secondary.opacity(0.12)
                        .overlay { Image(systemName: "paintpalette").foregroundStyle(.tertiary) }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if look.theme.id == planThemeID {
                    Text("This plan")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit \u{201C}\(look.theme.name)\u{201D}")
    }

    @ViewBuilder
    private func themeMenu(_ theme: Theme) -> some View {
        Button("Edit Theme") { dismiss(); open(theme.id) }
        let current = ThemeGallery.group(of: theme, worshipThemeId: model.slideBuilding.lyricsImportThemeId)
        Menu("Show Under") {
            ForEach(ThemeGallery.Group.allCases, id: \.self) { group in
                Button((group == current ? "\u{2713} " : "") + group.title) {
                    model.updateTheme(theme.id) { $0.galleryGroup = group.rawValue }
                }
            }
        }
    }

    // MARK: Helpers

    private func pair(_ wideID: String, with lowerID: String?) {
        guard wideID != lowerID else { return }
        model.updateTheme(wideID) { $0.streamLowerThirdThemeId = lowerID }
        DiagnosticsStore.shared.note("theme.paired", detail: "\(wideID) -> \(lowerID ?? "own")")
    }

    private static func draggedTheme(_ payload: String) -> String? {
        payload.hasPrefix(dragPrefix) ? String(payload.dropFirst(dragPrefix.count)) : nil
    }

    private func look(_ id: String, in looks: [ThemeLook]) -> ThemeLook? {
        looks.first { $0.theme.id == id }
    }

    private func bigTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
    }

    private func smallTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
    }

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)],
                  alignment: .leading, spacing: 16) {
            content()
        }
    }
}
