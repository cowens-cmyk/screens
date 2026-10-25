import Foundation

/// What Claude reads from a sermon series graphic (the title art the
/// designer made): its colors, where text can go, how to turn it into
/// backgrounds for text slides, type and the lower-third bar. The app
/// builds the whole series theme from it (see PhotoSeriesTheme).
public struct ArtAnalysis: Codable, Equatable, Sendable {
    /// A rectangle as fractions of the art, 0 to 1 from the top left.
    public struct Zone: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
        /// The art itself, blurred and dimmed until text reads on it.
        case blurredArt
        case gradient
        case solid
    }

    public enum Tone: String, Codable, CaseIterable, Sendable {
        /// Darkened, for light text.
        case dark
        /// Washed toward white, for dark text.
        case light
    }

    public struct TextBackground: Codable, Equatable, Sendable {
        public var kind: BackgroundKind
        public var tone: Tone
        /// How far to dim or wash the art, 0 to 1.
        public var strength: Double
        /// How much to blur it, 0 to 1.
        public var blur: Double
        /// Gradient colors top to bottom, or the one solid color.
        public var colors: [String]

        public init(kind: BackgroundKind, tone: Tone, strength: Double, blur: Double, colors: [String]) {
            self.kind = kind
            self.tone = tone
            self.strength = strength
            self.blur = blur
            self.colors = colors
        }
    }

    public enum BarStyle: String, Codable, CaseIterable, Sendable {
        case solid
        /// Fades up from the bottom of the frame.
        case gradient
        /// See-through tint with a light edge.
        case glass
    }

    public enum BarPlacement: String, Codable, CaseIterable, Sendable {
        /// Edge to edge across the bottom.
        case fullWidth
        /// Inset from the edges with rounded corners.
        case floating
    }

    public struct LowerThird: Codable, Equatable, Sendable {
        public var style: BarStyle
        public var color: String
        public var opacity: Double
        public var placement: BarPlacement
        /// A short rule in the accent color along the top of the bar.
        public var accentRule: Bool
        public var textColor: String
        public var accentColor: String

        public init(style: BarStyle, color: String, opacity: Double, placement: BarPlacement,
                    accentRule: Bool, textColor: String, accentColor: String) {
            self.style = style
            self.color = color
            self.opacity = opacity
            self.placement = placement
            self.accentRule = accentRule
            self.textColor = textColor
            self.accentColor = accentColor
        }
    }

    public enum Weight: String, Codable, CaseIterable, Sendable {
        case light, regular, medium, semibold, bold, heavy, black
    }

    public var seriesTitle: String
    public var artHasTitle: Bool
    public var rationale: String
    public var palette: [String]
    public var accentColor: String
    public var textColor: String
    public var focusX: Double
    public var focusY: Double
    public var titleUsesArt: Bool
    public var titleZone: Zone
    public var textBackground: TextBackground
    public var headingFont: String
    public var headingWeight: Weight
    public var bodyFont: String
    public var headingAllCaps: Bool
    public var scriptureItalic: Bool
    public var lowerThird: LowerThird

    public init(
        seriesTitle: String, artHasTitle: Bool, rationale: String, palette: [String], accentColor: String,
        textColor: String, focusX: Double, focusY: Double, titleUsesArt: Bool, titleZone: Zone,
        textBackground: TextBackground, headingFont: String, headingWeight: Weight, bodyFont: String,
        headingAllCaps: Bool, scriptureItalic: Bool, lowerThird: LowerThird
    ) {
        self.seriesTitle = seriesTitle
        self.artHasTitle = artHasTitle
        self.rationale = rationale
        self.palette = palette
        self.accentColor = accentColor
        self.textColor = textColor
        self.focusX = focusX
        self.focusY = focusY
        self.titleUsesArt = titleUsesArt
        self.titleZone = titleZone
        self.textBackground = textBackground
        self.headingFont = headingFont
        self.headingWeight = headingWeight
        self.bodyFont = bodyFont
        self.headingAllCaps = headingAllCaps
        self.scriptureItalic = scriptureItalic
        self.lowerThird = lowerThird
    }

    public static func decode(_ json: String) throws -> ArtAnalysis {
        try JSONDecoder().decode(ArtAnalysis.self, from: Data(json.utf8))
    }

    public struct NotAnObject: LocalizedError {
        public var errorDescription: String? { "Claude's answer couldn't be read." }
    }

    /// Claude's answer laid over `fallback` field by field: anything
    /// missing, null, misspelt or of the wrong kind keeps the fallback's
    /// value, so an answer that's partly wrong still builds every design
    /// instead of none. Throws only when the answer isn't a JSON object.
    public static func decode(_ json: String, filling fallback: ArtAnalysis) throws -> ArtAnalysis {
        guard let answer = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let encoded = try? JSONEncoder().encode(fallback),
              var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        else { throw NotAnObject() }
        func decodes(_ candidate: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: candidate) else { return false }
            return (try? JSONDecoder().decode(ArtAnalysis.self, from: data)) != nil
        }
        // Each value is tried on its own, kept only if the whole still
        // decodes; objects (the bar, the background) are gone into.
        func apply(_ answer: [String: Any], at path: [String]) {
            for (key, value) in answer.sorted(by: { $0.key < $1.key }) {
                let keyPath = path + [key]
                guard let current = Self.value(at: keyPath, in: merged) else { continue }
                if let nested = value as? [String: Any], current is [String: Any] {
                    apply(nested, at: keyPath)
                    continue
                }
                var candidate = merged
                Self.set(value, at: keyPath, in: &candidate)
                if decodes(candidate) { merged = candidate }
            }
        }
        apply(answer, at: [])
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let result = try? JSONDecoder().decode(ArtAnalysis.self, from: data)
        else { return fallback }
        return result
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        guard let first = path.first else { return object }
        guard let next = object[first] else { return nil }
        if path.count == 1 { return next }
        return (next as? [String: Any]).flatMap { value(at: Array(path.dropFirst()), in: $0) }
    }

    private static func set(_ newValue: Any, at path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = newValue
            return
        }
        var nested = object[first] as? [String: Any] ?? [:]
        set(newValue, at: Array(path.dropFirst()), in: &nested)
        object[first] = nested
    }

    // MARK: Asking Claude

    /// The structured-output schema. Fonts are plain strings, not an enum:
    /// a Mac has a few hundred families, too many for a schema, so the
    /// installed list goes in the prompt and `sanitized` holds Claude to it.
    public static var schema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false,
             "required": Array(properties.keys).sorted(), "properties": properties]
        }
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let boolean: [String: Any] = ["type": "boolean"]
        func choice<T: RawRepresentable & CaseIterable>(_: T.Type) -> [String: Any] where T.RawValue == String {
            ["type": "string", "enum": T.allCases.map(\.rawValue)]
        }
        return object([
            "seriesTitle": string,
            "artHasTitle": boolean,
            "rationale": string,
            "palette": ["type": "array", "items": string],
            "accentColor": string,
            "textColor": string,
            "focusX": number,
            "focusY": number,
            "titleUsesArt": boolean,
            "titleZone": object(["x": number, "y": number, "width": number, "height": number]),
            "textBackground": object([
                "kind": choice(BackgroundKind.self),
                "tone": choice(Tone.self),
                "strength": number,
                "blur": number,
                "colors": ["type": "array", "items": string],
            ]),
            "headingFont": string,
            "headingWeight": choice(Weight.self),
            "bodyFont": string,
            "headingAllCaps": boolean,
            "scriptureItalic": boolean,
            "lowerThird": object([
                "style": choice(BarStyle.self),
                "color": string,
                "opacity": number,
                "placement": choice(BarPlacement.self),
                "accentRule": boolean,
                "textColor": string,
                "accentColor": string,
            ]),
        ])
    }

    public static let instructions = """
    You look at the artwork for a church sermon series (usually the title graphic the church's designer made) and decide how a presentation app should build the rest of the series from it: a Title slide, full-screen slides for sermon points, scripture passages, a point with its verse, and worship lyrics, plus lower thirds laid over a camera shot of the pastor on the livestream. Everything should feel like it belongs with the art.

    Return:
    - seriesTitle: the series title exactly as lettered in the art, in normal capitalization; "" if there is no legible title.
    - artHasTitle: true if the art already has the series title lettered on it (so the app won't print it again).
    - rationale: one or two plain sentences on the choices. No marketing language.
    - palette: 3 to 6 colors from the art as #RRGGBB, most prominent first.
    - accentColor: the series' signature color from the art, for scripture references.
    - textColor: the color for large text on the text-slide background below.
    - focusX, focusY: 0 to 1, the point of the art to keep in frame when it's cropped to 16:9 (usually the lettering or the subject).
    - titleUsesArt: true to show the art itself, full screen, as the Title slide. False only if it can't be cropped to 16:9 without losing what matters.
    - titleZone: the largest calm area of the art (fractions 0 to 1 of the image, from the top left) clear of lettering and the main subject, where a short message title could sit. All zeros if there is none.
    - textBackground: the background behind points, scripture and lyrics. These carry several lines of text, so they must be calm.
      kind: blurredArt (the art blurred and dimmed, the usual choice when the art has texture or photography), gradient or solid (from the palette, better for flat or typographic art).
      tone: dark (dimmed, for light text) or light (washed toward white, for dark text).
      strength: 0 to 1, how far to dim or wash it; enough that textColor reads easily.
      blur: 0 to 1, how much to blur the art (only for blurredArt).
      colors: for gradient, 2 or 3 colors top to bottom; for solid, 1; otherwise [].
    - headingFont, bodyFont: family names copied exactly from the installed font list in the message. Pick faces that echo the art's lettering: its feel (geometric, condensed, serif, script, grotesque), not a copy. bodyFont must be comfortable for a paragraph of scripture. Never a script or decorative face for bodyFont.
    - headingWeight: the heading weight.
    - headingAllCaps: true if the art's lettering is in capitals or the style suits them.
    - scriptureItalic: true to set scripture in the body font's italic.
    - lowerThird: the bar the livestream text sits on.
      style: solid, gradient (fades up from the bottom of the frame) or glass (see-through tint).
      color: #RRGGBB, usually a deep color from the palette; opacity 0 to 1 (0.75 or more for solid and gradient).
      placement: fullWidth or floating (inset, rounded).
      accentRule: true for a short rule in accentColor along the top edge.
      textColor and accentColor: text and references on the bar.

    Colors are #RRGGBB. Text must read clearly on what it sits on.
    """

    /// The text sent with the image.
    public static func prompt(fileName: String, width: Int, height: Int, fonts: [String]) -> String {
        """
        The series art is attached (\(width)×\(height), file "\(fileName)").

        Installed font families (choose only from these):
        \(fonts.joined(separator: ", "))
        """
    }

    // MARK: Cleaning up

    /// Clamps every number, repairs or replaces colors that aren't hex, and
    /// swaps a font that isn't installed for `fallbackFont`, so what comes
    /// back can always be built.
    public func sanitized(installedFamilies: [String], fallbackFont: String = "Helvetica Neue") -> ArtAnalysis {
        var result = self
        func unit(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : fallback }
        let palette = palette.compactMap { SeriesColor(hex: $0) }
        let darkest = palette.min { $0.luminance < $1.luminance } ?? SeriesColor(red: 0.08, green: 0.08, blue: 0.1)
        let lightest = palette.max { $0.luminance < $1.luminance } ?? .white
        func color(_ hex: String, _ fallback: SeriesColor) -> String {
            (SeriesColor(hex: hex) ?? fallback).hex()
        }

        result.seriesTitle = String(seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        result.rationale = String(rationale.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        result.palette = palette.isEmpty ? [darkest.hex()] : palette.prefix(6).map { $0.hex() }
        result.accentColor = color(accentColor, palette.max { $0.saturation < $1.saturation } ?? lightest)
        result.focusX = unit(focusX, 0.5)
        result.focusY = unit(focusY, 0.5)
        result.titleZone = Self.clamped(titleZone)

        var background = textBackground
        background.strength = unit(background.strength, 0.6)
        background.blur = unit(background.blur, 0.6)
        let backdrop = background.tone == .dark ? darkest : lightest
        var colors = background.colors.compactMap { SeriesColor(hex: $0) }
        switch background.kind {
        case .gradient:
            if colors.isEmpty { colors = [backdrop.mixed(with: .black, amount: 0.2), backdrop] }
            if colors.count == 1 { colors.append(colors[0].mixed(with: background.tone == .dark ? .black : .white, amount: 0.35)) }
            colors = Array(colors.prefix(3))
        case .solid:
            colors = [colors.first ?? backdrop]
        case .blurredArt:
            colors = []
        }
        background.colors = colors.map { $0.hex() }
        result.textBackground = background
        result.textColor = color(textColor, background.tone == .dark ? .white : .black)

        let installed = Dictionary(installedFamilies.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let fallback = installed[fallbackFont.lowercased()] ?? installedFamilies.first ?? fallbackFont
        func font(_ name: String) -> String {
            installed[name.trimmingCharacters(in: .whitespaces).lowercased()] ?? fallback
        }
        result.headingFont = font(headingFont)
        result.bodyFont = font(bodyFont)

        var bar = lowerThird
        bar.color = color(bar.color, darkest)
        bar.opacity = min(max(bar.opacity.isFinite ? bar.opacity : 0.85, 0.35), 1)
        bar.textColor = color(bar.textColor, .white)
        bar.accentColor = color(bar.accentColor, SeriesColor(hex: result.accentColor) ?? .white)
        result.lowerThird = bar
        return result
    }

    static func clamped(_ zone: Zone) -> Zone {
        guard [zone.x, zone.y, zone.width, zone.height].allSatisfy(\.isFinite) else { return Zone(x: 0, y: 0, width: 0, height: 0) }
        let x = min(max(zone.x, 0), 1)
        let y = min(max(zone.y, 0), 1)
        let width = min(max(zone.width, 0), 1 - x)
        let height = min(max(zone.height, 0), 1 - y)
        // A sliver isn't somewhere text can go.
        guard width * height >= 0.02, width >= 0.15, height >= 0.06 else { return Zone(x: 0, y: 0, width: 0, height: 0) }
        return Zone(x: x, y: y, width: width, height: height)
    }

    // MARK: Without Claude

    /// A reasonable read of the art from its colors alone, for when there's
    /// no API key or Claude can't be reached: the art dimmed behind white
    /// text (or washed behind black for light art), the most vivid color as
    /// the accent, a deep bar, and system fonts. `variant` steps the accent
    /// through the other vivid colors, for Try Again.
    public static func local(swatches: [SeriesPalette.Swatch], seriesTitle: String,
                             fonts: (heading: String, body: String) = ("Avenir Next", "Avenir Next"),
                             variant: Int = 0) -> ArtAnalysis {
        let colors = swatches.map(\.color)
        let average = swatches.reduce((r: 0.0, g: 0.0, b: 0.0)) {
            ($0.r + $1.color.red * $1.share, $0.g + $1.color.green * $1.share, $0.b + $1.color.blue * $1.share)
        }
        let overall = SeriesColor(red: average.r, green: average.g, blue: average.b)
        // Very light art reads best washed out with dark text; everything
        // else is dimmed for white text, the safer look in a dark room.
        let tone: Tone = overall.luminance > 0.6 ? .light : .dark
        let accent = SeriesPalette.accent(of: swatches, skip: variant) ?? .white
        let deep = colors.filter { $0.luminance < 0.2 }.max { $0.saturation < $1.saturation }
            ?? (colors.min { $0.luminance < $1.luminance } ?? .black).mixed(with: .black, amount: 0.5)
        let text: SeriesColor = tone == .dark ? .white : SeriesColor(red: 0.07, green: 0.07, blue: 0.08)
        return ArtAnalysis(
            seriesTitle: seriesTitle, artHasTitle: true,
            rationale: "Built from the art's colors.",
            palette: colors.prefix(6).map { $0.hex() }, accentColor: accent.hex(), textColor: text.hex(),
            focusX: 0.5, focusY: 0.5, titleUsesArt: true,
            titleZone: Zone(x: 0, y: 0, width: 0, height: 0),
            textBackground: TextBackground(kind: .blurredArt, tone: tone, strength: 0.45, blur: 0.7, colors: []),
            headingFont: fonts.heading, headingWeight: .bold, bodyFont: fonts.body,
            headingAllCaps: true, scriptureItalic: false,
            lowerThird: LowerThird(style: .solid, color: deep.hex(), opacity: 0.88, placement: .fullWidth,
                                   accentRule: true, textColor: SeriesColor.white.hex(), accentColor: accent.hex()))
    }

    // MARK: From a Claude Design download

    /// A Claude Design download already made its choices, so it's read
    /// without asking Claude again: its text, accent and bar colors and its
    /// capitals, over its own background used as it is. The background is
    /// art with no words on it, so it carries no title; `strength` starts
    /// at 0 and the contrast check dims it only as far as its text color
    /// needs (the app leaves it unblurred). The palette, and a bar for a download without a
    /// lower third of its own, come from the background's colors.
    public static func designed(_ export: SeriesExport, swatches: [SeriesPalette.Swatch]) -> ArtAnalysis {
        var analysis = local(swatches: swatches, seriesTitle: export.series)
        let text = export.textColor.flatMap(SeriesColor.init(hex:)) ?? SeriesColor(hex: analysis.textColor) ?? .white
        analysis.rationale = "Colors and fonts from the Claude Design download."
        analysis.artHasTitle = false
        analysis.textColor = text.hex()
        if let accent = export.accentColor.flatMap(SeriesColor.init(hex:)) { analysis.accentColor = accent.hex() }
        // Light text needs the background kept dark, dark text light.
        analysis.textBackground = TextBackground(kind: .blurredArt, tone: text.luminance > 0.4 ? .dark : .light,
                                                 strength: 0, blur: 0, colors: [])
        analysis.headingAllCaps = export.headingAllCaps ?? false
        analysis.scriptureItalic = false
        if let barText = export.lowerThirdTextColor.flatMap(SeriesColor.init(hex:)) {
            analysis.lowerThird.textColor = barText.hex()
        }
        analysis.lowerThird.accentColor = (export.lowerThirdAccentColor.flatMap(SeriesColor.init(hex:))
            ?? SeriesColor(hex: analysis.accentColor) ?? .white).hex()
        return analysis
    }
}

/// Where art lands when it fills a 1920×1080 slide: scaled to cover the
/// frame and cropped around a focus point, the way the title art is cut.
public enum ArtCrop {
    public static let slide = (width: 1920.0, height: 1080.0)

    /// The part of the image that stays, as fractions of the image.
    public static func visible(imageWidth: Double, imageHeight: Double, focusX: Double, focusY: Double) -> ArtAnalysis.Zone {
        guard imageWidth > 0, imageHeight > 0 else { return .init(x: 0, y: 0, width: 1, height: 1) }
        let scale = max(slide.width / imageWidth, slide.height / imageHeight)
        let width = min(1, slide.width / (imageWidth * scale))
        let height = min(1, slide.height / (imageHeight * scale))
        let x = min(max(focusX - width / 2, 0), 1 - width)
        let y = min(max(focusY - height / 2, 0), 1 - height)
        return .init(x: x, y: y, width: width, height: height)
    }

    /// The pixel size to draw artwork of this shape at: its own proportions,
    /// large enough to cover the slide (the background is cropped to it
    /// later, like any picture), and no more than 3840 on a side.
    public static func renderSize(width: Double, height: Double) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (Int(slide.width), Int(slide.height)) }
        let scale = min(max(slide.width / width, slide.height / height), 3840 / width, 3840 / height)
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    /// Where a lower third of this shape sits on the slide, in slide points
    /// from the top: as large as fits without cropping, centered across and
    /// resting on the bottom edge, where the bar belongs.
    public static func bottomFit(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0, 0, slide.width, slide.height) }
        let scale = min(slide.width / width, slide.height / height)
        let fitted = (width: width * scale, height: height * scale)
        return ((slide.width - fitted.width) / 2, slide.height - fitted.height, fitted.width, fitted.height)
    }

    /// A zone of the image in slide points, clipped to what's visible; nil
    /// when the crop cuts it away.
    public static func slideRect(of zone: ArtAnalysis.Zone, visible: ArtAnalysis.Zone)
        -> (x: Double, y: Double, width: Double, height: Double)? {
        guard !zone.isEmpty, !visible.isEmpty else { return nil }
        let left = max(zone.x, visible.x), right = min(zone.x + zone.width, visible.x + visible.width)
        let top = max(zone.y, visible.y), bottom = min(zone.y + zone.height, visible.y + visible.height)
        guard right > left, bottom > top else { return nil }
        let x = (left - visible.x) / visible.width * slide.width
        let y = (top - visible.y) / visible.height * slide.height
        let width = (right - left) / visible.width * slide.width
        let height = (bottom - top) / visible.height * slide.height
        guard width >= 300, height >= 90 else { return nil }
        return (x, y, width, height)
    }
}
