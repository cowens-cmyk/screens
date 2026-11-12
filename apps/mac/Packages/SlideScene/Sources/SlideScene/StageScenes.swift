import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

/// What a stage display shows when no video is playing and no slide or
/// action has picked a layout for it.
public enum StageSource: Sendable, Equatable {
    /// A stage layout (worship lyrics, sermon timer and notes, …).
    case layout(ConfidenceLayout)
    /// Whatever the audience screen shows.
    case mirror
}

/// The stage's Video layout and what it needs to know about the room while a
/// video plays. Nil when the stage is set not to switch for videos.
public struct StageVideoPlan: Sendable, Equatable {
    /// The Video stage layout: time left, the video's box, sermon timer, clock.
    public var layout: ConfidenceLayout
    /// The stage is in Message mode, so the sermon timer stays in view while
    /// the video plays even when it hasn't been started.
    public var isMessage: Bool

    public init(layout: ConfidenceLayout, isMessage: Bool) {
        self.layout = layout
        self.isMessage = isMessage
    }
}

/// Builds the stage display's scene. Pure, so it runs on the render thread
/// from values copied out of the locked boxes.
///
/// The order of precedence:
/// 1. A video that is live and not finished takes the stage over with the
///    Video layout (unless the stage is set not to): the time left above the
///    video, and during the Message the sermon timer and the clock along the
///    bottom. Nothing else is changed for it, so when it ends the stage shows
///    exactly what it did before.
/// 2. A layout picked for this screen (a slide's stage layout, a Set Stage
///    Layout action, or the screen's own pick) — until the stage mode changes.
/// 3. The stage mode: its layout, or the audience screen for Mirror.
public enum StageScenes {

    static let dimmed = SceneColor(red: 0.72, green: 0.72, blue: 0.72)

    public static func scene(
        override: ConfidenceLayout?,
        source: StageSource,
        video plan: StageVideoPlan? = nil,
        info: ConfidenceInfo,
        at date: Date,
        cache: StageSceneCache? = nil,
        slot: String = "",
        audience: () -> RenderScene
    ) -> RenderScene {
        // A layout build is shared through the cache when one is given.
        func layoutScene(_ layout: ConfidenceLayout) -> RenderScene {
            guard let cache else {
                return ConfidenceSceneBuilder.scene(layout: layout, info: info, at: date)
            }
            return cache.scene(slot: slot, layout: layout, info: info, at: date)
        }
        if let plan, let video = activeVideo(in: info, at: date) {
            let live = audience()
            guard let cache else {
                return videoScene(plan: plan, audience: live, video: video, info: info, at: date)
            }
            return cache.videoScene(slot: slot, plan: plan, audience: live, info: info, at: date) {
                videoScene(plan: plan, audience: live, video: video, info: info, at: date)
            }
        }
        if let override {
            return layoutScene(override)
        }
        switch source {
        case .layout(let layout):
            return layoutScene(layout)
        case .mirror:
            var scene = audience()
            addStageAlert(to: &scene, info: info, at: date)
            return scene
        }
    }

    /// The live video (a foreground one, or one playing once on the
    /// background layer), while it has time left. A paused video keeps the
    /// stage — it is still on the audience screen.
    public static func activeVideo(in info: ConfidenceInfo, at date: Date) -> VideoCountdown? {
        guard let video = info.videoCountdown, video.duration > 0,
              video.remaining(at: date) > 0
        else { return nil }
        return video
    }

    /// The video's time left as the stage shows it, in whole seconds, or nil
    /// when no video holds the stage. Besides `info` (and the plan), this and
    /// the displayed second of the clock and timers are the only things the
    /// video stage changes with — so a cache of built stage scenes keys on
    /// it. It counts down with the video's own position: the picture itself
    /// is live media and needs no rebuild.
    public static func displayedVideoSecond(in info: ConfidenceInfo, at date: Date) -> Int? {
        guard let video = activeVideo(in: info, at: date) else { return nil }
        return Int(video.remaining(at: date).rounded(.up))
    }

    /// Whole seconds left, rounded up so "0:00" shows only when it has ended.
    public static func countdownText(remaining: Double) -> String {
        TimerSnapshot.timecode(max(0, remaining).rounded(.up))
    }

    /// During the Message the Video layout keeps the sermon timer: in
    /// Message mode, or whenever the sermon timer is running.
    public static func isDuringMessage(plan: StageVideoPlan, info: ConfidenceInfo) -> Bool {
        plan.isMessage || SermonTimer.find(in: info.timers, id: \.id, name: \.name)?.isRunning == true
    }

    /// The Video layout's objects that show only during the Message: the
    /// ones that show the sermon timer.
    public static func showsOnlyDuringMessage(_ object: SlideObject) -> Bool {
        object.textLink?.source == .timer && object.textLink?.timerId == SermonTimer.id
    }

    static func isVideoBox(_ object: SlideObject) -> Bool {
        object.objectKind == .shape
            && object.name.caseInsensitiveCompare(ConfidenceLayoutTemplate.videoBoxName) == .orderedSame
    }

    /// Where the video goes in a Video layout that has lost its box: where
    /// the template's box is.
    public static func defaultVideoArea(in canvasSize: CGSize) -> CGRect {
        CGRect(
            x: canvasSize.width * 0.1875, y: canvasSize.height * (252.0 / 1080.0),
            width: canvasSize.width * 0.625, height: canvasSize.height * 0.625)
    }

    /// The Video layout with the video as the audience sees it inside its
    /// box. Objects drawn before the box (and the box itself) sit under the
    /// picture, the rest over it. A stage message is the bar across the top
    /// unless the layout has its own Stage Message box.
    public static func videoScene(
        plan: StageVideoPlan, audience: RenderScene, video: VideoCountdown,
        info: ConfidenceInfo, at date: Date
    ) -> RenderScene {
        var layout = plan.layout
        if !isDuringMessage(plan: plan, info: info) {
            layout.objects.removeAll(where: showsOnlyDuringMessage)
        }
        let canvas = canvasSize(of: layout)
        let boxIndex = layout.objects.lastIndex(where: isVideoBox)
        let under = Set(boxIndex.map { layout.objects[...$0].map(\.id) } ?? [])
        var scene = ConfidenceSceneBuilder.scene(
            layout: layout, info: info, at: date,
            messageStyle: layout.hasStageMessageObject ? .linkedObject : .banner,
            layer: { under.contains($0.id) ? .stillGraphics : .slide })

        let area = boxIndex.map { frame(of: layout.objects[$0]) } ?? defaultVideoArea(in: canvas)
        let picture = aspectFit(audience.canvasSize, in: area)
        for item in videoItems(of: audience, layer: video.layer, into: picture) {
            scene.addItem(item, to: .videos)
        }
        if !video.isPlaying {
            for item in pausedItems(over: picture, canvasSize: canvas) {
                scene.addItem(item, to: .slide)
            }
        }
        return scene
    }

    /// A small "Paused" tag at the foot of the picture: the time left has
    /// stopped because the video has.
    static func pausedItems(over picture: CGRect, canvasSize: CGSize) -> [RenderItem] {
        let unit = canvasSize.height / 1080
        let tag = CGRect(
            x: picture.midX - 110 * unit, y: picture.maxY - 84 * unit,
            width: 220 * unit, height: 60 * unit)
        return [
            RenderItem(
                id: "stage-video-paused-plate", frame: tag,
                content: .shape(ShapeStyle(
                    kind: .roundedRectangle(cornerRadius: 30 * unit),
                    fill: .solid(SceneColor(red: 0, green: 0, blue: 0, alpha: 0.72))
                ))
            ),
            RenderItem(
                id: "stage-video-paused", frame: tag,
                content: .text(StyledText(
                    string: "Paused", fontSize: 36 * unit, color: dimmed, alignment: .center,
                    autoShrink: true, minFontSize: 18 * unit
                ))
            ),
        ]
    }

    /// The audience scene's items on the video's layer, mapped from its
    /// canvas into `rect`.
    static func videoItems(
        of audience: RenderScene, layer: LayerKind = .videos, into rect: CGRect
    ) -> [RenderItem] {
        let source = audience.canvasSize
        guard source.width > 0, source.height > 0 else { return [] }
        let scaleX = rect.width / source.width
        let scaleY = rect.height / source.height
        let items = audience.layers.filter { $0.kind == layer }.flatMap(\.items)
        return items.map { item in
            var item = item
            item.id = "stage-\(item.id)"
            item.frame = CGRect(
                x: rect.minX + item.frame.minX * scaleX,
                y: rect.minY + item.frame.minY * scaleY,
                width: item.frame.width * scaleX,
                height: item.frame.height * scaleY
            )
            return item
        }
    }

    static func aspectFit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
    }

    static func frame(of object: SlideObject) -> CGRect {
        CGRect(x: object.x ?? 0, y: object.y ?? 0, width: object.width ?? 0, height: object.height ?? 0)
    }

    static func canvasSize(of layout: ConfidenceLayout) -> CGSize {
        CGSize(
            width: layout.canvasWidth.map(Double.init) ?? SlideSceneBuilder.canvasSize.width,
            height: layout.canvasHeight.map(Double.init) ?? SlideSceneBuilder.canvasSize.height
        )
    }

    /// Stage messages still reach the stage over a mirror: the large bar
    /// across the top, since there is no layout to rearrange.
    static func addStageAlert(to scene: inout RenderScene, info: ConfidenceInfo, at date: Date) {
        guard let alert = info.stageAlert(at: date), info.alertVisible else { return }
        for item in AlertSceneBuilder.bannerItems(
            for: alert, canvasSize: scene.canvasSize, info: info, at: date, size: .stage
        ) {
            scene.addItem(item, to: .alerts)
        }
    }
}
