import Foundation

/// The Prism scene a plan item leaves the room on when it goes live, for the
/// cue pill on its row.
///
/// Worked out in the order things land, so the pill names the scene the
/// lights end up on: the item's own cue and its macros go first, then the
/// first slide's own actions, so a scene on the first slide is the one that
/// stays. With none of those, the item's place in the service (Song 2,
/// Message…) goes out, and only on a Mac where the lights follow the
/// service.
public enum PlanItemCue: Equatable, Sendable {
    /// A scene cued by name.
    case scene(id: String?, name: String, from: Source)
    /// The item's place in the service, sent as its note in the cue table.
    case position(ServicePosition)

    public enum Source: Equatable, Sendable {
        /// Dropped on the item, or picked in its right-click › Prism Cue.
        case item
        /// A macro on the item cues it; the macro's name.
        case macro(String)
        /// The presentation's first slide cues it itself.
        case firstSlide
    }

    /// `combo` gives a macro's name and actions by id.
    public static func resolve(
        itemActions: [SlideAction], firstSlideActions: [SlideAction], position: ServicePosition?,
        combo: (String) -> (name: String, actions: [SlideAction])?
    ) -> PlanItemCue? {
        if let action = firstSlideActions.first(where: PrismScenes.isPrism) {
            return scene(action, from: .firstSlide)
        }
        // Run in order, the last one is what the lights stay on.
        var found: PlanItemCue?
        for action in itemActions {
            if PrismScenes.isPrism(action) {
                found = scene(action, from: .item)
            } else if action.kind == .fireCombo, let id = action.comboId, let macro = combo(id),
                      let inner = PrismScenes.lastCue(in: macro.actions, combo: { combo($0)?.actions }) {
                found = scene(inner, from: .macro(macro.name))
            }
        }
        if let found { return found }
        return position.map(PlanItemCue.position)
    }

    private static func scene(_ action: SlideAction, from source: Source) -> PlanItemCue {
        let name = action.prismCueName.flatMap { $0.isEmpty ? nil : $0 } ?? "Note \(action.midiNumber ?? 0)"
        return .scene(id: action.prismCueId, name: name, from: source)
    }

    /// The slide that goes up first for this item: its arrangement's first
    /// section's first slide, else the deck's first.
    public static func firstSlide(of presentation: Presentation, arrangementId: String?) -> Slide? {
        if let id = arrangementId, !id.isEmpty,
           let arrangement = presentation.arrangements?.first(where: { $0.id == id }) {
            for section in arrangement.sectionIds {
                if let slide = presentation.slides.first(where: { $0.sectionId == section }) { return slide }
            }
        }
        return presentation.slides.first
    }
}

extension PrismScenes {
    /// Dragged from the top bar's Prism cues onto a plan item.
    public static let dragPrefix = "prism-scene::"

    public static func dragPayload(_ scene: PrismScene) -> String { dragPrefix + scene.id }

    public static func draggedSceneID(_ payload: String?) -> String? {
        guard let payload, payload.hasPrefix(dragPrefix) else { return nil }
        let id = String(payload.dropFirst(dragPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// A plan item's actions cueing `scene` instead of the scene it cued
    /// itself before; nil takes its own cue off. Its macros stay.
    public static func settingItemScene(
        _ scene: PrismScene?, in actions: [SlideAction]?, actionID: String = UUID().uuidString
    ) -> [SlideAction]? {
        var kept = (actions ?? []).filter { !isPrism($0) }
        if let scene { kept.append(action(for: scene, id: actionID)) }
        return kept.isEmpty ? nil : kept
    }

    /// The Prism action that lands last in a list, macros inside it included.
    public static func lastCue(
        in actions: [SlideAction], combo: (String) -> [SlideAction]?, depth: Int = 0, visited: Set<String> = []
    ) -> SlideAction? {
        guard depth < 8 else { return nil }
        var found: SlideAction?
        for action in actions {
            if isPrism(action) {
                found = action
            } else if action.kind == .fireCombo, let id = action.comboId, !visited.contains(id),
                      let inner = combo(id),
                      let cue = lastCue(in: inner, combo: combo, depth: depth + 1, visited: visited.union([id])) {
                found = cue
            }
        }
        return found
    }
}
