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

/// Builds the stage display's scene. Pure, so it runs on the render thread
/// from values copied out of the locked boxes.
///
/// The order of precedence:
/// 1. A video that is live and not finished takes the stage over: a large
///    countdown of the time left above the video. Nothing else is changed
///    for it, so when it ends the stage shows exactly what it did before.
/// 2. A layout picked for this screen (a slide's stage layout, a Set Stage
///    Layout action, or the screen's own pick) — until the stage mode changes.
/// 3. The stage mode: its layout, or the audience screen for Mirror.
public enum StageScenes {

    /// Seconds left at which the countdown turns orange, then red.
    public static let warningSeconds: Double = 10
    public static let urgentSeconds: Double = 5

    static let orange = SceneColor(red: 1.0, green: 0.62, blue: 0.0)
    static let red = SceneColor(red: 1.0, green: 0.23, blue: 0.19)
    static let dimmed = SceneColor(red: 0.72, green: 0.72, blue: 0.72)

    public static func scene(
        override: ConfidenceLayout?,
        source: StageSource,
        info: ConfidenceInfo,
        at date: Date,
        audience: () -> RenderScene
    ) -> RenderScene {
        if let video = activeVideo(in: info, at: date) {
            let live = audience()
            let canvas = override.map(canvasSize(of:)) ?? {
                switch source {
                case .layout(let layout): canvasSize(of: layout)
                case .mirror: live.canvasSize
                }
            }()
            var scene = videoScene(audience: live, video: video, canvasSize: canvas, at: date)
            addStageAlert(to: &scene, info: info, at: date)
            return scene
        }
        if let override {
            return ConfidenceSceneBuilder.scene(layout: override, info: info, at: date)
        }
        switch source {
        case .layout(let layout):
            return ConfidenceSceneBuilder.scene(layout: layout, info: info, at: date)
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

    /// Whole seconds left, rounded up so "0:00" shows only when it has ended.
    public static func countdownText(remaining: Double) -> String {
        TimerSnapshot.timecode(max(0, remaining).rounded(.up))
    }

    public static func countdownColor(remaining: Double) -> SceneColor {
        if remaining <= urgentSeconds { return red }
        if remaining <= warningSeconds { return orange }
        return .white
    }

    /// Where the countdown sits: across the top, as large as it fits.
    public static func countdownFrame(in canvasSize: CGSize) -> CGRect {
        CGRect(
            x: canvasSize.width * 0.03, y: canvasSize.height * 0.035,
            width: canvasSize.width * 0.94, height: canvasSize.height * 0.30)
    }

    /// Where the video goes: under the countdown and smaller than the
    /// screen, so the time left is what reads first.
    public static func videoArea(in canvasSize: CGSize) -> CGRect {
        CGRect(
            x: canvasSize.width * 0.10, y: canvasSize.height * 0.36,
            width: canvasSize.width * 0.80, height: canvasSize.height * 0.53)
    }

    /// The time left in big digits across the top, the video as the
    /// audience sees it under that, and its name in small type below.
    public static func videoScene(
        audience: RenderScene, video: VideoCountdown, canvasSize: CGSize, at date: Date
    ) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        let width = canvasSize.width
        let height = canvasSize.height
        let unit = height / 1080
        let preview = aspectFit(audience.canvasSize, in: videoArea(in: canvasSize))

        let remaining = video.remaining(at: date)
        scene.addItem(RenderItem(
            id: "stage-video-countdown",
            frame: countdownFrame(in: canvasSize),
            content: .text(StyledText(
                string: countdownText(remaining: remaining), fontSize: 300 * unit,
                color: countdownColor(remaining: remaining), alignment: .center,
                tabularFigures: true, autoShrink: true, minFontSize: 60 * unit
            ))
        ), to: .slide)

        // A dark plate so a letterboxed or not-yet-decoded video still reads
        // as a picture frame.
        scene.addItem(RenderItem(
            id: "stage-video-plate", frame: preview,
            content: .solid(SceneColor(red: 0.08, green: 0.08, blue: 0.08))
        ), to: .stillGraphics)
        for item in videoItems(of: audience, layer: video.layer, into: preview) {
            scene.addItem(item, to: .videos)
        }

        let name = video.isPlaying ? video.name : "\(video.name) · Paused"
        scene.addItem(RenderItem(
            id: "stage-video-name",
            frame: CGRect(x: width * 0.10, y: height * 0.905, width: width * 0.80, height: height * 0.06),
            content: .text(StyledText(
                string: name, fontSize: 40 * unit, color: dimmed, alignment: .center,
                autoShrink: true, minFontSize: 20 * unit
            ))
        ), to: .slide)
        return scene
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

    static func canvasSize(of layout: ConfidenceLayout) -> CGSize {
        CGSize(
            width: layout.canvasWidth.map(Double.init) ?? SlideSceneBuilder.canvasSize.width,
            height: layout.canvasHeight.map(Double.init) ?? SlideSceneBuilder.canvasSize.height
        )
    }

    /// Stage messages still reach the stage over a mirror or a video: the
    /// large bar across the top, since there is no layout to rearrange.
    static func addStageAlert(to scene: inout RenderScene, info: ConfidenceInfo, at date: Date) {
        guard let alert = info.stageAlert(at: date), info.alertVisible else { return }
        for item in AlertSceneBuilder.bannerItems(
            for: alert, canvasSize: scene.canvasSize, info: info, at: date, size: .stage
        ) {
            scene.addItem(item, to: .alerts)
        }
    }
}
