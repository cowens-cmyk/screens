import CoreGraphics
import PresenterCore
import RenderEngine

/// The Side TVs' copy of the room's picture: the same scene, with a song's
/// words drawn larger. Lyrics are set for the big centre wall, where two
/// small lines at the top read well from the back; on a TV beside it the
/// same lines are a fraction of the size and hard to read. Only the slide's
/// own text boxes grow. The background, media, the theme's decoration and
/// alerts are the room's own, so the TVs stay in step with the wall, and
/// anything that isn't a song goes to the TVs exactly as the room sees it.
public enum SideScreenLyrics {
    /// The routing key the Side TVs screen reads its scene from, alongside
    /// the livestream's design keys.
    public static let variantKey = "side-tvs-lyrics"

    public static let defaultScale = 1.6
    public static let scaleRange: ClosedRange<Double> = 1.0...2.5

    /// Kept clear at each edge of the canvas, as a share of its size: a
    /// larger box grows into the picture, never off a TV's edge. A box the
    /// theme already put past this line may keep its own edges.
    public static let safeMargin = 0.05

    /// Songs, and anything else of the Worship type, carry lyrics.
    public static func carriesLyrics(_ presentation: Presentation?) -> Bool {
        guard let presentation else { return false }
        return PresentationTypes.screensType(of: presentation) == PresentationTypes.worship
    }

    /// The scene for the Side TVs while `presentation` is live.
    public static func scene(
        _ scene: RenderScene, presentation: Presentation?, scale: Double
    ) -> RenderScene {
        guard carriesLyrics(presentation) else { return scene }
        return Self.scene(enlargingTextOf: scene, scale: scale)
    }

    /// The scene with each of the slide's own text boxes `scale` times the
    /// size, around its centre and inside the safe area. Every other layer
    /// and item is left as it is.
    public static func scene(enlargingTextOf scene: RenderScene, scale: Double) -> RenderScene {
        let factor = min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
        guard factor > 1.001,
              let index = scene.layers.firstIndex(where: { $0.kind == .slide })
        else { return scene }
        var out = scene
        let canvas = scene.canvasSize
        out.layers[index].items = scene.layers[index].items.map { item in
            guard enlarges(item) else { return item }
            var grown = enlarged(item, by: factor, canvas: canvas)
            // A page turn or a build carries the box's other states; they
            // grow with it so the move doesn't jump between sizes.
            grown.animationSteps = item.animationSteps.map { step in
                var step = step
                if let from = step.fromItem, enlarges(from) {
                    step.fromItem = enlarged(from, by: factor, canvas: canvas)
                }
                if let to = step.toItem, enlarges(to) {
                    step.toItem = enlarged(to, by: factor, canvas: canvas)
                }
                return step
            }
            return grown
        }
        return out
    }

    /// The lyrics are the slide's own plain text boxes. The theme's text
    /// (a song title or CCLI line, ids "theme-…"), words inside a shape
    /// ("…::text"), and text that runs along a path, ticks or scrolls are
    /// laid out for their exact place and stay as the room has them, as does
    /// text cut by a mask, which would no longer line up with it.
    static func enlarges(_ item: RenderItem) -> Bool {
        guard case .text(let text) = item.content,
              !item.id.hasPrefix("theme-"), !item.id.hasSuffix("::text"),
              text.pathData == nil, text.tickerSpeed == 0, text.scroll == nil,
              item.maskedBy == nil, item.matteGroup == nil,
              item.frame.width > 0, item.frame.height > 0
        else { return false }
        return true
    }

    static func enlarged(_ item: RenderItem, by factor: Double, canvas: CGSize) -> RenderItem {
        guard case .text(let text) = item.content else { return item }
        var out = item
        out.frame = frame(item.frame, scaledBy: factor, canvas: canvas)
        out.content = .text(styled(text, scaledBy: factor))
        return out
    }

    /// `frame` grown around its centre, then moved (and if need be cut)
    /// to sit inside the safe area, or the frame's own edges where the
    /// theme put it past that.
    public static func frame(_ frame: CGRect, scaledBy factor: Double, canvas: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return frame }
        let safe = CGRect(origin: .zero, size: canvas)
            .insetBy(dx: canvas.width * safeMargin, dy: canvas.height * safeMargin)
        let bounds = safe.union(frame).intersection(CGRect(origin: .zero, size: canvas))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return frame }
        let width = min(frame.width * factor, bounds.width)
        let height = min(frame.height * factor, bounds.height)
        let x = min(max(frame.midX - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(frame.midY - height / 2, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The type and every measure drawn with it, `factor` times larger. It
    /// shrinks to fit when the box couldn't grow as much (a wide line near
    /// the safe edge), but never below the room's own size, and keeps each
    /// written line on one line, so two lines on the wall stay two lines on
    /// the TVs.
    static func styled(_ text: StyledText, scaledBy factor: Double) -> StyledText {
        var out = text
        out.fontSize = text.fontSize * factor
        out.autoShrink = true
        out.minFontSize = text.autoShrink ? min(text.minFontSize, text.fontSize) : text.fontSize
        out.keepLinesWhole = true
        out.tracking = text.tracking * factor
        out.wordSpacing = text.wordSpacing * factor
        out.paragraphSpacing = text.paragraphSpacing * factor
        out.firstLineIndent = text.firstLineIndent * factor
        out.leftIndent = text.leftIndent * factor
        out.rightIndent = text.rightIndent * factor
        out.insetTop = text.insetTop * factor
        out.insetLeft = text.insetLeft * factor
        out.insetBottom = text.insetBottom * factor
        out.insetRight = text.insetRight * factor
        if var shadow = text.shadow {
            shadow.blurRadius *= factor
            shadow.offsetX *= factor
            shadow.offsetY *= factor
            out.shadow = shadow
        }
        if var outline = text.outline {
            outline.width *= factor
            out.outline = outline
        }
        if var lineFill = text.lineFill {
            lineFill.verticalPadding *= factor
            lineFill.horizontalPadding *= factor
            lineFill.verticalOffset *= factor
            lineFill.horizontalOffset *= factor
            lineFill.cornerRadius *= factor
            out.lineFill = lineFill
        }
        out.lineOverrides = text.lineOverrides.map { line in
            var line = line
            line.fontSize = line.fontSize.map { $0 * factor }
            line.tracking = line.tracking.map { $0 * factor }
            line.firstLineIndent = line.firstLineIndent.map { $0 * factor }
            line.leftIndent = line.leftIndent.map { $0 * factor }
            line.rightIndent = line.rightIndent.map { $0 * factor }
            return line
        }
        out.styleRuns = text.styleRuns.map { run in
            var run = run
            run.fontSize = run.fontSize.map { $0 * factor }
            run.tracking = run.tracking.map { $0 * factor }
            if var outline = run.outline {
                outline.width *= factor
                run.outline = outline
            }
            return run
        }
        // Worked out for the room's line breaks when the text is drawn.
        out.balancedLineInsets = []
        return out
    }
}
