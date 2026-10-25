import Foundation

/// A sermon series' look, turned into a theme: full-screen Title, Point,
/// Scripture, Point + Scripture and Worship designs for the room, and a
/// matching lower third for each but Title, tied together for the
/// livestream. Built once per series from its artwork.
public struct SermonSeriesStyle: Sendable {
    public var name: String
    /// Media ids for the series art (no text in them).
    public var backgroundMediaID: String?
    /// A 1920×1080 transparent image with the lower-third bar drawn on it.
    public var lowerThirdMediaID: String?
    public var font: String
    public var boldFont: String
    public var textColor: String
    public var accentColor: String
    /// Scripture's face (often the body font's italic); body font when nil.
    public var verseFont: String?
    /// The lower-third bar is often the opposite of the background (navy
    /// bar, cream background), so its text has its own colors.
    public var lowerThirdTextColor: String?
    public var lowerThirdAccentColor: String?
    /// Headings in capitals with open letter spacing.
    public var headingCaps: Bool

    public init(
        name: String, backgroundMediaID: String? = nil,
        lowerThirdMediaID: String? = nil, font: String = "Helvetica Neue", boldFont: String = "HelveticaNeue-Bold",
        textColor: String = "#FFFFFFFF", accentColor: String = "#FFB21EFF",
        verseFont: String? = nil, lowerThirdTextColor: String? = nil, lowerThirdAccentColor: String? = nil,
        headingCaps: Bool = false
    ) {
        self.verseFont = verseFont
        self.lowerThirdTextColor = lowerThirdTextColor
        self.lowerThirdAccentColor = lowerThirdAccentColor
        self.headingCaps = headingCaps
        self.name = name
        self.backgroundMediaID = backgroundMediaID
        self.lowerThirdMediaID = lowerThirdMediaID
        self.font = font
        self.boldFont = boldFont
        self.textColor = textColor
        self.accentColor = accentColor
    }
}

public enum SermonSeriesTheme {
    public static let pointCategory = "Sermon Points"
    public static let scriptureCategory = "Bible"
    public static let pointScriptureCategory = "Point + Scripture"
    public static let titleCategory = "Title"
    /// Songs ask for "Lyrics"; ThemeCategories answers that with Worship.
    public static let worshipCategory = "Worship"
    /// Text boxes on the designs. Worship's is "Lyrics", the name every
    /// song slide's text box has, so lyrics land in it.
    static let titleText = "Title"
    static let subtitleText = "Subtitle"
    static let lyricsText = "Lyrics"

    public static func make(_ style: SermonSeriesStyle, id: String = UUID().uuidString) -> Theme {
        func text(_ name: String, _ sample: String, x: Double, y: Double, w: Double, h: Double,
                  size: Double, bold: Bool = false, accent: Bool = false, verse: Bool = false, onBar: Bool = false,
                  align: TextHorizontalAlignment = .center) -> SlideObject {
            let color = onBar
                ? (accent ? style.lowerThirdAccentColor ?? style.accentColor : style.lowerThirdTextColor ?? style.textColor)
                : (accent ? style.accentColor : style.textColor)
            let caps = bold && style.headingCaps
            return SlideObject(
                id: UUID().uuidString, objectKind: .text, name: name, text: sample,
                x: x, y: y, width: w, height: h,
                textStyle: TextStyle(
                    fontName: bold ? style.boldFont : (verse ? style.verseFont ?? style.font : style.font), fontSize: size,
                    colorHex: color, tracking: caps ? size * 0.08 : nil,
                    horizontalAlignment: align, verticalAlignment: .middle,
                    textTransform: caps ? .uppercase : nil,
                    autoShrink: true, minFontSize: size * 0.5))
        }
        func art(_ mediaID: String?) -> [SlideObject] {
            guard let mediaID else { return [] }
            return [SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: "Series Art", text: "",
                x: 0, y: 0, width: 1920, height: 1080, shapeKind: .rectangle,
                fill: ObjectFill(fillKind: .media, mediaId: mediaID, mediaScaleMode: .fill))]
        }
        func bar() -> [SlideObject] {
            if let mediaID = style.lowerThirdMediaID { return art(mediaID) }
            return [SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: "Bar", text: "",
                x: 0, y: 820, width: 1920, height: 240, shapeKind: .rectangle,
                fill: ObjectFill(fillKind: .solid, colorHex: "#000000B8"))]
        }
        func slide(_ name: String, _ objects: [SlideObject], folder: String? = nil) -> Slide {
            Slide(id: UUID().uuidString, name: name, objects: objects, folder: folder)
        }

        // A design's objects are drawn in order, the last on top: the art
        // and bars come first so the text is drawn over them.
        let point = slide(pointCategory, art(style.backgroundMediaID) + [
            text("Point", "Main point goes here", x: 160, y: 300, w: 1600, h: 480, size: 90, bold: true),
        ])
        let scripture = slide(scriptureCategory, art(style.backgroundMediaID) + [
            text("Verse", "For God so loved the world…", x: 220, y: 230, w: 1480, h: 540, size: 60, verse: true, align: .left),
            text("Reference", "John 3:16 ESV", x: 220, y: 800, w: 1480, h: 70, size: 36, bold: true, accent: true, align: .left),
        ])
        let pointScripture = slide(pointScriptureCategory, art(style.backgroundMediaID) + [
            text("Point", "Main point goes here", x: 160, y: 170, w: 1600, h: 300, size: 80, bold: true),
            text("Verse", "For God so loved the world…", x: 260, y: 520, w: 1400, h: 300, size: 44, verse: true),
            text("Reference", "John 3:16 ESV", x: 260, y: 840, w: 1400, h: 60, size: 32, bold: true, accent: true),
        ])

        let thirds = BasicTemplates.lowerThirds
        // Lower-third text sits inside the bottom ~200px, where series bars
        // are drawn, inset from the left like a broadcast graphic.
        let pointLower = slide("\(pointCategory) (Lower Third)", bar() + [
            text("Point", "Main point goes here", x: 80, y: 895, w: 1760, h: 150, size: 50, bold: true, onBar: true, align: .left),
        ], folder: thirds)
        let scriptureLower = slide("\(scriptureCategory) (Lower Third)", bar() + [
            text("Verse", "For God so loved the world…", x: 80, y: 890, w: 1760, h: 115, size: 36, verse: true, onBar: true, align: .left),
            text("Reference", "John 3:16 ESV", x: 80, y: 1008, w: 1760, h: 44, size: 26, bold: true, accent: true, onBar: true, align: .left),
        ], folder: thirds)
        let pointScriptureLower = slide("\(pointScriptureCategory) (Lower Third)", bar() + [
            text("Point", "Main point goes here", x: 80, y: 885, w: 1760, h: 60, size: 40, bold: true, onBar: true, align: .left),
            text("Verse", "For God so loved the world…", x: 80, y: 948, w: 1760, h: 62, size: 28, verse: true, onBar: true, align: .left),
            text("Reference", "John 3:16 ESV", x: 80, y: 1012, w: 1760, h: 38, size: 22, bold: true, accent: true, onBar: true, align: .left),
        ], folder: thirds)

        // Title and Worship take the Point design's look, the same way an
        // older series is brought up to date, so both paths agree.
        let title = titleDesign(from: point, accent: scripture)
        let worship = worshipDesign(from: point)
        let worshipLower = worshipLowerThird(from: pointLower)

        let ties = [(pointCategory, pointLower), (scriptureCategory, scriptureLower),
                    (pointScriptureCategory, pointScriptureLower), (worshipCategory, worshipLower)]
        return Theme(
            id: id, name: style.name, fontFamily: style.font, fontSize: 72, textColorHex: style.textColor,
            backgroundColorHex: "#000000FF",
            // Point stays first: it's the design a slide with no category falls back to.
            slides: [point, scripture, pointScripture, title, worship,
                     pointLower, scriptureLower, pointScriptureLower, worshipLower],
            streamDesigns: [titleRoute]
                + ties.map { StreamDesign(category: $0.0, mode: .design, themeId: id, slideId: $0.1.id) },
            isSermonSeries: true)
    }

    /// The title slide leaves the camera clear on the livestream: the
    /// message title over the pastor would only cover the shot.
    static var titleRoute: StreamDesign { StreamDesign(category: titleCategory, mode: .clear) }

    // MARK: Series

    /// A series theme: flagged when made, or (for series made before the
    /// flag) one with all three message designs.
    public static func isSeries(_ theme: Theme) -> Bool {
        if theme.isSermonSeries == true { return true }
        let names = Set(fullScreen(theme.slides ?? []).map { $0.name.lowercased() })
        return [pointCategory, scriptureCategory, pointScriptureCategory].allSatisfy { names.contains($0.lowercased()) }
    }

    /// A series theme with any missing Title and Worship designs, Worship
    /// lower third and their livestream routes added in the series' own
    /// look (taken from its Point design), and flagged as a series. Nil when
    /// the theme isn't a series or already has everything, so running it
    /// again changes nothing.
    public static func upgraded(_ theme: Theme) -> Theme? {
        guard isSeries(theme) else { return nil }
        var result = theme
        var slides = theme.slides ?? []
        let full = fullScreen(slides)
        let lower = slides.filter { isLowerThird($0) }
        let point = full.first { $0.name.caseInsensitiveCompare(pointCategory) == .orderedSame } ?? full.first
        let scripture = full.first { $0.name.caseInsensitiveCompare(scriptureCategory) == .orderedSame }

        if let point, !has(titleCategory, in: full) {
            slides.append(titleDesign(from: point, accent: scripture))
        }
        if let point, !has(worshipCategory, in: full) {
            slides.append(worshipDesign(from: point))
        }
        let worshipLowerName = "\(worshipCategory) (Lower Third)"
        var worshipLower = lower.first { $0.name.caseInsensitiveCompare(worshipLowerName) == .orderedSame }
        if worshipLower == nil,
           let pointLower = lower.first(where: {
               $0.name.caseInsensitiveCompare("\(pointCategory) (Lower Third)") == .orderedSame
           }) {
            let made = worshipLowerThird(from: pointLower)
            slides.append(made)
            worshipLower = made
        }
        result.slides = slides

        var routes = theme.streamDesigns ?? []
        func routed(_ category: String) -> Bool {
            routes.contains { $0.category.caseInsensitiveCompare(category) == .orderedSame }
        }
        if !routed(titleCategory) { routes.insert(titleRoute, at: 0) }
        if !routed(worshipCategory), let worshipLower {
            routes.append(StreamDesign(category: worshipCategory, mode: .design, themeId: theme.id, slideId: worshipLower.id))
        }
        result.streamDesigns = routes
        result.isSermonSeries = true
        return result == theme ? nil : result
    }

    // MARK: General themes

    /// A general theme's names for lyrics and announcements, as the
    /// starter themes and ThemeCategories know them.
    public static let lyricsCategory = "Lyrics"
    public static let announcementsCategory = "Announcements"
    static let bodyText = "Body"

    /// A series' look as a general theme, for songs, announcements,
    /// scripture and points outside the message: Lyrics in place of
    /// Worship, an Announcements design, no Point + Scripture, and not
    /// flagged as a series, so the sermon pickers and the series upgrade
    /// leave it alone. Lyrics comes first, the design a slide with no
    /// category falls back to.
    public static func general(from series: Theme) -> Theme {
        var theme = series
        let pointScriptureNames = [pointScriptureCategory, "\(pointScriptureCategory) (Lower Third)"]
        var slides = (series.slides ?? []).filter { slide in
            !pointScriptureNames.contains { $0.caseInsensitiveCompare(slide.name) == .orderedSame }
        }
        for index in slides.indices {
            if slides[index].name == worshipCategory {
                slides[index].name = lyricsCategory
            } else if slides[index].name == "\(worshipCategory) (Lower Third)" {
                slides[index].name = "\(lyricsCategory) (Lower Third)"
            }
        }
        let full = fullScreen(slides)
        if let point = full.first(where: { $0.name == pointCategory }), !has(announcementsCategory, in: full) {
            slides.append(announcementsDesign(
                from: point, bodyFont: series.fontFamily,
                verse: full.first { $0.name == scriptureCategory }?.objects.first { $0.name == "Verse" }))
        }
        let order = [lyricsCategory, titleCategory, announcementsCategory, scriptureCategory, pointCategory]
        func rank(_ slide: Slide) -> Int {
            let name = slide.name.replacingOccurrences(of: " (Lower Third)", with: "")
            return (isLowerThird(slide) ? order.count : 0) + (order.firstIndex(of: name) ?? order.count - 1)
        }
        theme.slides = slides.enumerated()
            .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
            .map(\.element)
        let kept = Set(slides.map(\.id))
        theme.streamDesigns = series.streamDesigns?.compactMap { route in
            guard route.slideId.map(kept.contains) ?? true,
                  route.category.caseInsensitiveCompare(pointScriptureCategory) != .orderedSame else { return nil }
            var route = route
            if route.category == worshipCategory { route.category = lyricsCategory }
            return route
        }
        theme.isSermonSeries = nil
        return theme
    }

    /// An announcement: a heading in the Point's face and color over a
    /// paragraph in the body font, in the Point's look.
    static func announcementsDesign(from point: Slide, bodyFont: String, verse: SlideObject?) -> Slide {
        let source = pointText(in: point)
        let frame = box(of: source)
        let size = source?.textStyle?.fontSize ?? 90
        var heading = restyled(source, name: titleText, sample: "Announcement", size: size * 0.85, keepCaps: true)
        place(&heading, x: frame.x, y: 180, w: frame.w, h: 220)
        var body = restyled(verse ?? source, name: bodyText, sample: "Details, times and where to sign up",
                            size: 56, keepCaps: false)
        body.textStyle?.fontName = bodyFont
        body.textStyle?.horizontalAlignment = heading.textStyle?.horizontalAlignment ?? .center
        place(&body, x: frame.x, y: 430, w: frame.w, h: 470)
        return derived(from: point, name: announcementsCategory, texts: [heading, body])
    }

    static func isLowerThird(_ slide: Slide) -> Bool {
        (slide.folder ?? "").caseInsensitiveCompare(BasicTemplates.lowerThirds) == .orderedSame
    }

    static func fullScreen(_ slides: [Slide]) -> [Slide] {
        slides.filter { !isLowerThird($0) }
    }

    private static func has(_ category: String, in slides: [Slide]) -> Bool {
        slides.contains { $0.name.caseInsensitiveCompare(category) == .orderedSame }
    }

    // MARK: Layers

    /// The shapes a series design is built on, by how low they sit: the
    /// art, background and bar at the bottom, then a scrim or the bar's
    /// edge, then the accent rule on the bar.
    static let backdropRanks: [String: Int] = [
        "Series Art": 0, "Series Background": 0, "Series Lower Third": 0, "Bar": 0,
        "Scrim": 1, "Bar Edge": 1, "Accent Rule": 2,
    ]

    /// A design's objects with its backdrop shapes moved beneath everything
    /// else. Slides are drawn in list order, the last object on top.
    public static func layered(_ objects: [SlideObject]) -> [SlideObject] {
        func rank(_ object: SlideObject) -> Int? {
            object.objectKind == .text ? nil : backdropRanks[object.name]
        }
        let backdrop = objects.enumerated()
            .compactMap { offset, object in rank(object).map { (rank: $0, offset: offset, object: object) } }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
        let moved = Set(backdrop.map(\.offset))
        return backdrop.map(\.object) + objects.enumerated().filter { !moved.contains($0.offset) }.map(\.element)
    }

    /// Whether a text box sits under one of the design's backdrop shapes,
    /// as every series design did before they were built back to front:
    /// the art covered the text on the audience screens and the bar dimmed
    /// it on the livestream.
    static func hasTextUnderBackdrop(_ objects: [SlideObject]) -> Bool {
        guard let lastBackdrop = objects.lastIndex(where: { $0.objectKind != .text && backdropRanks[$0.name] != nil })
        else { return false }
        return objects[..<lastBackdrop].contains { $0.objectKind == .text }
    }

    /// The theme with any design that has text under its own art or bar put
    /// right; nil when none does. A design staff arranged differently is
    /// left alone.
    public static func relayered(_ theme: Theme) -> Theme? {
        guard var slides = theme.slides, slides.contains(where: { hasTextUnderBackdrop($0.objects) }) else { return nil }
        for index in slides.indices where hasTextUnderBackdrop(slides[index].objects) {
            slides[index].objects = layered(slides[index].objects)
        }
        var result = theme
        result.slides = slides
        return result
    }

    // MARK: Text boxes

    /// The text boxes a design needs so every slide made in it has
    /// somewhere to put its words.
    static func requiredText(for design: Slide) -> [String] {
        let name = design.name.replacingOccurrences(of: " (Lower Third)", with: "")
        switch name {
        case titleCategory: return [titleText, subtitleText]
        case pointCategory: return ["Point"]
        case scriptureCategory: return ["Verse", "Reference"]
        case pointScriptureCategory: return ["Point", "Verse", "Reference"]
        case worshipCategory, lyricsCategory: return [lyricsText]
        case announcementsCategory: return [titleText, bodyText]
        default: return []
        }
    }

    /// Where a missing text box goes: the usual layout for its design.
    private static func defaultFrame(_ box: String, design: String, lower: Bool)
        -> (x: Double, y: Double, w: Double, h: Double, size: Double) {
        if lower {
            switch (design, box) {
            case (pointScriptureCategory, "Point"): return (80, 885, 1760, 60, 40)
            case (pointScriptureCategory, "Verse"): return (80, 948, 1760, 62, 28)
            case (pointScriptureCategory, "Reference"): return (80, 1012, 1760, 38, 22)
            case (_, "Verse"): return (80, 890, 1760, 115, 36)
            case (_, "Reference"): return (80, 1008, 1760, 44, 26)
            default: return (80, 895, 1760, 150, 48)
            }
        }
        switch (design, box) {
        case (pointScriptureCategory, "Point"): return (160, 170, 1600, 300, 80)
        case (pointScriptureCategory, "Verse"): return (260, 520, 1400, 300, 44)
        case (pointScriptureCategory, "Reference"): return (260, 840, 1400, 60, 32)
        case (announcementsCategory, titleText): return (160, 180, 1600, 220, 76)
        case (_, titleText): return (160, 300, 1600, 360, 100)
        case (_, subtitleText): return (160, 660, 1600, 120, 44)
        case (_, "Verse"): return (220, 230, 1480, 540, 60)
        case (_, "Reference"): return (220, 800, 1480, 70, 36)
        case (_, lyricsText): return (160, 190, 1600, 700, 80)
        case (_, bodyText): return (160, 430, 1600, 470, 56)
        default: return (160, 300, 1600, 480, 90)
        }
    }

    /// The theme with every text box its designs need, any missing one
    /// added in the usual place in the color of the design's other text
    /// (or the theme's), and every design layered with its text on top. A
    /// design never comes out as art alone, whatever went wrong making it.
    public static func completed(_ theme: Theme) -> Theme {
        guard var slides = theme.slides else { return theme }
        let lowerColor = slides.first { isLowerThird($0) }?.objects
            .first { $0.objectKind == .text }?.textStyle?.colorHex
        for index in slides.indices {
            var design = slides[index]
            let lower = isLowerThird(design)
            let names = Set(design.objects.filter { $0.objectKind == .text }.map { $0.name.lowercased() })
            let missing = requiredText(for: design).filter { !names.contains($0.lowercased()) }
            let sibling = design.objects.first { $0.objectKind == .text }?.textStyle
            let base = design.name.replacingOccurrences(of: " (Lower Third)", with: "")
            for name in missing {
                let frame = defaultFrame(name, design: base, lower: lower)
                let color = sibling?.colorHex ?? (lower ? lowerColor : nil) ?? theme.textColorHex
                design.objects.append(SlideObject(
                    id: UUID().uuidString, objectKind: .text, name: name, text: name,
                    x: frame.x, y: frame.y, width: frame.w, height: frame.h,
                    textStyle: TextStyle(
                        fontName: sibling?.fontName ?? theme.fontFamily, fontSize: frame.size, colorHex: color,
                        horizontalAlignment: lower ? .left : (sibling?.horizontalAlignment ?? .center),
                        verticalAlignment: .middle, autoShrink: true, minFontSize: (frame.size * 0.5).rounded())))
            }
            design.objects = layered(design.objects)
            slides[index] = design
        }
        var result = theme
        result.slides = slides
        return result
    }

    // MARK: Designs taken from Point

    /// The message title, large, in the Point's box, with the series name or
    /// speaker beneath it in the scripture reference's accent style.
    static func titleDesign(from point: Slide, accent: Slide?) -> Slide {
        let source = pointText(in: point)
        let frame = box(of: source)
        let size = source?.textStyle?.fontSize ?? 90
        let titleHeight = frame.h * 0.75
        var title = restyled(source, name: titleText, sample: "Message Title", size: size * 1.15, keepCaps: true)
        place(&title, x: frame.x, y: frame.y, w: frame.w, h: titleHeight)
        let reference = accent?.objects.first { $0.objectKind == .text && $0.name == "Reference" }
        var subtitle = restyled(reference ?? source, name: subtitleText, sample: "Series Name", size: size * 0.45, keepCaps: true)
        subtitle.textStyle?.horizontalAlignment = source?.textStyle?.horizontalAlignment
        place(&subtitle, x: frame.x, y: frame.y + titleHeight, w: frame.w, h: max(60, frame.h - titleHeight))
        return derived(from: point, name: titleCategory, texts: [title, subtitle])
    }

    /// Song lyrics in the Point's box and face, in sentence case: lyrics in
    /// capitals are hard to sing from.
    static func worshipDesign(from point: Slide) -> Slide {
        let source = pointText(in: point)
        let frame = box(of: source)
        var lyrics = restyled(source, name: lyricsText, sample: sampleLyrics,
                              size: (source?.textStyle?.fontSize ?? 90) * 0.9, keepCaps: false)
        place(&lyrics, x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        return derived(from: point, name: worshipCategory, texts: [lyrics])
    }

    /// The Point lower third's bar with lyrics on it.
    static func worshipLowerThird(from pointLower: Slide) -> Slide {
        let source = pointText(in: pointLower)
        let frame = box(of: source)
        var lyrics = restyled(source, name: lyricsText, sample: sampleLyrics,
                              size: (source?.textStyle?.fontSize ?? 50) * 0.9, keepCaps: false)
        place(&lyrics, x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        return derived(from: pointLower, name: "\(worshipCategory) (Lower Third)", texts: [lyrics])
    }

    private static let sampleLyrics = "Amazing grace how sweet the sound\nThat saved a wretch like me"

    private static func pointText(in slide: Slide) -> SlideObject? {
        let texts = slide.objects.filter { $0.objectKind == .text }
        return texts.first { $0.name == "Point" } ?? texts.first
    }

    private static func box(of object: SlideObject?) -> (x: Double, y: Double, w: Double, h: Double) {
        (object?.x ?? 160, object?.y ?? 300, object?.width ?? 1600, object?.height ?? 480)
    }

    private static func restyled(
        _ source: SlideObject?, name: String, sample: String, size: Double, keepCaps: Bool
    ) -> SlideObject {
        var style = source?.textStyle ?? TextStyle(horizontalAlignment: .center, verticalAlignment: .middle)
        style.fontSize = size.rounded()
        style.minFontSize = (size * 0.5).rounded()
        style.autoShrink = true
        if !keepCaps {
            style.textTransform = nil
            style.tracking = nil
        } else if style.textTransform == .uppercase {
            style.tracking = (size * 0.08).rounded()
        }
        var object = source ?? SlideObject(id: "", objectKind: .text, name: name, text: sample)
        object.id = UUID().uuidString
        object.name = name
        object.text = sample
        object.textStyle = style
        return object
    }

    private static func place(_ object: inout SlideObject, x: Double, y: Double, w: Double, h: Double) {
        object.x = x
        object.y = y
        object.width = w
        object.height = h
    }

    /// A copy of a design with its text boxes swapped for new ones and
    /// everything else (series art, bar) kept beneath, under fresh ids:
    /// first in the list, since the last object is drawn on top.
    private static func derived(from design: Slide, name: String, texts: [SlideObject]) -> Slide {
        let rest = design.objects.filter { $0.objectKind != .text }.map { object -> SlideObject in
            var copy = object
            copy.id = UUID().uuidString
            return copy
        }
        var slide = design
        slide.id = UUID().uuidString
        slide.name = name
        slide.objects = rest + texts
        // Animation order and history name the old design's objects.
        slide.animationOrder = nil
        slide.history = nil
        return slide
    }

    /// The prompt to paste into Claude Design for a new series' artwork.
    public static func claudeDesignPrompt(series: String) -> String {
        """
        Design the slide artwork for a church sermon series called "\(series)". I need two images, both 1920×1080, with NO words on them (my presentation app adds the text):

        1. Background — used behind five full-screen slide types: the message title, a sermon point (one large line), a scripture passage (a paragraph of verse text plus its reference), a point with its supporting verse, and song lyrics. Keep the middle calm and dark enough for large white text.
        2. Lower third — a transparent PNG with only a bar or shape across the bottom (roughly the bottom 260 pixels) for text to sit on over a camera shot of the pastor. Everything else fully transparent.

        Also tell me the heading, body and scripture fonts (with weights), whether headings are all caps, and as hex codes: the text and accent colors on the background, and the text and accent colors on the lower-third bar.
        Export 1 as JPG and 2 as PNG.
        """
    }
}

public extension Library {

    /// Brings every sermon series in the library up to the five designs
    /// (see SermonSeriesTheme.upgraded), and puts text back on top of the
    /// art and bars in any theme that has it underneath (see
    /// SermonSeriesTheme.relayered). Other themes are left alone. It
    /// runs as the library opens, so one theme that can't be read or saved
    /// is reported to `failed` and passed over rather than keeping the
    /// library shut; the import upgrades that series when it's next used.
    @discardableResult
    func upgradeSermonSeriesThemes(failed: (_ themeID: String, _ error: any Error) -> Void = { _, _ in }) throws -> Int {
        var upgraded = 0
        for id in try store.ids(of: .theme) {
            do {
                let document = try open(Theme.self, id: id)
                let grown = SermonSeriesTheme.upgraded(document.value)
                let relayered = SermonSeriesTheme.relayered(grown ?? document.value)
                guard let theme = relayered ?? grown else { continue }
                try document.update { stored in
                    stored.slides = theme.slides
                    stored.streamDesigns = theme.streamDesigns
                    if theme.isSermonSeries == true { stored.isSermonSeries = true }
                }
                try save(document)
                upgraded += 1
            } catch {
                failed(id, error)
            }
        }
        return upgraded
    }
}
