import Foundation

/// A sermon series theme built from one piece of series art and what
/// Claude (or the palette alone) read from it: the art itself as the Title
/// slide, a calm background made from it behind points, scripture and
/// lyrics, and a lower-third bar in the series' colors, with every text
/// color checked for contrast against what it sits on. The same build makes
/// a general theme from any church graphic (see Kind).
public enum PhotoSeriesTheme {
    /// What the art becomes: a sermon series (the five message designs and
    /// four lower thirds), or a general theme for songs, announcements,
    /// scripture and points in the same look.
    public enum Kind: Sendable {
        case sermonSeries
        case general
    }

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
        /// Staff's own picks from Edit Colors & Fonts, used as they are on the
        /// full-screen designs.
        public var textColorOverride: SeriesColor?
        public var accentColorOverride: SeriesColor?
        public var barColorOverride: SeriesColor?
        public var kind: Kind
        /// A lower-third image of its own (a Claude Design download's
        /// transparent PNG), drawn in place of the bar shapes.
        public var lowerThirdMediaID: String?
        /// That image's bar where its text sits (see barSamples). Empty
        /// when nothing there is solid: the text is over the camera shot.
        public var lowerThirdSamples: [SeriesColor]

        public init(
            name: String, analysis: ArtAnalysis, headingFont: String, bodyFont: String, verseFont: String,
            titleArtMediaID: String?, artWidth: Double, artHeight: Double, textBackgroundMediaID: String?,
            textBackgroundSamples: [SeriesColor] = [], titleSamples: [SeriesColor] = [],
            textColorOverride: SeriesColor? = nil, accentColorOverride: SeriesColor? = nil,
            barColorOverride: SeriesColor? = nil, kind: Kind = .sermonSeries,
            lowerThirdMediaID: String? = nil, lowerThirdSamples: [SeriesColor] = []
        ) {
            self.kind = kind
            self.lowerThirdMediaID = lowerThirdMediaID
            self.lowerThirdSamples = lowerThirdSamples
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
        /// How solid a veil (see `scrimColor`) between the background and
        /// the text on the full-screen designs has to be for the text to
        /// read: 0 when it reads without one. Busy mid-tone art, where
        /// neither white nor black text reaches the minimum, needs one.
        public var textScrim: Double = 0
        /// The art behind the text is busy, so the veil is a plate behind
        /// each design's block of text rather than over the whole background.
        public var textPlate = false
        /// The same for the Title slide's text over the art, in its box.
        public var titleScrim: Double = 0
        /// The same for lower-third text on an image bar (a download's),
        /// which can't itself be made more solid.
        public var barScrim: Double = 0
    }

    /// What generated body text (points, verses, lyrics) is held to on the
    /// full-screen designs. A projector washes colors out, so text that only
    /// just makes WCAG's 4.5:1 on paper reads weakly in the room. References
    /// and subtitles, set in the accent, are held to 4.5:1; staff's own picks
    /// are used as picked, with a veil under them if they don't reach 4.5:1.
    public static let bodyContrast = 7.0

    /// How solid a plate behind text on busy art is at least: enough to
    /// quiet the art behind the words, not to hide it.
    static let plateOpacity = 0.6

    /// The veil that helps text most: black under light text, white under
    /// dark.
    public static func scrimColor(for text: SeriesColor) -> SeriesColor {
        text.contrast(with: .black) >= text.contrast(with: .white) ? .black : .white
    }

    /// Whether the art behind a block of text is busy: neighboring samples
    /// swing in lightness (stripes, lettering, a sharp photo), so even text
    /// that passes on average breaks up over it. A smooth gradient or a
    /// soft blur isn't busy.
    public static func isBusy(_ samples: [SeriesColor]) -> Bool {
        guard samples.count >= 2 else { return false }
        func lightness(_ color: SeriesColor) -> Double {
            let y = color.luminance
            return y > 0.008856 ? 116 * cbrt(y) - 16 : 903.3 * y
        }
        let values = samples.map(lightness)
        let steps = zip(values, values.dropFirst()).map { abs($0 - $1) }
        return steps.reduce(0, +) / Double(steps.count) > 10
    }

    /// How solid a veil (in `veil`, or `scrimColor(for:)` the first text)
    /// laid over the samples has to be for every one of `texts` to reach
    /// `minimum` against them, rounded up to the next 5%: 0 when they
    /// already do.
    public static func scrimOpacity(for texts: [SeriesColor], on samples: [SeriesColor],
                                    minimum: Double = SeriesContrast.minimum, veil: SeriesColor? = nil) -> Double {
        guard !samples.isEmpty, let first = texts.first else { return 0 }
        let veil = veil ?? scrimColor(for: first)
        func passes(_ alpha: Double) -> Bool {
            let veiled = samples.map { veil.composited(alpha: alpha, over: $0) }
            return texts.allSatisfy { SeriesContrast.worst($0, on: veiled) >= minimum }
        }
        guard !passes(0) else { return 0 }
        guard passes(1) else { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if passes(mid) { high = mid } else { low = mid }
        }
        return min(1, (high * 20).rounded(.up) / 20)
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

    /// A color that reads is kept. One that has to move is moved well clear
    /// of the line where it can be: a projector washes out text that only
    /// just passes on paper (white asked for on cream art came out a mid
    /// grey).
    static func fixed(_ wanted: SeriesColor, on samples: [SeriesColor]) -> SeriesColor {
        guard SeriesContrast.worst(wanted, on: samples) < SeriesContrast.minimum else { return wanted }
        let strong = SeriesContrast.readable(wanted, on: samples, minimum: bodyContrast)
        return SeriesContrast.worst(strong, on: samples) >= bodyContrast
            ? strong : SeriesContrast.readable(wanted, on: samples)
    }

    /// Full-screen text on a background: the body color held to
    /// `bodyContrast` (moved the least it can, else the better of white or
    /// black), the veil it needs to get there, and the accent made to read
    /// on that. Busy art always gets a plate. Picked colors stay as picked,
    /// and the veil is made solid enough for them to reach 4.5:1.
    static func backed(text wantedText: SeriesColor, accent wantedAccent: SeriesColor, on samples: [SeriesColor],
                       textPicked: Bool, accentPicked: Bool)
        -> (text: SeriesColor, accent: SeriesColor, scrim: Double, plate: Bool) {
        guard !samples.isEmpty else { return (wantedText, wantedAccent, 0, false) }
        let bodyMinimum = textPicked ? SeriesContrast.minimum : bodyContrast
        var text = wantedText
        if !textPicked, SeriesContrast.worst(text, on: samples) < bodyContrast {
            let strong = SeriesContrast.readable(text, on: samples, minimum: bodyContrast)
            let passing = SeriesContrast.readable(text, on: samples)
            text = SeriesContrast.worst(strong, on: samples) >= bodyContrast ? strong
                : SeriesContrast.worst(passing, on: samples) >= SeriesContrast.minimum ? passing
                : SeriesContrast.plainText(on: samples)
        }
        let veil = scrimColor(for: text)
        let plate = isBusy(samples)
        var scrim = scrimOpacity(for: [text], on: samples, minimum: bodyMinimum, veil: veil)
        if plate { scrim = max(scrim, plateOpacity) }
        var accent = wantedAccent
        if accentPicked {
            scrim = max(scrim, scrimOpacity(for: [accent], on: samples, veil: veil))
        } else {
            accent = fixed(wantedAccent, on: samples.map { veil.composited(alpha: scrim, over: $0) })
        }
        return (text, accent, scrim, plate)
    }

    /// A series Claude drew from its name alone (SeriesGenerator), whose
    /// background and bar are its own artwork: built like any series, with
    /// the colors Claude chose checked against that artwork where the text
    /// sits, as a series from a photo is, and a scrim under text no color
    /// would read on. With no solid bar where its text goes, lower-third
    /// text is checked against the darkest and brightest camera shot.
    public static func make(_ style: SermonSeriesStyle, backgroundSamples: [SeriesColor], barSamples: [SeriesColor],
                            id: String = UUID().uuidString) -> Theme {
        var style = style
        func color(_ hex: String?, _ fallback: SeriesColor) -> SeriesColor { hex.flatMap(SeriesColor.init(hex:)) ?? fallback }
        let background = backgroundSamples.isEmpty ? [SeriesColor.black] : backgroundSamples
        let bar = barSamples.isEmpty ? [SeriesColor.black, .white] : barSamples
        let full = backed(text: color(style.textColor, .white), accent: color(style.accentColor, .white),
                          on: background, textPicked: false, accentPicked: false)
        let barText = fixed(color(style.lowerThirdTextColor, .white), on: bar)
        let barAccent = fixed(color(style.lowerThirdAccentColor, barText), on: bar)
        style.textColor = full.text.hex()
        style.accentColor = full.accent.hex()
        style.lowerThirdTextColor = barText.hex()
        style.lowerThirdAccentColor = barAccent.hex()
        var colors = Colors(text: full.text, accent: full.accent, titleText: full.text, bar: bar[0], barOpacity: 1,
                            barText: barText, barAccent: barAccent, barRule: barAccent, background: background[0])
        colors.textScrim = full.scrim
        colors.textPlate = full.plate
        colors.barScrim = scrimOpacity(for: [barText, barAccent], on: bar)

        var theme = SermonSeriesTheme.make(style, id: id)
        theme.slides = theme.slides?.map { design in
            var design = design
            if SermonSeriesTheme.isLowerThird(design) {
                if colors.barScrim > 0 { design.objects.append(barScrim(colors)) }
            } else if let backing = textBacking(colors, under: design.objects) {
                design.objects.append(backing)
            }
            design.objects = SermonSeriesTheme.layered(design.objects)
            return design
        }
        return SermonSeriesTheme.completed(theme)
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
        let full = backed(text: input.textColorOverride ?? wantedText, accent: input.accentColorOverride ?? wantedAccent,
                          on: backgroundSamples, textPicked: input.textColorOverride != nil,
                          accentPicked: input.accentColorOverride != nil)
        let text = full.text
        let accent = full.accent
        let titleText = input.textColorOverride
            ?? (input.titleSamples.isEmpty ? text : fixed(wantedText, on: input.titleSamples))

        let barAccent = input.accentColorOverride ?? SeriesColor(hex: analysis.lowerThird.accentColor) ?? accent
        let wantedBarText = SeriesColor(hex: analysis.lowerThird.textColor) ?? .white
        if input.lowerThirdMediaID != nil {
            // An image bar can't be made more solid, so only its text moves:
            // the download's own colors when they read on the bar, else the
            // least change toward white or black. With nothing solid where
            // the text sits, the text is over the camera shot itself.
            let samples = input.lowerThirdSamples.isEmpty ? [SeriesColor.black, .white] : input.lowerThirdSamples
            let measured = input.lowerThirdSamples.first ?? darkest
            let fixedAccent = SeriesContrast.readable(barAccent, on: samples)
            let fixedBarText = SeriesContrast.readable(wantedBarText, on: samples)
            var colors = Colors(text: text, accent: accent, titleText: titleText, bar: measured, barOpacity: 1,
                                barText: fixedBarText, barAccent: fixedAccent,
                                barRule: fixedAccent, background: backgroundSamples.first ?? darkest)
            colors.barScrim = scrimOpacity(for: [fixedBarText, fixedAccent], on: samples)
            return scrimmed(colors, input: input, full: full)
        }
        let bar = input.barColorOverride ?? SeriesColor(hex: analysis.lowerThird.color) ?? darkest
        let fixed = barText(
            bar: bar, opacity: analysis.lowerThird.opacity,
            text: wantedBarText, accent: barAccent)
        let rule = barAccent.contrast(with: bar.composited(alpha: fixed.opacity, over: .black)) >= 2 ? barAccent : fixed.accent
        let colors = Colors(text: text, accent: accent, titleText: titleText, bar: bar, barOpacity: fixed.opacity,
                            barText: fixed.text, barAccent: fixed.accent, barRule: rule,
                            background: backgroundSamples.first ?? darkest)
        return scrimmed(colors, input: input, full: full)
    }

    /// The veils the full-screen text needs, measured with the colors it
    /// ended up with. Staff's own picks included: a pick that doesn't read
    /// gets a veil under it rather than being changed. The title over the
    /// art is a heading, held to 4.5:1, with a plate behind it on busy art.
    private static func scrimmed(_ colors: Colors, input: Input,
                                 full: (text: SeriesColor, accent: SeriesColor, scrim: Double, plate: Bool)) -> Colors {
        var colors = colors
        colors.textScrim = full.scrim
        colors.textPlate = full.plate
        let title = scrimOpacity(for: [colors.titleText], on: input.titleSamples)
        colors.titleScrim = isBusy(input.titleSamples) ? max(title, plateOpacity) : title
        return colors
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

    /// What a lower-third image's text is checked against, from its pixels
    /// where the text sits (color with alpha not premultiplied). Only the
    /// bar counts: clear pixels around it are the camera shot, not
    /// something the text sits on, and counting them would rule out every
    /// color the download chose. A bar that is itself see-through is laid
    /// over black and white, the darkest and brightest shot behind it.
    public static func barSamples(_ pixels: [(color: SeriesColor, alpha: Double)]) -> [SeriesColor] {
        pixels.filter { $0.alpha > 0.5 }.flatMap { pixel -> [SeriesColor] in
            guard pixel.alpha < 0.99 else { return [pixel.color] }
            return [pixel.color.composited(alpha: pixel.alpha, over: .black),
                    pixel.color.composited(alpha: pixel.alpha, over: .white)]
        }
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
        // Objects are drawn in order, the last on top, so each design lists
        // its background, then any scrim, then its text.
        theme.slides = theme.slides?.map { design in
            var design = design
            if SermonSeriesTheme.isLowerThird(design) {
                if let image = input.lowerThirdMediaID {
                    var under = [SlideObject(
                        id: UUID().uuidString, objectKind: .shape, name: "Series Lower Third", text: "",
                        x: 0, y: 0, width: 1920, height: 1080, shapeKind: .rectangle,
                        fill: ObjectFill(fillKind: .media, mediaId: image, mediaScaleMode: .fill))]
                    if colors.barScrim > 0 { under.append(barScrim(colors)) }
                    design.objects = under + design.objects.filter { $0.objectKind == .text }
                } else {
                    design.objects = lowerThirdObjects(design.objects, analysis: analysis.lowerThird, colors: colors)
                }
            } else if design.name == SermonSeriesTheme.titleCategory {
                design.objects = titleObjects(design.objects, input: input, colors: colors, backdrop: backdrop)
            } else {
                if let backdrop { design.objects.insert(backdrop, at: 0) }
                if let backing = textBacking(colors, under: design.objects) { design.objects.append(backing) }
            }
            design.objects = SermonSeriesTheme.layered(design.objects)
            return design
        }
        let made = input.kind == .general ? SermonSeriesTheme.general(from: theme) : theme
        return SermonSeriesTheme.completed(made)
    }

    /// What goes between the background and a full-screen design's text,
    /// if anything: on busy art a soft plate behind the design's block of
    /// text, so the words sit on something calm while the art shows around
    /// them; otherwise, when the text needs help, a veil over the whole
    /// background.
    static func textBacking(_ colors: Colors, under objects: [SlideObject]) -> SlideObject? {
        guard colors.textScrim > 0 else { return nil }
        let fill = ObjectFill(fillKind: .solid, colorHex: scrimColor(for: colors.text).hex(alpha: colors.textScrim))
        let texts = objects.filter { $0.objectKind == .text }
        guard colors.textPlate, !texts.isEmpty else {
            return SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Scrim", text: "",
                               x: 0, y: 0, width: 1920, height: 1080, shapeKind: .rectangle, fill: fill)
        }
        let left = texts.map { $0.x ?? 0 }.min() ?? 0
        let top = texts.map { $0.y ?? 0 }.min() ?? 0
        let right = texts.map { ($0.x ?? 0) + ($0.width ?? 1920) }.max() ?? 1920
        let bottom = texts.map { ($0.y ?? 0) + ($0.height ?? 1080) }.max() ?? 1080
        return plate(x: left, y: top, width: right - left, height: bottom - top, fill: fill)
    }

    /// A rounded plate around a block of text, padded and kept on the slide.
    static func plate(x: Double, y: Double, width: Double, height: Double, fill: ObjectFill) -> SlideObject {
        let pad = 40.0
        let left = max(24, x - pad), top = max(24, y - pad)
        let right = min(1896, x + width + pad), bottom = min(1056, y + height + pad)
        return SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Scrim", text: "",
                           x: left, y: top, width: right - left, height: bottom - top,
                           shapeKind: .roundedRectangle, cornerRadius: 28, fill: fill)
    }

    /// A veil across the bottom of the frame, under lower-third text on an
    /// image bar it doesn't read on.
    static func barScrim(_ colors: Colors) -> SlideObject {
        SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Scrim", text: "",
                    x: 0, y: 860, width: 1920, height: 220, shapeKind: .rectangle,
                    fill: ObjectFill(fillKind: .solid,
                                     colorHex: scrimColor(for: colors.barText).hex(alpha: colors.barScrim)))
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
            rest.insert(backdrop, at: 0)
        }
        // Off the art, the title sits on the same background as the other
        // designs and takes the same scrim.
        if !usesArt, let backing = textBacking(colors, under: objects) { rest.append(backing) }
        guard var title = objects.first(where: { $0.name == SermonSeriesTheme.titleText }),
              var subtitle = objects.first(where: { $0.name == SermonSeriesTheme.subtitleText })
        else { return rest + objects.filter { $0.objectKind == .text } }
        guard usesArt else { return rest + [title, subtitle] }

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
        if colors.titleScrim > 0 {
            // A soft plate behind the title where the art is busy or no
            // color reads on it alone.
            rest.append(plate(x: box.x, y: box.y, width: box.width, height: box.height, fill: ObjectFill(
                fillKind: .solid, colorHex: scrimColor(for: colors.titleText).hex(alpha: colors.titleScrim))))
        }
        return rest + [title, subtitle]
    }

    /// The bar, drawn as shapes in the series colors, under the text: first
    /// in the list, which is drawn first.
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
            // On the bar, so after it.
            let ruleX = (texts.first?.x ?? 80)
            shapes.append(shape("Accent Rule", x: ruleX, y: floating ? frame.y + 14 : frame.y, w: 140, h: 6,
                                fill: ObjectFill(fillKind: .solid, colorHex: colors.barRule.hex())))
        }
        return shapes + texts
    }
}
