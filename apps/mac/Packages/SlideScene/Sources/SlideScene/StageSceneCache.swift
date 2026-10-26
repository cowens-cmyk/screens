import Foundation
import PresenterCore
import RenderEngine

/// Keeps the last built stage layout scene per stage screen, so the screen's
/// window, its virtual screen and its DeckLink or NDI feed share one build,
/// and a build happens only when what the layout shows changes.
///
/// Every one of those asked for the scene on its own refresh, 60 times a
/// second each, and each ask built the layout from scratch: resolving every
/// linked text, formatting the clock, laying out the slide objects. On the
/// show Mac that was the largest piece of work on the render thread and the
/// feed queues. The scene only changes when the inputs change or a shown
/// value ticks, so the key is the layout, the stage info, the text every
/// clock, timer and countdown shows now, and the wall-clock second (for
/// visibility rules that turn on a timer's state rather than its text).
///
/// A stage message bypasses the cache: its takeover fades by the frame.
public final class StageSceneCache: @unchecked Sendable {

    struct Key: Equatable {
        var layout: ConfidenceLayout
        var info: ConfidenceInfo
        var shown: [String?]
        var second: Int64
        /// For the Video layout: Message mode, the audience scene the
        /// picture comes from, and the video's shown second.
        var isMessage: Bool? = nil
        var audience: RenderScene? = nil
        var videoSecond: Int? = nil
    }

    private let entries = Locked<[String: (key: Key, scene: RenderScene)]>([:])
    private let buildCount = Locked(0)

    public init() {}

    /// Scenes built so far, for tests and the performance report.
    public var builds: Int { buildCount.value }

    public func scene(
        slot: String,
        layout: ConfidenceLayout,
        info: ConfidenceInfo,
        at date: Date,
        build: (ConfidenceLayout, ConfidenceInfo, Date) -> RenderScene = ConfidenceSceneBuilder.scene
    ) -> RenderScene {
        guard info.stageAlert(at: date) == nil else {
            buildCount.withLock { $0 += 1 }
            return build(layout, info, date)
        }
        let key = Key(
            layout: layout, info: info,
            shown: Self.shownValues(of: layout, info: info, at: date),
            second: Int64(date.timeIntervalSince1970.rounded(.down)))
        if let entry = entries.value[slot], entry.key == key {
            return entry.scene
        }
        let scene = build(layout, info, date)
        buildCount.withLock { $0 += 1 }
        entries.withLock { $0[slot] = (key, scene) }
        return scene
    }

    /// The Video layout while a video holds the stage. The picture itself is
    /// live media drawn by the compositor, so the scene only changes with the
    /// audience scene, the video's shown second and what the layout shows.
    public func videoScene(
        slot: String,
        plan: StageVideoPlan,
        audience: RenderScene,
        info: ConfidenceInfo,
        at date: Date,
        build: () -> RenderScene
    ) -> RenderScene {
        guard info.stageAlert(at: date) == nil else {
            buildCount.withLock { $0 += 1 }
            return build()
        }
        let key = Key(
            layout: plan.layout, info: info,
            shown: Self.shownValues(of: plan.layout, info: info, at: date),
            second: Int64(date.timeIntervalSince1970.rounded(.down)),
            isMessage: plan.isMessage, audience: audience,
            videoSecond: StageScenes.displayedVideoSecond(in: info, at: date))
        if let entry = entries.value[slot], entry.key == key {
            return entry.scene
        }
        let scene = build()
        buildCount.withLock { $0 += 1 }
        entries.withLock { $0[slot] = (key, scene) }
        return scene
    }

    public func forget(slot: String) {
        entries.withLock { $0[slot] = nil }
    }

    /// What each time-driven linked text shows at `date`, with its warning
    /// ink: the cheap part of a build that tells whether the rest is due.
    static func shownValues(of layout: ConfidenceLayout, info: ConfidenceInfo, at date: Date) -> [String?] {
        var values: [String?] = []
        for object in layout.objects {
            guard let link = object.textLink, LinkedText.isTimeVarying(link) else { continue }
            values.append(LinkedText.resolve(link, info: info, at: date))
            values.append(LinkedText.warningColorHex(for: link, info: info, at: date))
        }
        return values
    }
}
