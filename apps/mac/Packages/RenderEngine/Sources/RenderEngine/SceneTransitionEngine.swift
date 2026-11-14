import CoreGraphics
import Foundation

public struct SceneTransition: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case cut
        case dissolve

        case fade(SceneColor)

        case blurDissolve

        case filmBurn

        /// A dissolve that never thins what both pictures cover: the
        /// incoming pictures, shapes and fills fade up over the outgoing
        /// ones, which stay at full strength, in the first half; then the
        /// outgoing ones fade away under them in the second. A plain
        /// dissolve has each at half strength halfway through, which over a
        /// camera (a keyed lower third) lets the camera show through both.
        /// Text crosses as in a plain dissolve. See
        /// `push(_:streamDissolve:otherwise:)`.
        case heldDissolve
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
    /// One layer's transition. Each layer keeps its own, on its own clock:
    /// a slide fire changes the words and then, a few milliseconds later,
    /// the slide's background or media cue, and that second change must
    /// not cut short the words' dissolve (nor restart it).
    private struct Active {
        var previous: RenderScene
        var startedAt: Date
        var transition: SceneTransition
        /// The media layers changed by one push share it, so a video
        /// leaving one layer and a picture arriving on another cross on
        /// the same clock.
        var group: Int
        /// Media arriving with this change that has no picture yet. Until
        /// it has one (or `startedAt`, the latest the change may wait,
        /// comes) the layer shows what it showed before: a video takes a
        /// moment to open, and a dissolve run on its clock alone would be
        /// over before the first frame came, so the old picture would go
        /// to black and the new one pop in.
        var awaiting: Set<String> = []

        var end: Date { startedAt.addingTimeInterval(transition.duration) }
    }

    private struct State {
        var target: RenderScene
        var active: [LayerKind: Active] = [:]
        var groups = 0
    }

    private let state: Locked<State>

    private let pullCount = Locked<Int>(0)

    /// Whether a media id has a picture to show yet. Without one, changes
    /// start at once.
    private let mediaReady = Locked<(@Sendable (String) -> Bool)?>(nil)

    /// The longest a media change waits for its incoming picture before
    /// it dissolves anyway.
    public static let longestMediaWait: TimeInterval = 1.0

    /// The layers that carry full-frame media: a slide's background or
    /// video, and media cues.
    static let mediaLayers: Set<LayerKind> = [.loopingVideos, .stillGraphics, .videos]

    public func telemetry(at date: Date = Date()) -> (pulls: Int, transition: String?) {
        let pulls = pullCount.value
        let description: String? = state.withLock { s in
            let running = s.active.filter { $0.value.end > date }
            guard !running.isEmpty else { return nil }
            return running.sorted { $0.key.rawValue < $1.key.rawValue }.map { layer, active in
                "\(active.transition.kind) \(Int(Self.progress(of: active, at: date) * 100))% on \(layer.rawValue)"
            }.joined(separator: ", ")
        }
        return (pulls, description)
    }

    public init(initial: RenderScene = RenderScene(), mediaReady: (@Sendable (String) -> Bool)? = nil) {
        state = Locked(State(target: initial))
        self.mediaReady.value = mediaReady
    }

    public func setMediaReady(_ ready: (@Sendable (String) -> Bool)?) {
        mediaReady.value = ready
    }

    /// The transition a layer is in at `date`, nil when it isn't in one.
    public func transition(on layer: LayerKind, at date: Date = Date()) -> SceneTransition? {
        state.withLock { s in
            guard let active = s.active[layer], active.end > date else { return nil }
            return active.transition
        }
    }

    /// When the transitions under way finish; nil when none is running.
    public func transitionEnd(after date: Date = Date()) -> Date? {
        state.withLock { s in
            guard let end = s.active.values.map(\.end).max(), end > date else { return nil }
            return end
        }
    }

    public func heldMediaIDs(at date: Date = Date()) -> Set<String> {
        Set(heldMedia(at: date).keys)
    }

    /// The outgoing media still on screen in a transition, each with how
    /// long that transition runs, so its sound can fade out with it.
    public func heldMedia(at date: Date = Date()) -> [String: TimeInterval] {
        state.withLock { s in
            var held: [String: TimeInterval] = [:]
            for (kind, active) in s.active where active.end > date {
                for item in active.previous.layers.first(where: { $0.kind == kind })?.items ?? [] {
                    if let id = item.content.mediaID {
                        held[id] = max(held[id] ?? 0, active.transition.duration)
                    }
                }
            }
            return held
        }
    }

    public func push(_ scene: RenderScene, transition: SceneTransition) {
        push(scene) { _ in transition }
    }

    public func push(_ scene: RenderScene, transitionFor: (LayerKind) -> SceneTransition?) {
        let ready = mediaReady.value
        state.withLock { s in
            let now = Date()
            let scene = Self.settled(scene, after: s.target)
            let changed = Self.changedLayers(from: s.target, to: scene)

            guard !changed.isEmpty else {
                s.target = scene
                return
            }
            // What the screens show this moment, so a layer that changes
            // again mid-transition carries on from where it is.
            let showing = Self.current(s, at: now)
            s.groups += 1
            // The new full-frame media without a picture yet, cut or not: a
            // background that cut in before its first frame would show
            // nothing, and one that waited alone would come up after the
            // words. Media an earlier change is still waiting for, and that
            // this one keeps, is still waited for (a second click inside the
            // wait doesn't put the background up before it has a picture).
            var awaiting = Set<String>()
            var latest = now.addingTimeInterval(Self.longestMediaWait)
            if ready != nil {
                for layer in changed where Self.waitsForMedia(layer, transitionFor(layer)) {
                    awaiting.formUnion(Self.arrivingMediaIDs(on: layer, from: showing, to: scene))
                }
                let kept = Set(scene.layers.flatMap { $0.items.compactMap(\.content.mediaID) })
                for active in s.active.values where !active.awaiting.isEmpty && active.startedAt > now {
                    let still = active.awaiting.intersection(kept)
                    if !still.isEmpty {
                        awaiting.formUnion(still)
                        latest = min(latest, active.startedAt)
                    }
                }
            }
            // Every layer this change touches waits with it, the words as
            // much as the background: the slide goes up whole, on one clock,
            // once its media has a picture (or `latest` comes, so a file that
            // never opens can't hold the screens). Until then the screens
            // keep what they showed.
            for layer in changed {
                let transition = transitionFor(layer)
                if let transition, transition.kind != .cut {
                    var active = Active(
                        previous: showing, startedAt: now, transition: transition, group: s.groups)
                    if !awaiting.isEmpty {
                        active.awaiting = awaiting
                        active.startedAt = latest
                    }
                    s.active[layer] = active
                } else if !awaiting.isEmpty {
                    var active = Active(previous: showing, startedAt: latest, transition: .cut, group: s.groups)
                    active.awaiting = awaiting
                    s.active[layer] = active
                } else {
                    s.active[layer] = nil
                }
            }
            s.target = scene
        }
        if let ready { startReady(ready, at: Date()) }
    }

    /// Whether the media arriving on `layer` is what a change waits for:
    /// the full-frame media layers always, cut or not, and the slide layer
    /// when it changes with a held dissolve (a lower-third picture on the
    /// livestream's copy), since holding the old one up until the new one
    /// can cover it is the point of it. Every layer the change touches then
    /// waits on that one set, on one clock.
    static func waitsForMedia(_ layer: LayerKind, _ transition: SceneTransition?) -> Bool {
        mediaLayers.contains(layer) || transition?.kind == .heldDissolve
    }

    /// The livestream's push. Its slide layer is what goes over the camera
    /// (a lower-third design, or a slide's lower-third picture, in place of
    /// the slide). When one lower third follows another the slide layer
    /// changes with a held dissolve of `streamDissolve` seconds (a cut at 0),
    /// whatever the room's slide transition is. A lower third arriving over
    /// a clear camera, or leaving it clear, and every other layer, keep
    /// `otherwise`, as the room's do.
    public func push(
        _ scene: RenderScene, streamDissolve: Double,
        otherwise transitionFor: (LayerKind) -> SceneTransition?
    ) {
        let before = state.withLock { $0.target }
        let crossing = Self.showsSomething(.slide, in: before) && Self.showsSomething(.slide, in: scene)
        let held: SceneTransition = streamDissolve < 0.05
            ? .cut : SceneTransition(kind: .heldDissolve, duration: streamDissolve)
        push(scene) { layer in
            layer == .slide && crossing ? held : transitionFor(layer)
        }
    }

    /// Whether a layer has anything on it that isn't hidden or see-through.
    static func showsSomething(_ kind: LayerKind, in scene: RenderScene) -> Bool {
        guard let layer = scene.layers.first(where: { $0.kind == kind }), !layer.isHidden else { return false }
        return layer.items.contains { $0.opacity > 0.001 }
    }

    public func scene(at date: Date) -> RenderScene {
        pullCount.withLock { $0 += 1 }
        if let ready = mediaReady.value { startReady(ready, at: date) }
        return state.withLock { s in
            s.active = s.active.filter { $0.value.end > date }
            return Self.current(s, at: date)
        }
    }

    /// Starts each change whose incoming media now has a picture. Asked
    /// outside the lock: the media engine has locks of its own.
    private func startReady(_ ready: (String) -> Bool, at date: Date) {
        let waiting = state.withLock { s in
            s.active.values.reduce(into: [Int: Set<String>]()) { groups, active in
                guard !active.awaiting.isEmpty, active.startedAt > date else { return }
                groups[active.group, default: []].formUnion(active.awaiting)
            }
        }
        guard !waiting.isEmpty else { return }
        let landed = Set(waiting.filter { $0.value.allSatisfy(ready) }.keys)
        guard !landed.isEmpty else { return }
        state.withLock { s in
            for (kind, active) in s.active where landed.contains(active.group) && !active.awaiting.isEmpty {
                s.active[kind]?.awaiting = []
                s.active[kind]?.startedAt = min(active.startedAt, date)
            }
        }
    }

    /// Media ids on a layer of `new` that `old` doesn't have there.
    static func arrivingMediaIDs(on kind: LayerKind, from old: RenderScene, to new: RenderScene) -> Set<String> {
        let oldIDs = Set((old.layers.first { $0.kind == kind }?.items ?? []).compactMap(\.content.mediaID))
        let newIDs = Set((new.layers.first { $0.kind == kind }?.items ?? []).compactMap(\.content.mediaID))
        return newIDs.subtracting(oldIDs)
    }

    /// The target, with each layer still in its transition drawn partway.
    private static func current(_ s: State, at date: Date) -> RenderScene {
        var scene = s.target
        let order = Dictionary(
            s.target.layers.enumerated().map { ($0.element.kind, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        for (kind, active) in s.active {
            // A cut waiting for its media shows the layer as it was.
            if active.transition.kind == .cut {
                guard !active.awaiting.isEmpty, date < active.startedAt else { continue }
                let held = active.previous.layers.first { $0.kind == kind }?.items ?? []
                if let index = scene.layers.firstIndex(where: { $0.kind == kind }) {
                    scene.layers[index].items = held
                } else if !held.isEmpty {
                    for item in held { scene.addItem(item, to: kind) }
                }
                continue
            }
            let progress = progress(of: active, at: date)
            guard progress < 1,
                  let index = scene.layers.firstIndex(where: { $0.kind == kind }) else { continue }
            let blended = composite(
                previous: active.previous, target: s.target,
                transitions: [kind: active.transition], progress: progress,
                holds: [kind: holds(for: kind, in: active, among: s, order: order)])
            if let layer = blended.layers.first(where: { $0.kind == kind }) {
                scene.layers[index] = layer
            }
        }
        return scene
    }

    /// Full-frame media crossing between two media layers in one change (a
    /// video slide to a picture slide: the video's layer clears as the
    /// picture's fills) would dip through black if both faded: halfway, each
    /// is at half strength. The lower layer holds at full instead, and only
    /// the upper one fades, over it or away from it.
    private static func holds(
        for kind: LayerKind, in active: Active, among s: State, order: [LayerKind: Int]
    ) -> Hold {
        guard mediaLayers.contains(kind), let mine = order[kind] else { return [] }
        var hold: Hold = []
        // Only on one clock: a hold that ended before the fade over it
        // would pop.
        for (other, peer) in s.active
        where peer.group == active.group && other != kind && peer.transition == active.transition
            && peer.startedAt == active.startedAt {
            guard mediaLayers.contains(other), let theirs = order[other], theirs > mine else { continue }
            let canvas = s.target.canvasSize
            let leaving = peer.previous.layers.first { $0.kind == other }?.items ?? []
            let arriving = s.target.layers.first { $0.kind == other }?.items ?? []
            // Arrivals here are revealed as the full-frame picture above
            // fades away; what leaves here is covered as one above fades in.
            if leaving.contains(where: { coversCanvas($0, canvas: canvas) }) { hold.insert(.arriving) }
            if arriving.contains(where: { coversCanvas($0, canvas: canvas) }) { hold.insert(.leaving) }
        }
        return hold
    }

    /// Whether an item hides everything under it: an opaque full-frame
    /// colour (a letterbox's backing) or media filling the frame.
    static func coversCanvas(_ item: RenderItem, canvas: CGSize) -> Bool {
        guard item.opacity >= 0.999, item.maskedBy == nil, item.blendMode == .normal,
              item.frame.insetBy(dx: -0.5, dy: -0.5).contains(CGRect(origin: .zero, size: canvas))
        else { return false }
        switch item.content {
        case .solid(let color): return color.alpha >= 0.999
        case .media(_, let scaleMode, _): return scaleMode != .fit
        default: return false
        }
    }

    private static func progress(of active: Active, at date: Date) -> Double {
        min(max(date.timeIntervalSince(active.startedAt) / active.transition.duration, 0), 1)
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

    /// What a layer keeps at full strength through a dissolve instead of
    /// fading it (see `holds(for:in:among:order:)`).
    struct Hold: OptionSet, Hashable {
        let rawValue: Int
        static let leaving = Hold(rawValue: 1)
        static let arriving = Hold(rawValue: 2)
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
        transitions: [LayerKind: SceneTransition], progress: Double,
        holds: [LayerKind: Hold] = [:]
    ) -> RenderScene {
        var scene = target
        for index in scene.layers.indices {
            let kind = scene.layers[index].kind
            guard let transition = transitions[kind] else { continue }
            let hold = holds[kind] ?? []
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
                guard !hold.contains(.arriving) else { return items }
                return items.map { item in
                    guard !oldKeys.contains(membershipKey(item)) else { return item }
                    var out = item
                    out.opacity *= opacity
                    return out
                }
            }
            // On a media layer the outgoing picture goes in just under the
            // incoming one, so anything that stays (a letterbox's black
            // backing, shared by both clips) stays under both rather than
            // covering the clip that's leaving.
            func stacked(_ leaving: [RenderItem], _ arriving: [RenderItem]) -> [RenderItem] {
                guard mediaLayers.contains(kind) else { return leaving + arriving }
                let at = arriving.firstIndex { !oldKeys.contains(membershipKey($0)) } ?? arriving.count
                return Array(arriving[..<at]) + leaving + Array(arriving[at...])
            }

            let hasArrivals = newItems.contains { !oldKeys.contains(membershipKey($0)) }
            let holdsUnder = hold.contains(.leaving) || (hasArrivals && mediaLayers.contains(kind))
            switch transition.kind {
            case .cut:
                continue
            case .dissolve:
                scene.layers[index].items = stacked(
                    holdsUnder ? leaving : faded(leaving, to: 1 - progress),
                    lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress))
            case .fade(let plate):

                let firstHalf = progress < 0.5
                let plateOpacity = firstHalf ? progress * 2 : (1 - progress) * 2
                var items = firstHalf ? oldItems : newItems
                items.append(RenderItem(
                    id: Self.fadePlateID(kind),
                    frame: CGRect(origin: .zero, size: scene.canvasSize),
                    content: .solid(SceneColor(
                        red: plate.red, green: plate.green, blue: plate.blue,
                        alpha: plateOpacity
                    ))
                ))
                scene.layers[index].items = items
            case .heldDissolve:
                // What covers the camera (pictures, shapes, fills) holds:
                // the outgoing at full strength until halfway, then fading,
                // under the incoming fading up to full by halfway, so where
                // both cover one is always at full. Words cross exactly as in
                // a plain dissolve (unchanged lines hold, changed lines cross,
                // old words fade as new ones come): held, the old line and
                // the new one would both be at full strength halfway, one on
                // top of the other. The outgoing words go just under the
                // incoming ones, over the incoming design, so they fade out
                // in view rather than vanish under a new bar.
                let arrivingStrength = min(1, progress * 2)
                let leavingStrength = min(1, (1 - progress) * 2)
                let coversUnder = leaving.filter { !Self.isText($0) }
                let wordsLeaving = faded(leaving.filter(Self.isText), to: 1 - progress)
                var arriving = newItems.map { item -> RenderItem in
                    guard !oldKeys.contains(membershipKey(item)) else { return item }
                    var out = item
                    if Self.isText(item) {
                        out.opacity *= progress
                    } else if !hold.contains(.arriving) {
                        out.opacity *= arrivingStrength
                    }
                    return out
                }
                arriving = lineDissolved(arriving, reworded, progress: progress)
                arriving.insert(contentsOf: wordsLeaving, at: arriving.firstIndex(where: Self.isText) ?? arriving.count)
                scene.layers[index].items = (hold.contains(.leaving) ? coversUnder : faded(coversUnder, to: leavingStrength))
                    + arriving
            case .blurDissolve:

                let swell = (1 - abs(progress * 2 - 1)) * 60
                scene.layers[index].items = stacked(
                    blurred(holdsUnder ? leaving : faded(leaving, to: 1 - progress), radius: swell),
                    lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress))
            case .filmBurn:

                let peak = 1 - abs(progress * 2 - 1)
                let leaving = burned(faded(leaving, to: 1 - progress), amount: peak, phase: progress)
                let arriving = burned(
                    lineDissolved(arrivingFaded(newItems, to: progress), reworded, progress: progress),
                    amount: peak, phase: progress)
                var items = stacked(leaving, arriving)
                items.append(RenderItem(
                    id: "\(Self.platePrefix)burn-\(kind.rawValue)",
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

    static func isText(_ item: RenderItem) -> Bool {
        if case .text = item.content { return true }
        return false
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

    static let platePrefix = "transition-plate-"

    static func fadePlateID(_ kind: LayerKind) -> String { platePrefix + kind.rawValue }

    private static func blurred(_ items: [RenderItem], radius: Double) -> [RenderItem] {
        guard radius > 0.5 else { return items }
        return items.map { item in
            var out = item
            out.effects = [SceneEffect(kind: .blur(radius: radius))] + out.effects
            return out
        }
    }
}

extension RenderScene {
    /// The scene for an output with a transparent background, keyed over a
    /// camera (the livestream over NDI, a keyed DeckLink port). A transition's
    /// full-frame plate there would cover the camera with black or a color on
    /// every slide, so a fade goes through clear instead (the layer's items
    /// fade as the plate would have risen) and a film burn's wash is left out.
    public func withoutTransitionPlates() -> RenderScene {
        let prefix = SceneTransitionEngine.platePrefix
        guard layers.contains(where: { $0.items.contains { $0.id.hasPrefix(prefix) } })
        else { return self }
        var scene = self
        for index in scene.layers.indices {
            let fadeID = SceneTransitionEngine.fadePlateID(scene.layers[index].kind)
            var remaining = 1.0
            scene.layers[index].items.removeAll { item in
                guard item.id.hasPrefix(prefix) else { return false }
                if item.id == fadeID, case .solid(let color) = item.content {
                    remaining = 1 - color.alpha
                }
                return true
            }
            guard remaining < 1 else { continue }
            for item in scene.layers[index].items.indices {
                scene.layers[index].items[item].opacity *= remaining
            }
        }
        return scene
    }
}
