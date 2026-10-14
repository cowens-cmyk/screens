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
/// 1. A foreground video that is live and not finished takes the stage over:
///    the video and a large countdown of the time left.
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

    /// The live foreground video (layer Videos), while it has time left. A
    /// paused video keeps the stage — it is still on the audience screen.
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

    /// The video as the audience sees it, scaled into the upper part of the
    /// frame, with its name and the time left below.
    public static func videoScene(
        audience: RenderScene, video: VideoCountdown, canvasSize: CGSize, at date: Date
    ) -> RenderScene {
        var scene = RenderScene(canvasSize: canvasSize)
        let width = canvasSize.width
        let height = canvasSize.height
        let unit = height / 1080
        let area = CGRect(
            x: width * 0.03, y: height * 0.03, width: width * 0.94, height: height * 0.64)
        let preview = aspectFit(audience.canvasSize, in: area)

        // A dark plate so a letterboxed or not-yet-decoded video still reads
        // as a picture frame.
        scene.addItem(RenderItem(
            id: "stage-video-plate", frame: preview,
            content: .solid(SceneColor(red: 0.08, green: 0.08, blue: 0.08))
        ), to: .stillGraphics)
        for item in videoItems(of: audience, into: preview) {
            scene.addItem(item, to: .videos)
        }

        let remaining = video.remaining(at: date)
        let name = video.isPlaying ? video.name : "\(video.name) · Paused"
        scene.addItem(RenderItem(
            id: "stage-video-name",
            frame: CGRect(x: width * 0.03, y: height * 0.685, width: width * 0.94, height: height * 0.075),
            content: .text(StyledText(
                string: name, fontSize: 52 * unit, color: dimmed, alignment: .center,
                autoShrink: true, minFontSize: 24 * unit
            ))
        ), to: .slide)
        scene.addItem(RenderItem(
            id: "stage-video-countdown",
            frame: CGRect(x: width * 0.03, y: height * 0.76, width: width * 0.94, height: height * 0.22),
            content: .text(StyledText(
                string: countdownText(remaining: remaining), fontSize: 220 * unit,
                color: countdownColor(remaining: remaining), alignment: .center,
                tabularFigures: true, autoShrink: true, minFontSize: 48 * unit
            ))
        ), to: .slide)
        return scene
    }

    /// The audience scene's foreground-video items, mapped from its canvas
    /// into `rect`.
    static func videoItems(of audience: RenderScene, into rect: CGRect) -> [RenderItem] {
        let source = audience.canvasSize
        guard source.width > 0, source.height > 0 else { return [] }
        let scaleX = rect.width / source.width
        let scaleY = rect.height / source.height
        let items = audience.layers.filter { $0.kind == .videos }.flatMap(\.items)
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

    /// Stage messages still reach the stage over a mirror or a video.
    static func addStageAlert(to scene: inout RenderScene, info: ConfidenceInfo, at date: Date) {
        guard let alert = info.alert, alert.showsOnConfidence, info.alertVisible else { return }
        for item in AlertSceneBuilder.bannerItems(
            for: alert, canvasSize: scene.canvasSize, info: info, at: date
        ) {
            scene.addItem(item, to: .alerts)
        }
    }
}
