import CoreGraphics
import Foundation

public struct SceneTransition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case cut
        case dissolve

        case fade(SceneColor)

        case blurDissolve

        case filmBurn
    }

    public var kind: Kind
    public var duration: Double

    public init(kind: Kind, duration: Double = 0.5) {
        self.kind = kind
        self.duration = min(max(duration, 0.05), 10)
    }

    public static let cut = SceneTransition(kind: .cut, duration: 0.05)
}

public final class SceneTransitionEngine: @unchecked Sendable {
    private struct Active {
        var previous: RenderScene
        var startedAt: Date

        var transitions: [LayerKind: SceneTransition]

        var duration: Double
    }

    private struct State {
        var target: RenderScene
        var active: Active?
    }

    private let state: Locked<State>

    private let pullCount = Locked<Int>(0)

    public func telemetry(at date: Date = Date()) -> (pulls: Int, transition: String?) {
        let pulls = pullCount.value
        let description: String? = state.withLock { s in
            guard let active = s.active else { return nil }
            let progress = Self.progress(of: active, at: date)
            let kinds = active.transitions.values.map { "\($0.kind)" }.joined(separator: "+")
            return "\(kinds) \(Int(progress * 100))% over \(active.transitions.count) layer(s)"
        }
        return (pulls, description)
    }

    public init(initial: RenderScene = RenderScene()) {
        state = Locked(State(target: initial, active: nil))
    }

    /// When the transition under way finishes; nil when none is running.
    public func transitionEnd(after date: Date = Date()) -> Date? {
        state.withLock { s in
            guard let active = s.active else { return nil }
            let end = active.startedAt.addingTimeInterval(active.duration)
            return end > date ? end : nil
        }
    }

    public func heldMediaIDs(at date: Date = Date()) -> Set<String> {
        state.withLock { s in
            guard let active = s.active,
                  date.timeIntervalSince(active.startedAt) < active.duration
            else { return [] }
            var ids = Set<String>()
            for layer in active.previous.layers where active.transitions.keys.contains(layer.kind) {
                for item in layer.items {

                    if let id = item.content.mediaID { ids.insert(id) }
                }
            }
            return ids
        }
    }

    public func push(_ scene: RenderScene, transition: SceneTransition) {
        push(scene) { _ in transition }
    }

    public func push(_ scene: RenderScene, transitionFor: (LayerKind) -> SceneTransition?) {
        state.withLock { s in
            let scene = Self.settled(scene, after: s.target)
            let changed = Self.changedLayers(from: s.target, to: scene)

            guard !changed.isEmpty else {
                s.target = scene
                return
            }
            var transitions: [LayerKind: SceneTransition] = [:]
            for layer in changed {
                if let transition = transitionFor(layer), transition.kind != .cut {
                    transitions[layer] = transition
                }
            }
            guard !transitions.isEmpty else {
                s.target = scene

                s.active = nil
                return
            }

            let base = s.active.map { Self.composite(
                previous: $0.previous, target: s.target,
                transitions: $0.transitions,
                progress: Self.progress(of: $0, at: Date())
            ) } ?? s.target
            s.active = Active(
                previous: base, startedAt: Date(),
                transitions: transitions,
                duration: transitions.values.map(\.duration).max() ?? 0.05
            )
            s.target = scene
        }
    }

    public func scene(at date: Date) -> RenderScene {
        pullCount.withLock { $0 += 1 }
        return state.withLock { s in
            guard let active = s.active else { return s.target }
            let progress = Self.progress(of: active, at: date)
            if progress >= 1 {
                s.active = nil
                return s.target
            }
            return Self.composite(
                previous: active.previous, target: s.target,
                transitions: active.transitions, progress: progress
            )
        }
    }

    private static func progress(of active: Active, at date: Date) -> Double {
        min(max(date.timeIntervalSince(active.startedAt) / active.duration, 0), 1)
    }

    static func membershipKey(_ item: RenderItem) -> String {

        if let id = item.content.mediaID { return item.id + "|" + id }
        return item.id
    }

    static func changedLayers(from old: RenderScene, to new: RenderScene) -> Set<LayerKind> {
        var changed = Set<LayerKind>()
        for kind in LayerKind.allCases {
            let oldIDs = old.layers.first { $0.kind == kind }
                .map { Set($0.items.map(membershipKey)) } ?? []
            let newIDs = new.layers.first { $0.kind == kind }
                .map { Set($0.items.map(membershipKey)) } ?? []
            if oldIDs != newIDs { changed.insert(kind) }
        }
        return changed
    }

    static func composite(
        previous: RenderScene, target: RenderScene,
        transition: SceneTransition, progress: Double,
        layers: Set<LayerKind>
    ) -> RenderScene {
        composite(
            previous: previous, target: target,
            transitions: Dictionary(uniqueKeysWithValues: layers.map { ($0, transition) }),
            progress: progress
        )
    }

    static func composite(
        previous: RenderScene, target: RenderScene,
        transitions: [LayerKind: SceneTransition], progress: Double
    ) -> RenderScene {
        var scene = target
        for index in scene.layers.indices {
            let kind = scene.layers[index].kind
            guard let transition = transitions[kind] else { continue }
            let oldItems = previous.layers.first { $0.kind == kind }?.items ?? []
            let newItems = scene.layers[index].items

            // Text that is identical on both slides (same words, style and
            // place, such as a passage's reference across its slides) holds
            // still instead of dissolving into itself.
            let steady = steadyText(old: oldItems, new: newItems)
            // A box whose words partly change: its unchanged lines hold and
            // only the changed lines cross over.
            let reworded = transition.kind == .cut ? [] : rewordedText(
                old: oldItems.filter { !steady.leaving.contains(membershipKey($0)) },
                new: newItems.filter { !steady.arriving.contains(membershipKey($0)) })
            let oldKeys = Set(oldItems.map(membershipKey)).union(steady.arriving)
                .union(reworded.map { membershipKey($0.new) })
            let newKeys = Set(newItems.map(membershipKey)).union(steady.leaving)
                .union(reworded.map { membershipKey($0.old) })

            let leaving = oldItems.filter { !newKeys.contains(membershipKey($0)) }
                .map { item in
                    var out = item
                    out.id += "::leaving"
                    return out
                }
            func arrivingFaded(_ items: [RenderItem], to opacity: Double) -> [RenderItem] {
                items.map { item in
                    guard !oldKeys.contains(membershipKey(item)) else { return item }
                    var out = item
                    out.opacity *= opacity
                    return out
                }
            }

            let hasArrivals = newItems.contains { !oldKeys.contains(membershipKey($0)) }
            let holdsUnder = hasArrivals
                && (kind == .loopingVideos || kind == .stillGraphics || kind == .videos)
            switch transition.kind {
            case .cut:
                continue
            case .dissolve:
                scene.layers[index].items =
                    (holdsUnder ? leaving : faded(leaving, to: 1 - progress))
                    + lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress)
            case .fade(let plate):

                let firstHalf = progress < 0.5
                let plateOpacity = firstHalf ? progress * 2 : (1 - progress) * 2
                var items = firstHalf ? oldItems : newItems
                items.append(RenderItem(
                    id: "transition-plate-\(kind.rawValue)",
                    frame: CGRect(origin: .zero, size: scene.canvasSize),
                    content: .solid(SceneColor(
                        red: plate.red, green: plate.green, blue: plate.blue,
                        alpha: plateOpacity
                    ))
                ))
                scene.layers[index].items = items
            case .blurDissolve:

                let swell = (1 - abs(progress * 2 - 1)) * 60
                scene.layers[index].items =
                    blurred(holdsUnder ? leaving : faded(leaving, to: 1 - progress), radius: swell)
                    + lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress)
            case .filmBurn:

                let peak = 1 - abs(progress * 2 - 1)
                let leaving = burned(faded(leaving, to: 1 - progress), amount: peak, phase: progress)
                let arriving = burned(
                    lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress),
                    amount: peak, phase: progress)
                var items = leaving + arriving
                items.append(RenderItem(
                    id: "transition-plate-\(kind.rawValue)",
                    frame: CGRect(origin: .zero, size: scene.canvasSize),
                    content: .solid(SceneColor(red: 1, green: 0.72, blue: 0.42, alpha: peak * 0.35))
                ))
                scene.layers[index].items = items
            }
        }
        return scene
    }

    /// An item without its timing: when its slide fired and its build
    /// steps differ slide to slide even when it looks exactly the same.
    static func untimed(_ item: RenderItem) -> RenderItem {
        var copy = item
        copy.animationSteps = []
        copy.animationContext = nil
        copy.tickerAnchorHostTime = nil
        return copy
    }

    /// The same text box with the same look, whatever it says.
    private static func sameBox(_ old: RenderItem, _ new: RenderItem) -> Bool {
        guard case .text(var oldText) = old.content, case .text(let newText) = new.content else { return false }
        oldText.string = newText.string
        oldText.styleRuns = newText.styleRuns
        var probe = untimed(old)
        probe.id = new.id
        probe.content = .text(oldText)
        return probe == untimed(new)
    }

    private static func sameLook(_ old: RenderItem, _ new: RenderItem) -> Bool {
        var probe = untimed(old)
        probe.id = new.id
        return probe == untimed(new)
    }

    /// Keys of text items on the incoming slide that match an outgoing text
    /// item in everything but id and timing, and the keys of those outgoing items.
    static func steadyText(old: [RenderItem], new: [RenderItem]) -> (arriving: Set<String>, leaving: Set<String>) {
        let oldKeys = Set(old.map(membershipKey))
        var unmatched = old.filter { item in
            if case .text = item.content { return !new.contains { $0.id == item.id } }
            return false
        }
        var arriving = Set<String>(), leaving = Set<String>()
        for item in new where !oldKeys.contains(membershipKey(item)) {
            guard case .text = item.content else { continue }
            if let index = unmatched.firstIndex(where: { sameLook($0, item) }) {
                arriving.insert(membershipKey(item))
                leaving.insert(membershipKey(unmatched[index]))
                unmatched.remove(at: index)
            }
        }
        return (arriving, leaving)
    }

    /// A text box on both slides whose words changed, with which of its
    /// lines read the same in the same place on both.
    struct Reworded {
        var old: RenderItem
        var new: RenderItem
        var oldSteady: [TextRasterizer.LaidOutLine]
        var newSteady: [TextRasterizer.LaidOutLine]
        var oldChanged: [TextRasterizer.LaidOutLine]
        var newChanged: [TextRasterizer.LaidOutLine]
    }

    static func rewordedText(old: [RenderItem], new: [RenderItem]) -> [Reworded] {
        let oldIDs = Set(old.map(\.id))
        var pool = old.filter { item in
            if case .text = item.content { return !new.contains { $0.id == item.id } }
            return false
        }
        var result: [Reworded] = []
        for item in new where !oldIDs.contains(item.id) {
            guard case .text(let newText) = item.content,
                  let index = pool.firstIndex(where: { sameBox($0, item) }),
                  case .text(let oldText) = pool[index].content,
                  let oldLines = TextRasterizer.laidOutLines(for: oldText, sceneFrame: pool[index].frame.size),
                  let newLines = TextRasterizer.laidOutLines(for: newText, sceneFrame: item.frame.size)
            else { continue }
            var unmatchedOld = oldLines
            var newSteady: [TextRasterizer.LaidOutLine] = [], oldSteady: [TextRasterizer.LaidOutLine] = []
            var newChanged: [TextRasterizer.LaidOutLine] = []
            for line in newLines {
                if !line.text.isEmpty, let match = unmatchedOld.firstIndex(where: {
                    $0.text == line.text && $0.fontScale == line.fontScale
                        && abs($0.origin.x - line.origin.x) < 0.5 && abs($0.origin.y - line.origin.y) < 0.5
                }) {
                    newSteady.append(line)
                    oldSteady.append(unmatchedOld.remove(at: match))
                } else {
                    newChanged.append(line)
                }
            }
            guard !newSteady.isEmpty else { continue }
            result.append(Reworded(
                old: pool[index], new: item, oldSteady: oldSteady, newSteady: newSteady,
                oldChanged: unmatchedOld, newChanged: newChanged))
            pool.remove(at: index)
        }
        return result
    }

    /// Replaces each reworded box with its steady lines at full strength,
    /// its new lines fading in and its old lines fading out, all drawn from
    /// the same layout so nothing shifts.
    static func lineDissolved(_ items: [RenderItem], _ reworded: [Reworded], progress: Double) -> [RenderItem] {
        guard !reworded.isEmpty else { return items }
        let byID = Dictionary(reworded.map { ($0.new.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [RenderItem] = []
        for item in items {
            guard let pair = byID[item.id] else {
                result.append(item)
                continue
            }
            var steady = pair.new
            steady.content = hiding(pair.newChanged, in: pair.new.content)
            var arriving = pair.new
            arriving.id += "::changed"
            arriving.opacity *= progress
            arriving.content = hiding(pair.newSteady, in: pair.new.content)
            var leaving = pair.old
            leaving.id += "::leaving"
            leaving.opacity *= 1 - progress
            leaving.content = hiding(pair.oldSteady, in: pair.old.content)
            result += [leaving, steady, arriving]
        }
        return result
    }

    private static func hiding(_ lines: [TextRasterizer.LaidOutLine], in content: ItemContent) -> ItemContent {
        guard case .text(var text) = content else { return content }
        for line in lines where line.length > 0 {
            text.styleRuns.append(StyleRun(line: line.paragraph, column: line.column, length: line.length, hidden: true))
        }
        return .text(text)
    }

    /// The incoming scene, with text that carries over from the outgoing one
    /// keeping its timing, so a theme's build-in doesn't replay on words
    /// already on screen.
    static func settled(_ scene: RenderScene, after previous: RenderScene) -> RenderScene {
        var scene = scene
        for index in scene.layers.indices {
            let kind = scene.layers[index].kind
            let oldItems = previous.layers.first { $0.kind == kind }?.items ?? []
            let newItems = scene.layers[index].items
            let oldIDs = Set(oldItems.map(\.id))
            var pool = oldItems.filter { item in
                if case .text = item.content { return !newItems.contains { $0.id == item.id } }
                return false
            }
            for itemIndex in newItems.indices where !oldIDs.contains(newItems[itemIndex].id) {
                let item = newItems[itemIndex]
                guard case .text = item.content,
                      let match = pool.firstIndex(where: { sameLook($0, item) })
                        ?? pool.firstIndex(where: { sameBox($0, item) })
                else { continue }
                let old = pool.remove(at: match)
                guard sameLook(old, item) || hasSteadyLine(old, item) else { continue }
                scene.layers[index].items[itemIndex].animationSteps = old.animationSteps
                // Carried-over text stays up: the outgoing slide's exit or
                // dismiss never applies to it.
                var context = old.animationContext
                context?.exitHostTime = nil
                context?.dismissHostTime = nil
                scene.layers[index].items[itemIndex].animationContext = context
                scene.layers[index].items[itemIndex].tickerAnchorHostTime = old.tickerAnchorHostTime
            }
        }
        return scene
    }

    private static func hasSteadyLine(_ old: RenderItem, _ new: RenderItem) -> Bool {
        !rewordedText(old: [old], new: [new]).isEmpty
    }

    private static func faded(_ items: [RenderItem], to opacity: Double) -> [RenderItem] {
        items.map { item in
            var out = item
            out.opacity *= opacity
            return out
        }
    }

    private static func burned(_ items: [RenderItem], amount: Double, phase: Double) -> [RenderItem] {
        guard amount > 0.01 else { return items }
        return items.map { item in
            var out = item
            out.effects = [SceneEffect(kind: .burn(amount: amount, phase: phase))] + out.effects
            return out
        }
    }

    private static func blurred(_ items: [RenderItem], radius: Double) -> [RenderItem] {
        guard radius > 0.5 else { return items }
        return items.map { item in
            var out = item
            out.effects = [SceneEffect(kind: .blur(radius: radius))] + out.effects
            return out
        }
    }
}
