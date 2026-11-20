import PresenterCore
import SwiftUI

/// Prism's mark, as on its app icon: a rounded triangle lit blue to pink.
struct PrismMark: View {
    var muted = false

    static let colors: [Color] = [
        Color(red: 0.36, green: 0.78, blue: 1.0),
        Color(red: 0.58, green: 0.42, blue: 1.0),
        Color(red: 1.0, green: 0.42, blue: 0.78),
    ]

    var body: some View {
        RoundedTriangle()
            .fill(muted
                  ? AnyShapeStyle(Color.secondary.opacity(0.7))
                  : AnyShapeStyle(LinearGradient(colors: Self.colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .aspectRatio(1.08, contentMode: .fit)
            .accessibilityHidden(true)
    }

    private struct RoundedTriangle: Shape {
        func path(in rect: CGRect) -> Path {
            let top = CGPoint(x: rect.midX, y: rect.minY)
            let right = CGPoint(x: rect.maxX, y: rect.maxY)
            let left = CGPoint(x: rect.minX, y: rect.maxY)
            let radius = min(rect.width, rect.height) * 0.2
            var path = Path()
            path.move(to: CGPoint(x: (left.x + right.x) / 2, y: rect.maxY))
            path.addArc(tangent1End: right, tangent2End: top, radius: radius)
            path.addArc(tangent1End: top, tangent2End: left, radius: radius)
            path.addArc(tangent1End: left, tangent2End: right, radius: radius)
            path.closeSubpath()
            return path
        }
    }
}

// MARK: The plan row's pill

/// The Prism scene a plan item leaves the lights on, at the row's end: the
/// mark and the scene's name. Bright when the item (or its first slide, or
/// a macro on it) names the scene; plain when it's the item's place in the
/// service; grey when that place doesn't go out because the lights don't
/// follow the service on this Mac.
struct PlanCuePill: View {
    let cue: PlanItemCue
    /// Prism's own name for a position's scene, when Prism is on this Mac.
    let positionName: (ServicePosition) -> String
    let follows: Bool

    var body: some View {
        let chosen = isChosen
        let off = !chosen && !follows
        HStack(spacing: 4) {
            PrismMark(muted: off).frame(width: 10, height: 9)
            // Cut short here rather than by layout, so the pill hugs its
            // name and a long scene name can't push the item's name out.
            Text(name.count > 14 ? String(name.prefix(13)) + "\u{2026}" : name)
                .font(.system(size: 10, weight: chosen ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(off ? AnyShapeStyle(.tertiary) : chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: 17)
        .fixedSize()
        .background {
            Capsule().fill(chosen
                ? AnyShapeStyle(LinearGradient(
                    colors: PrismMark.colors.map { $0.opacity(0.26) }, startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(Color.secondary.opacity(0.10)))
        }
        .overlay {
            if chosen { Capsule().strokeBorder(PrismMark.colors[1].opacity(0.45), lineWidth: 0.5) }
        }
        .help(help)
    }

    private var isChosen: Bool {
        if case .scene = cue { return true }
        return false
    }

    private var name: String {
        switch cue {
        case .scene(_, let name, _): name
        case .position(let position): positionName(position)
        }
    }

    private var help: String {
        switch cue {
        case .scene(_, let name, .item): "Prism: \(name), chosen for this item"
        case .scene(_, let name, .macro(let macro)): "Prism: \(name), from the macro \u{201C}\(macro)\u{201D}"
        case .scene(_, let name, .firstSlide): "Prism: \(name), from the first slide"
        case .position(let position) where follows: "Prism: \(positionName(position)), this item\u{2019}s place in the service"
        case .position(let position):
            "Prism: \(positionName(position)) would go out, but this Mac doesn\u{2019}t change Prism scenes with the service (Settings \u{203A} Prism & MIDI)"
        }
    }
}

extension ServiceLighting {
    /// What the pill shows for a plan item.
    static func cue(for item: ServiceItem, position: ServicePosition?, model: AppModel) -> PlanItemCue? {
        guard item.itemKind != .header else { return nil }
        var firstSlideActions: [SlideAction] = []
        if item.itemKind == .presentation, let deck = model.presentation(item.refId),
           let slide = PlanItemCue.firstSlide(of: deck, arrangementId: item.arrangementId) {
            firstSlideActions = slide.actions ?? []
        } else if item.itemKind == .media, let media = model.media(item.refId) {
            firstSlideActions = media.actions ?? []
        }
        return PlanItemCue.resolve(
            itemActions: item.actions ?? [], firstSlideActions: firstSlideActions, position: position,
            combo: { id in
                (try? model.actionCombo(id)).map { (model.entry(id)?.name ?? "Macro", $0.actions) }
            })
    }

    /// Prism's name for a position's scene (its cues carry the positions'
    /// keys as ids), else the position's own title.
    static func sceneName(for position: ServicePosition) -> String {
        PrismLink.shared.prismScenes.first { $0.id == position.key }?.name ?? position.title
    }
}

// MARK: The top bar's Prism cues

/// The top bar's Prism button: every scene as a chip to drag onto a plan
/// item. The item then cues that scene whenever it goes live, saved with
/// the plan.
struct PrismCuePalette: View {
    let model: AppModel
    @Bindable private var link = PrismLink.shared

    var body: some View {
        let scenes = link.sceneChoices(model)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PrismMark().frame(width: 15, height: 14)
                Text("Prism Cues").font(.headline)
                Spacer()
            }
            Text("Drag a cue onto a plan item. Prism goes to that scene when the item goes live.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(scenes) { scene in chip(scene) }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            if link.prismScenes.isEmpty {
                Text("Prism isn\u{2019}t on this Mac: these are the scenes it starts with.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text("Right-click a plan item \u{203A} Prism Cue to change or clear it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { link.loadScenes() }
    }

    @ViewBuilder
    private func chip(_ scene: PrismScene) -> some View {
        let usable = scene.note != nil
        HStack(spacing: 5) {
            PrismMark(muted: !usable).frame(width: 11, height: 10)
            Text(scene.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            Capsule().fill(LinearGradient(
                colors: PrismMark.colors.map { $0.opacity(usable ? 0.22 : 0.06) },
                startPoint: .leading, endPoint: .trailing)))
        .contentShape(Capsule())
        .foregroundStyle(usable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .help(usable ? "\(scene.name): note \(scene.note ?? 0). Drag onto a plan item." : "\(scene.name) has no note in Prism yet")
        .draggablePayload(usable ? PrismScenes.dragPayload(scene) : nil)
    }
}
