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

    /// How far the background behind a song's words can be darkened.
    public static let dimRange: ClosedRange<Double> = 0...0.6
    /// The id of the darkening laid over the background during a song.
    static let dimID = "side-tvs-dim"

    /// The scene for the Side TVs while `presentation` is live. `dim`
    /// darkens the background behind a song's words (0 leaves it).
    public static func scene(
        _ scene: RenderScene, presentation: Presentation?, scale: Double, dim: Double = 0
    ) -> RenderScene {
        guard carriesLyrics(presentation) else { return scene }
        return Self.scene(enlargingTextOf: scene, scale: scale, dim: dim)
    }

    /// The scene with the slide's own text drawn `scale` times the size.
    /// The lyrics alone on a slide (the usual case) get the whole safe area
    /// of the TV and wrap in it: a song's lines are set nearly as wide as
    /// the wall, so a box that only grew around its centre was held to the
    /// wall's width, and with each line kept whole the words shrank back to
    /// the wall's size, the same picture as the room's. Several boxes each
    /// grow around their own centre so they don't cover each other. Every
    /// other layer and item is left as it is.
    public static func scene(enlargingTextOf scene: RenderScene, scale: Double, dim: Double = 0) -> RenderScene {
        let factor = min(max(scale, scaleRange.lowerBound), scaleRange.upperBound)
        guard let index = scene.layers.firstIndex(where: { $0.kind == .slide }) else { return scene }
        var out = scene
        let canvas = scene.canvasSize
        let lyrics = scene.layers[index].items.filter(enlarges)
        // The lyrics alone on the slide go to the middle of the TV, so a
        // band the theme drew behind them at the top of the wall would be
        // left there empty: it stays on the wall, not the TVs.
        if lyrics.count == 1, let lyricFrame = lyrics.first?.frame {
            out.layers[index].items.removeAll { backsLyrics($0, lyricFrame: lyricFrame, canvas: canvas) }
        }
        out = dimmed(out, by: dim, slideLayer: index)
        guard factor > 1.001 || lyrics.count == 1 else { return out }
        let fills = lyrics.count == 1
        func grow(_ item: RenderItem) -> RenderItem {
            fills ? filling(item, by: factor, canvas: canvas) : enlarged(item, by: factor, canvas: canvas)
        }
        out.layers[index].items = out.layers[index].items.map { item in
            guard enlarges(item) else { return item }
            var grown = grow(item)
            // A page turn or a build carries the box's other states; they
            // grow with it so the move doesn't jump between sizes.
            grown.animationSteps = item.animationSteps.map { step in
                var step = step
                if let from = step.fromItem, enlarges(from) { step.fromItem = grow(from) }
                if let to = step.toItem, enlarges(to) { step.toItem = grow(to) }
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

    /// A piece of the theme drawn behind the lyrics: a bar or band (not its
    /// words, such as the CCLI line) that overlaps the lyrics' box and covers
    /// less than half the picture. A backdrop that fills the screen stays.
    static func backsLyrics(_ item: RenderItem, lyricFrame: CGRect, canvas: CGSize) -> Bool {
        guard item.id.hasPrefix("theme-"), canvas.width > 0, canvas.height > 0 else { return false }
        if case .text = item.content { return false }
        let overlap = item.frame.intersection(lyricFrame)
        guard !overlap.isNull, overlap.width * overlap.height > 0 else { return false }
        return item.frame.width * item.frame.height < canvas.width * canvas.height * 0.5
    }

    /// The background darkened behind the words: a black layer over every
    /// media and background layer, under the slide's own pieces.
    static func dimmed(_ scene: RenderScene, by dim: Double, slideLayer index: Int) -> RenderScene {
        let amount = min(max(dim, dimRange.lowerBound), dimRange.upperBound)
        guard amount > 0.001 else { return scene }
        var out = scene
        let veil = RenderItem(
            id: dimID, frame: CGRect(origin: .zero, size: scene.canvasSize),
            content: .solid(SceneColor(red: 0, green: 0, blue: 0, alpha: amount)))
        out.layers[index].items.insert(veil, at: 0)
        return out
    }

    static func enlarged(_ item: RenderItem, by factor: Double, canvas: CGSize) -> RenderItem {
        guard case .text(let text) = item.content else { return item }
        var out = item
        out.frame = frame(item.frame, scaledBy: factor, canvas: canvas)
        out.content = .text(styled(text, scaledBy: factor))
        return out
    }

    /// The lyrics box given the whole safe area, its words `factor` times
    /// the size and in the middle of the TV, across and down: on the wall
    /// they sit in a band at the top, where a TV beside it reads them worst.
    static func filling(_ item: RenderItem, by factor: Double, canvas: CGSize) -> RenderItem {
        guard case .text(let text) = item.content, canvas.width > 0, canvas.height > 0 else { return item }
        let whole = CGRect(origin: .zero, size: canvas)
        let safe = whole.insetBy(dx: canvas.width * safeMargin, dy: canvas.height * safeMargin)
        var out = item
        out.frame = safe
        var styled = styled(text, scaledBy: factor)
        styled.alignment = .center
        styled.verticalAlignment = .middle
        out.content = .text(readable(styled, canvas: canvas))
        return out
    }

    /// A soft shadow under words that have none, so they read over a
    /// moving background on a TV. A theme's own shadow or outline is kept.
    static func readable(_ text: StyledText, canvas: CGSize) -> StyledText {
        guard text.shadow == nil, text.outline == nil else { return text }
        var out = text
        let unit = canvas.height / 1080
        out.shadow = TextShadow(
            color: SceneColor(red: 0, green: 0, blue: 0, alpha: 0.7),
            blurRadius: 10 * unit, offsetX: 0, offsetY: 3 * unit)
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

    /// How much larger than the room's the words are at the least, however
    /// long the lines: the TVs never show the wall's picture.
    public static let floorScale = 1.25

    /// The type and every measure drawn with it, `factor` times larger. A
    /// line too long for the TV wraps, in lines of about equal length, and
    /// the words shrink to fit only as far as `floorScale` times the room's
    /// size (or `factor`, when that is smaller).
    static func styled(_ text: StyledText, scaledBy factor: Double) -> StyledText {
        var out = text
        out.fontSize = text.fontSize * factor
        out.autoShrink = true
        out.minFontSize = text.fontSize * min(factor, floorScale)
        out.keepLinesWhole = false
        out.balancedWrap = true
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
