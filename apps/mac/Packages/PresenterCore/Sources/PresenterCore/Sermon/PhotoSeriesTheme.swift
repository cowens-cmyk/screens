import Foundation

/// A sermon series theme built from one piece of series art and what
/// Claude (or the palette alone) read from it: the art itself as the Title
/// slide, a calm background made from it behind points, scripture and
/// lyrics, and a lower-third bar in the series' colors, with every text
/// color checked for contrast against what it sits on.
public enum PhotoSeriesTheme {
    public struct Input: Sendable {
        public var name: String
        /// Sanitized (see ArtAnalysis.sanitized).
        public var analysis: ArtAnalysis
        /// PostScript names of the faces to use.
        public var headingFont: String
        public var bodyFont: String
        public var verseFont: String
        /// The art cropped to 1920×1080 around its focus point.
        public var titleArtMediaID: String?
        /// The art's size in pixels, to place text in its calm zone.
        public var artWidth: Double
        public var artHeight: Double
        /// The blurred, dimmed art, when the analysis chose that.
        public var textBackgroundMediaID: String?
        /// Colors measured from the rendered text background where text
        /// sits. Gradient and solid backgrounds are measured here instead.
        public var textBackgroundSamples: [SeriesColor]
        /// Colors measured from the title art inside `titleBox`.
        public var titleSamples: [SeriesColor]
        /// Staff's own picks from Adjust Colors, used as they are on the
        /// full-screen designs.
        public var textColorOverride: SeriesColor?
        public var accentColorOverride: SeriesColor?
        public var barColorOverride: SeriesColor?

        public init(
            name: String, analysis: ArtAnalysis, headingFont: String, bodyFont: String, verseFont: String,
            titleArtMediaID: String?, artWidth: Double, artHeight: Double, textBackgroundMediaID: String?,
            textBackgroundSamples: [SeriesColor] = [], titleSamples: [SeriesColor] = [],
            textColorOverride: SeriesColor? = nil, accentColorOverride: SeriesColor? = nil,
            barColorOverride: SeriesColor? = nil
        ) {
            self.name = name
            self.analysis = analysis
            self.headingFont = headingFont
            self.bodyFont = bodyFont
            self.verseFont = verseFont
            self.titleArtMediaID = titleArtMediaID
            self.artWidth = artWidth
            self.artHeight = artHeight
            self.textBackgroundMediaID = textBackgroundMediaID
            self.textBackgroundSamples = textBackgroundSamples
            self.titleSamples = titleSamples
            self.textColorOverride = textColorOverride
            self.accentColorOverride = accentColorOverride
            self.barColorOverride = barColorOverride
        }
    }

    /// The colors the theme ends up with, after the contrast checks.
    public struct Colors: Equatable, Sendable {
        public var text: SeriesColor
        public var accent: SeriesColor
        public var titleText: SeriesColor
        public var bar: SeriesColor
        public var barOpacity: Double
        public var barText: SeriesColor
        public var barAccent: SeriesColor
        /// The rule along the bar's top: a shape, not text, so it keeps the
        /// series' own accent unless that would vanish into the bar.
        public var barRule: SeriesColor
        public var background: SeriesColor
    }

    public typealias Box = (x: Double, y: Double, width: Double, height: Double)

    /// Where the Title slide's text goes: the art's calm zone when it has
    /// one in frame, otherwise a band across the bottom (the art usually
    /// carries its title in the middle) or the usual title box when the
    /// art has no lettering of its own.
    public static func titleBox(for analysis: ArtAnalysis, artWidth: Double, artHeight: Double) -> Box {
        let visible = ArtCrop.visible(imageWidth: artWidth, imageHeight: artHeight,
                                      focusX: analysis.focusX, focusY: analysis.focusY)
        if analysis.titleUsesArt, let zone = ArtCrop.slideRect(of: analysis.titleZone, visible: visible) {
            // Kept off the very edges, where a projector or a stream crops.
            let inset = 48.0
            let x = max(zone.x + 24, inset), y = max(zone.y + 16, inset)
            let right = min(zone.x + zone.width - 24, 1920 - inset)
            let bottom = min(zone.y + zone.height - 16, 1080 - inset)
            if right - x >= 300, bottom - y >= 90 { return (x, y, right - x, bottom - y) }
        }
        if analysis.titleUsesArt && analysis.artHasTitle { return (160, 850, 1600, 170) }
        return (160, 300, 1600, 480)
    }

    /// Text colors that read on what they sit on. Staff's own picks win on
    /// the full-screen designs; the bar always keeps its text readable,
    /// darkening the bar if no text color alone would do.
    public static func colors(for input: Input) -> Colors {
        let analysis = input.analysis
        let palette = analysis.palette.compactMap { SeriesColor(hex: $0) }
        let darkest = palette.min { $0.luminance < $1.luminance } ?? .black
        let backgroundSamples = input.textBackgroundSamples.isEmpty
            ? backgroundColors(analysis.textBackground, fallback: darkest)
            : input.textBackgroundSamples
        let wantedText = SeriesColor(hex: analysis.textColor) ?? .white
        let wantedAccent = SeriesColor(hex: analysis.accentColor) ?? wantedText
        let text = input.textColorOverride ?? SeriesContrast.readable(wantedText, on: backgroundSamples)
        let accent = input.accentColorOverride ?? SeriesContrast.readable(wantedAccent, on: backgroundSamples)
        let titleText = input.textColorOverride
            ?? (input.titleSamples.isEmpty ? text : SeriesContrast.readable(wantedText, on: input.titleSamples))

        let bar = input.barColorOverride ?? SeriesColor(hex: analysis.lowerThird.color) ?? darkest
        let barAccent = input.accentColorOverride ?? SeriesColor(hex: analysis.lowerThird.accentColor) ?? accent
        let fixed = barText(
            bar: bar, opacity: analysis.lowerThird.opacity,
            text: SeriesColor(hex: analysis.lowerThird.textColor) ?? .white, accent: barAccent)
        let rule = barAccent.contrast(with: bar.composited(alpha: fixed.opacity, over: .black)) >= 2 ? barAccent : fixed.accent
        return Colors(text: text, accent: accent, titleText: titleText, bar: bar, barOpacity: fixed.opacity,
                      barText: fixed.text, barAccent: fixed.accent, barRule: rule,
                      background: backgroundSamples.first ?? darkest)
    }

    /// Lower-third text over a camera shot: the bar is see-through, so the
    /// text is checked against the bar laid over both black and white, the
    /// darkest and brightest the shot behind it can be.
    public static func barText(bar: SeriesColor, opacity: Double, text: SeriesColor, accent: SeriesColor)
        -> (text: SeriesColor, accent: SeriesColor, opacity: Double) {
        var opacity = min(max(opacity, 0), 1)
        func backdrops() -> [SeriesColor] {
            [bar.composited(alpha: opacity, over: .black), bar.composited(alpha: opacity, over: .white)]
        }
        var fixedText = SeriesContrast.readable(text, on: backdrops())
        while SeriesContrast.worst(fixedText, on: backdrops()) < SeriesContrast.minimum, opacity < 1 {
            opacity = min(1, opacity + 0.05)
            fixedText = SeriesContrast.readable(text, on: backdrops())
        }
        return (fixedText, SeriesContrast.readable(accent, on: backdrops()), opacity)
    }

    static func backgroundColors(_ background: ArtAnalysis.TextBackground, fallback: SeriesColor) -> [SeriesColor] {
        let colors = background.colors.compactMap { SeriesColor(hex: $0) }
        guard !colors.isEmpty else { return [fallback] }
        // A gradient's in-between colors are checked too, so text that
        // reads on both ends can't fail in the middle.
        guard colors.count > 1 else { return colors }
        return zip(colors, colors.dropFirst()).flatMap { [$0, $0.mixed(with: $1, amount: 0.5), $1] }
    }

    // MARK: Building

    public static func make(_ input: Input, id: String = UUID().uuidString) -> Theme {
        let analysis = input.analysis
        let colors = colors(for: input)
        let blurred = analysis.textBackground.kind == .blurredArt ? input.textBackgroundMediaID : nil
        let style = SermonSeriesStyle(
            name: input.name, backgroundMediaID: blurred, lowerThirdMediaID: nil,
            font: input.bodyFont, boldFont: input.headingFont,
            textColor: colors.text.hex(), accentColor: colors.accent.hex(), verseFont: input.verseFont,
            lowerThirdTextColor: colors.barText.hex(), lowerThirdAccentColor: colors.barAccent.hex(),
            headingCaps: analysis.headingAllCaps)
        var theme = SermonSeriesTheme.make(style, id: id)
        theme.backgroundColorHex = colors.background.mixed(with: .black, amount: 0.3).hex()

        // Gradient and solid backgrounds are drawn as shapes, so they stay
        // sharp and can be changed later in the theme editor.
        let backdrop = blurred == nil ? backgroundShape(analysis.textBackground, colors: colors) : nil
        theme.slides = theme.slides?.map { design in
            var design = design
            if SermonSeriesTheme.isLowerThird(design) {
                design.objects = lowerThirdObjects(design.objects, analysis: analysis.lowerThird, colors: colors)
            } else if design.name == SermonSeriesTheme.titleCategory {
                design.objects = titleObjects(design.objects, input: input, colors: colors, backdrop: backdrop)
            } else if let backdrop {
                design.objects.append(backdrop)
            }
            return design
        }
        return theme
    }

    private static func backgroundShape(_ background: ArtAnalysis.TextBackground, colors: Colors) -> SlideObject {
        let stops = background.colors.compactMap { SeriesColor(hex: $0) }
        let fill: ObjectFill
        if background.kind == .gradient, stops.count >= 2 {
            fill = ObjectFill(
                fillKind: .linearGradient, gradientAngleDegrees: 90,
                gradientStops: stops.enumerated().map { index, color in
                    GradientStop(colorHex: color.hex(), position: Double(index) / Double(stops.count - 1))
                })
        } else {
            fill = ObjectFill(fillKind: .solid, colorHex: (stops.first ?? colors.background).hex())
        }
        return SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Series Background", text: "",
                           x: 0, y: 0, width: 1920, height: 1080, shapeKind: .rectangle, fill: fill)
    }

    /// Title: the art full screen, with the message title in its calm zone.
    /// When the art already carries the series title, the slide's own text
    /// is set smaller so it reads as a caption to the art, not a rival.
    private static func titleObjects(_ objects: [SlideObject], input: Input, colors: Colors, backdrop: SlideObject?) -> [SlideObject] {
        let analysis = input.analysis
        let usesArt = analysis.titleUsesArt && input.titleArtMediaID != nil
        var rest = objects.filter { $0.objectKind != .text }
        if usesArt, let art = input.titleArtMediaID {
            rest = [SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: "Series Art", text: "",
                x: 0, y: 0, width: 1920, height: 1080, shapeKind: .rectangle,
                fill: ObjectFill(fillKind: .media, mediaId: art, mediaScaleMode: .fill))]
        } else if let backdrop {
            rest.append(backdrop)
        }
        guard var title = objects.first(where: { $0.name == SermonSeriesTheme.titleText }),
              var subtitle = objects.first(where: { $0.name == SermonSeriesTheme.subtitleText })
        else { return objects.filter { $0.objectKind == .text } + rest }
        guard usesArt else { return [title, subtitle] + rest }

        let box = titleBox(for: analysis, artWidth: input.artWidth, artHeight: input.artHeight)
        let caption = analysis.artHasTitle
        let titleHeight = box.height * (caption ? 0.62 : 0.72)
        let size = min(caption ? 72 : 110, titleHeight * 0.8).rounded()
        let align: TextHorizontalAlignment = box.x + box.width / 2 < 1920 * 0.38 ? .left
            : box.x + box.width / 2 > 1920 * 0.62 ? .right : .center
        // A soft shadow keeps light text off a busy patch of art.
        let shadow = colors.titleText.luminance > 0.5
            ? ObjectShadow(colorHex: "#00000099", blurRadius: 14, offsetX: 0, offsetY: 2) : nil
        func set(_ object: inout SlideObject, y: Double, height: Double, size: Double, color: SeriesColor) {
            object.x = box.x
            object.y = y
            object.width = box.width
            object.height = height
            object.textStyle?.fontSize = size
            object.textStyle?.minFontSize = (size * 0.5).rounded()
            object.textStyle?.colorHex = color.hex()
            object.textStyle?.horizontalAlignment = align
            object.textStyle?.shadow = shadow
            if object.textStyle?.textTransform == .uppercase { object.textStyle?.tracking = (size * 0.08).rounded() }
        }
        set(&title, y: box.y, height: titleHeight, size: size, color: colors.titleText)
        set(&subtitle, y: box.y + titleHeight, height: box.height - titleHeight, size: (size * 0.45).rounded(),
            color: colors.titleText)
        return [title, subtitle] + rest
    }

    /// The bar, drawn as shapes in the series colors, under the text.
    private static func lowerThirdObjects(_ objects: [SlideObject], analysis bar: ArtAnalysis.LowerThird, colors: Colors) -> [SlideObject] {
        let floating = bar.placement == .floating
        var texts = objects.filter { $0.objectKind == .text }
        if floating {
            // Pulled in so the text keeps its margin inside the inset bar.
            for index in texts.indices {
                texts[index].x = (texts[index].x ?? 80) + 30
                texts[index].width = (texts[index].width ?? 1760) - 60
            }
        }
        let opacity = colors.barOpacity
        let color = colors.bar
        func shape(_ name: String, x: Double, y: Double, w: Double, h: Double, fill: ObjectFill,
                   rounded: Bool = false, stroke: ObjectStroke? = nil) -> SlideObject {
            SlideObject(id: UUID().uuidString, objectKind: .shape, name: name, text: "",
                        x: x, y: y, width: w, height: h,
                        shapeKind: rounded ? .roundedRectangle : .rectangle, cornerRadius: rounded ? 22 : nil,
                        fill: fill, stroke: stroke)
        }
        var shapes: [SlideObject] = []
        let frame: Box = floating ? (50, 858, 1820, 200) : (0, 860, 1920, 220)
        switch (bar.style, floating) {
        case (.gradient, false):
            // Rises out of the bottom of the frame; solid by the time it
            // reaches the text.
            shapes.append(shape("Bar", x: 0, y: 740, w: 1920, h: 340, fill: ObjectFill(
                fillKind: .linearGradient, gradientAngleDegrees: 90,
                gradientStops: [GradientStop(colorHex: color.hex(alpha: 0), position: 0),
                                GradientStop(colorHex: color.hex(alpha: opacity), position: 0.4),
                                GradientStop(colorHex: color.hex(alpha: opacity), position: 1)])))
        case (.gradient, true):
            shapes.append(shape("Bar", x: frame.x, y: frame.y, w: frame.width, h: frame.height, fill: ObjectFill(
                fillKind: .linearGradient, gradientAngleDegrees: 0,
                gradientStops: [GradientStop(colorHex: color.hex(alpha: opacity), position: 0),
                                GradientStop(colorHex: color.mixed(with: .black, amount: 0.3).hex(alpha: opacity), position: 1)]),
                rounded: true))
        case (.glass, _):
            let edge = SeriesColor.white.hex(alpha: 0.28)
            shapes.append(shape("Bar", x: frame.x, y: frame.y, w: frame.width, h: frame.height,
                                fill: ObjectFill(fillKind: .solid, colorHex: color.hex(alpha: opacity)),
                                rounded: floating, stroke: floating ? ObjectStroke(colorHex: edge, width: 2) : nil))
            if !floating {
                shapes.append(shape("Bar Edge", x: 0, y: frame.y, w: 1920, h: 2,
                                    fill: ObjectFill(fillKind: .solid, colorHex: edge)))
            }
        case (.solid, _):
            shapes.append(shape("Bar", x: frame.x, y: frame.y, w: frame.width, h: frame.height,
                                fill: ObjectFill(fillKind: .solid, colorHex: color.hex(alpha: opacity)),
                                rounded: floating))
        }
        if bar.accentRule {
            let ruleX = (texts.first?.x ?? 80)
            shapes.insert(shape("Accent Rule", x: ruleX, y: floating ? frame.y + 14 : frame.y, w: 140, h: 6,
                                fill: ObjectFill(fillKind: .solid, colorHex: colors.barRule.hex())), at: 0)
        }
        return texts + shapes
    }
}
