import Foundation

/// A scene in Prism, the church's lighting app, as a slide's right-click ›
/// Prism lists it.
public struct PrismScene: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The MIDI note Prism fires this scene on. A scene without one can't
    /// be reached from Screens until it's given one in Prism.
    public var note: Int?

    public init(id: String, name: String, note: Int?) {
        self.id = id
        self.name = name
        self.note = note
    }
}

/// Prism's scenes and the slide actions that cue them.
///
/// Prism listens to Screens by MIDI note: a slide that cues a scene sends
/// that scene's note when it goes live. The action keeps the scene's id and
/// name as well as the note, so a scene whose note is changed in Prism
/// still fires, and a Mac without Prism still shows which scene it is.
public enum PrismScenes {
    /// A MIDI Out action aimed at Prism carries this as its device.
    public static let deviceID = "prism"
    /// The device id slides saved before Prism replaced the old lighting
    /// app still carry. Those actions go to Prism too.
    public static let olderDeviceID = "lightkey"

    /// Where Prism keeps its show on this Mac (its Application Support
    /// folder), relative to the user's Library.
    public static func showURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Prism", isDirectory: true)
            .appendingPathComponent("Show.json")
    }

    /// The scenes in a Prism show file, in Prism's order. Nil when the data
    /// isn't a Prism show.
    public static func scenes(fromShow data: Data) -> [PrismScene]? {
        struct Show: Decodable {
            struct Cue: Decodable {
                var id: String
                var name: String
                var note: Int?
            }
            var cues: [Cue]
        }
        guard let show = try? JSONDecoder().decode(Show.self, from: data) else { return nil }
        return show.cues.map { PrismScene(id: $0.id, name: $0.name, note: $0.note) }
    }

    /// The scenes Prism has by default, from the church's cue table: what a
    /// Mac without Prism offers. Prism's own cues for the service positions
    /// carry the positions' keys as their ids, so these match them.
    public static func scenes(fromCueTable table: [LightingCue]) -> [PrismScene] {
        table.map { row in
            PrismScene(id: row.position, name: ServicePosition(key: row.position)?.title ?? row.position, note: row.note)
        }
    }

    public static func isPrism(_ action: SlideAction) -> Bool {
        action.kind == .midiOut && (action.midiDeviceId == deviceID || action.midiDeviceId == olderDeviceID)
    }

    /// The action that cues `scene`. The channel is left to Settings, so
    /// changing it there moves every slide's cue with it.
    public static func action(for scene: PrismScene, id: String = UUID().uuidString) -> SlideAction {
        SlideAction(
            id: id, kind: .midiOut,
            midiKind: .noteOn, midiNumber: scene.note, midiValue: 127, midiDeviceId: deviceID,
            prismCueId: scene.id, prismCueName: scene.name)
    }

    /// The scene a slide cues, if it cues one.
    public static func cue(on slide: Slide) -> SlideAction? {
        slide.actions?.first(where: isPrism)
    }

    /// The slide cueing `scene` instead of whatever it cued before; nil
    /// takes its cue off. A slide cues one scene at most: two would fire
    /// one after the other and leave the room on whichever came last.
    public static func setting(_ scene: PrismScene?, on slide: Slide, actionID: String = UUID().uuidString) -> Slide {
        var slide = slide
        var actions = (slide.actions ?? []).filter { !isPrism($0) }
        if let scene { actions.append(action(for: scene, id: actionID)) }
        slide.actions = actions.isEmpty ? nil : actions
        return slide
    }

    /// The note to send for a Prism action: its scene's note in Prism now,
    /// when the scene is known, else the note it was saved with.
    public static func note(for action: SlideAction, scenes: [PrismScene]) -> Int? {
        if let id = action.prismCueId, let scene = scenes.first(where: { $0.id == id }) {
            return scene.note
        }
        return action.midiNumber
    }

    /// What the slide's action list calls a Prism action.
    public static func label(for action: SlideAction) -> String {
        if let name = action.prismCueName, !name.isEmpty { return "Prism: \(name)" }
        return "Prism: note \(action.midiNumber ?? 0)"
    }

    /// Whether a list of actions (macros included) already cues Prism. Then
    /// it is the scene the operator chose, and the item's position cue
    /// stays quiet rather than flashing one scene before the other.
    public static func cuesPrism(
        _ actions: [SlideAction],
        combo: (String) -> [SlideAction]?, depth: Int = 0, visited: Set<String> = []
    ) -> Bool {
        guard depth < 8 else { return false }
        for action in actions {
            if isPrism(action) { return true }
            guard action.kind == .fireCombo, let id = action.comboId,
                  !visited.contains(id), let inner = combo(id) else { continue }
            if cuesPrism(inner, combo: combo, depth: depth + 1, visited: visited.union([id])) {
                return true
            }
        }
        return false
    }
}
