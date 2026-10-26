import Foundation
import QuartzCore

/// How a scene changes with time alone, with nothing about it edited.
///
/// Every output and preview used to draw its scene on every display refresh,
/// 60 to 120 times a second, whether or not anything on it moved. Most of a
/// service is a still slide, so most of that work drew the same picture
/// again. A scene is `moving` when the compositor would draw it differently a
/// frame later: a playing video, a camera or live feed, a running build or
/// transition step, a ticker or scrolling text, or an effect with a speed.
/// `wakeAt` is the host time a still scene starts to move by itself, such as
/// an auto build waiting on its start offset.
///
/// Clocks, timers and transitions between scenes are not here: their
/// providers build a different scene each time the shown value changes, so
/// the scene itself tells the gate.
public struct SceneMotion: Equatable, Sendable {
    public var isMoving: Bool
    public var wakeAt: CFTimeInterval?

    public init(isMoving: Bool = false, wakeAt: CFTimeInterval? = nil) {
        self.isMoving = isMoving
        self.wakeAt = wakeAt
    }

    public static let still = SceneMotion()
    public static let moving = SceneMotion(isMoving: true)

    public mutating func merge(_ other: SceneMotion) {
        isMoving = isMoving || other.isMoving
        if let wake = other.wakeAt { wakeAt = min(wakeAt ?? wake, wake) }
    }

    public static func of(
        _ scenes: [RenderScene], at hostTime: CFTimeInterval, media: MediaTextureSource?
    ) -> SceneMotion {
        var motion = SceneMotion.still
        for scene in scenes {
            motion.merge(of(scene, at: hostTime, media: media))
            if motion.isMoving { return motion }
        }
        return motion
    }

    public static func of(
        _ scene: RenderScene, at hostTime: CFTimeInterval, media: MediaTextureSource?
    ) -> SceneMotion {
        var motion = SceneMotion.still
        for layer in scene.layers where !layer.isHidden {
            for item in layer.items {
                motion.merge(of(item, at: hostTime, media: media))
                if motion.isMoving { return motion }
            }
        }
        return motion
    }

    static func of(
        _ item: RenderItem, at hostTime: CFTimeInterval, media: MediaTextureSource?
    ) -> SceneMotion {
        if let id = item.content.mediaID {
            // With no source to ask, a media item counts as moving: that was
            // the rule before stills could be told apart.
            if (media?.motion(for: id) ?? .moving) == .moving { return .moving }
        }
        if case .text(let text) = item.content {
            if text.tickerSpeed != 0 { return .moving }
            if let scroll = text.scroll, scroll.speed > 0,
               item.animationContext?.frozenHostTime == nil {
                return .moving
            }
        }
        for effect in item.effects where effectMoves(effect.kind) { return .moving }
        return animationMotion(of: item, at: hostTime)
    }

    /// Effects drawn from the host time, or from the frames before, change
    /// every frame; the others are fixed by their parameters.
    static func effectMoves(_ kind: SceneEffect.Kind) -> Bool {
        switch kind {
        case .warp(_, _, let speed): speed != 0
        case .scatter(_, _, let speed, _): speed > 0.001
        case .stainedGlass(_, _, _, let speed): speed != 0
        case .grain(_, _, let speed): speed > 0.001
        case .echo, .ghostTrails: true
        case .blur, .colorAdjust, .hueRotate, .invert, .posterize, .pixelate,
             .vignette, .glitch, .burn, .tint:
            false
        }
    }

    static func animationMotion(of item: RenderItem, at hostTime: CFTimeInterval) -> SceneMotion {
        guard let context = item.animationContext, !item.animationSteps.isEmpty,
              context.frozenHostTime == nil
        else { return .still }
        var motion = SceneMotion.still
        for step in item.animationSteps {
            switch AnimationTimeline.phase(of: step, context: context, now: hostTime) {
            case .running:
                return .moving
            case .pending:
                // A step whose group has a start time begins on its own; one
                // waiting for a click starts when the scene changes.
                if !(context.autoSettled && step.group == .auto),
                   let start = AnimationTimeline.effectiveStart(of: step, context: context) {
                    motion.merge(SceneMotion(wakeAt: start + step.startOffset))
                }
            case .done:
                break
            }
        }
        return motion
    }
}

/// Decides, on each display refresh, whether a view draws a new frame or
/// leaves the last one up. Pure, so the rules are tested without a display.
///
/// A frame is drawn when the key (the scene with everything else that sets
/// the picture: drawable size, adjustments, mask, media content) differs from
/// the last drawn one, when the scene moves by itself, when a waiting build
/// reaches its start, for one frame after motion stops (the frame where a
/// build lands), for `trailingFrames` frames after any change (a delayed
/// output's queue has to carry the change out), and once every
/// `refreshInterval` as a safety net. The check runs on
/// the same refresh that would have drawn before, so a cue still shows on the
/// next frame: skipping adds no latency.
public struct FrameGate<Key: Equatable> {
    public enum Reason: String, Equatable, Sendable {
        case first, invalidated, changed, moving, wake, settling, refresh
    }

    public enum Decision: Equatable, Sendable {
        case render(Reason)
        case skip

        public var renders: Bool { self != .skip }
    }

    public var refreshInterval: CFTimeInterval
    public var trailingFrames: Int

    private var lastKey: Key?
    private var lastRenderAt: CFTimeInterval = -.infinity
    private var wakeAt: CFTimeInterval?
    private var settleRemaining = 0
    private var invalid = false

    public init(refreshInterval: CFTimeInterval = 1, trailingFrames: Int = 0) {
        self.refreshInterval = refreshInterval
        self.trailingFrames = trailingFrames
    }

    /// Draw the next frame whatever it shows: the window moved screens, the
    /// layer was rebuilt, or a consumer lost the last frame.
    public mutating func invalidate() {
        invalid = true
    }

    public mutating func decide(
        key: Key, motion: SceneMotion, now: CFTimeInterval
    ) -> Decision {
        let reason: Reason?
        if lastKey == nil {
            reason = .first
        } else if invalid {
            reason = .invalidated
        } else if lastKey != key {
            reason = .changed
        } else if motion.isMoving {
            reason = .moving
        } else if let wake = wakeAt, now >= wake {
            reason = .wake
        } else if settleRemaining > 0 {
            reason = .settling
        } else if now - lastRenderAt >= refreshInterval {
            reason = .refresh
        } else {
            reason = nil
        }
        wakeAt = motion.wakeAt
        guard let reason else { return .skip }
        switch reason {
        case .settling: settleRemaining -= 1
        case .refresh: break
        case .moving: settleRemaining = max(1, trailingFrames)
        case .first, .invalidated, .changed, .wake: settleRemaining = trailingFrames
        }
        invalid = false
        lastKey = key
        lastRenderAt = now
        return .render(reason)
    }
}

/// Frames drawn and skipped over the last minute, in one-second buckets, for
/// the performance report.
public struct FrameTally: Sendable, Equatable {
    public static let window = 60

    private var seconds = [Int](repeating: Int.min, count: FrameTally.window)
    private var rendered = [Int](repeating: 0, count: FrameTally.window)
    private var skipped = [Int](repeating: 0, count: FrameTally.window)

    public init() {}

    public mutating func record(rendered didRender: Bool, at now: CFTimeInterval) {
        let second = Int(now.rounded(.down))
        let slot = ((second % Self.window) + Self.window) % Self.window
        if seconds[slot] != second {
            seconds[slot] = second
            rendered[slot] = 0
            skipped[slot] = 0
        }
        if didRender { rendered[slot] += 1 } else { skipped[slot] += 1 }
    }

    public func totals(at now: CFTimeInterval) -> (rendered: Int, skipped: Int) {
        let second = Int(now.rounded(.down))
        var drawn = 0
        var held = 0
        for slot in 0..<Self.window where seconds[slot] != Int.min
            && second - seconds[slot] < Self.window && seconds[slot] <= second {
            drawn += rendered[slot]
            held += skipped[slot]
        }
        return (drawn, held)
    }
}

/// Every view and feed that draws frames on a cadence, with its tally, so
/// the performance report can list them. Entries go away with their owner.
public final class FrameActivity: @unchecked Sendable {
    public static let shared = FrameActivity()

    public final class Handle: @unchecked Sendable {
        private let names: Locked<(kind: String, label: String)>
        private let tally = Locked(FrameTally())

        init(kind: String, label: String) {
            names = Locked((kind, label))
        }

        public var kind: String {
            get { names.value.kind }
            set { names.withLock { $0.kind = newValue } }
        }

        public var label: String {
            get { names.value.label }
            set { names.withLock { $0.label = newValue } }
        }

        public func record(rendered: Bool, at now: CFTimeInterval = CACurrentMediaTime()) {
            tally.withLock { $0.record(rendered: rendered, at: now) }
        }

        public func totals(at now: CFTimeInterval = CACurrentMediaTime()) -> (rendered: Int, skipped: Int) {
            tally.value.totals(at: now)
        }
    }

    public struct Entry: Sendable {
        public var kind: String
        public var label: String
        public var rendered: Int
        public var skipped: Int
    }

    private struct Weak {
        weak var handle: Handle?
    }

    private let handles = Locked<[Weak]>([])

    public func register(kind: String, label: String) -> Handle {
        let handle = Handle(kind: kind, label: label)
        handles.withLock { list in
            list.removeAll { $0.handle == nil }
            list.append(Weak(handle: handle))
        }
        return handle
    }

    public func snapshot(at now: CFTimeInterval = CACurrentMediaTime()) -> [Entry] {
        let live = handles.withLock { list -> [Handle] in
            list.removeAll { $0.handle == nil }
            return list.compactMap(\.handle)
        }
        return live.map { handle in
            let totals = handle.totals(at: now)
            return Entry(
                kind: handle.kind, label: handle.label,
                rendered: totals.rendered, skipped: totals.skipped)
        }
    }
}
