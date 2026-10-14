import Foundation

/// A sermon series' look, turned into a theme: full-screen Title, Point,
/// Scripture and Quote designs for the room and a matching lower third for
/// each, tied together for the livestream. Built once per series from the
/// artwork made in Claude Design.
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

    public init(
        name: String, backgroundMediaID: String? = nil,
        lowerThirdMediaID: String? = nil, font: String = "Helvetica Neue", boldFont: String = "HelveticaNeue-Bold",
        textColor: String = "#FFFFFFFF", accentColor: String = "#FFB21EFF"
    ) {
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

    public static func make(_ style: SermonSeriesStyle, id: String = UUID().uuidString) -> Theme {
        func text(_ name: String, _ sample: String, x: Double, y: Double, w: Double, h: Double,
                  size: Double, bold: Bool = false, accent: Bool = false,
                  align: TextHorizontalAlignment = .center) -> SlideObject {
            SlideObject(
                id: UUID().uuidString, objectKind: .text, name: name, text: sample,
                x: x, y: y, width: w, height: h,
                textStyle: TextStyle(
                    fontName: bold ? style.boldFont : style.font, fontSize: size,
                    colorHex: accent ? style.accentColor : style.textColor,
                    horizontalAlignment: align, verticalAlignment: .middle,
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

        let point = slide(pointCategory, [
            text("Point", "Main point goes here", x: 160, y: 300, w: 1600, h: 480, size: 90, bold: true),
        ] + art(style.backgroundMediaID))
        let scripture = slide(scriptureCategory, [
            text("Verse", "For God so loved the world…", x: 220, y: 230, w: 1480, h: 540, size: 60, align: .left),
            text("Reference", "John 3:16 ESV", x: 220, y: 800, w: 1480, h: 70, size: 36, bold: true, accent: true, align: .left),
        ] + art(style.backgroundMediaID))
        let pointScripture = slide(pointScriptureCategory, [
            text("Point", "Main point goes here", x: 160, y: 170, w: 1600, h: 300, size: 80, bold: true),
            text("Verse", "For God so loved the world…", x: 260, y: 520, w: 1400, h: 300, size: 44),
            text("Reference", "John 3:16 ESV", x: 260, y: 840, w: 1400, h: 60, size: 32, bold: true, accent: true),
        ] + art(style.backgroundMediaID))

        let thirds = BasicTemplates.lowerThirds
        let pointLower = slide("\(pointCategory) (Lower Third)", [
            text("Point", "Main point goes here", x: 120, y: 860, w: 1680, h: 160, size: 52, bold: true, align: .left),
        ] + bar(), folder: thirds)
        let scriptureLower = slide("\(scriptureCategory) (Lower Third)", [
            text("Verse", "For God so loved the world…", x: 120, y: 840, w: 1680, h: 140, size: 38, align: .left),
            text("Reference", "John 3:16 ESV", x: 120, y: 985, w: 1680, h: 50, size: 28, bold: true, accent: true, align: .left),
        ] + bar(), folder: thirds)
        let pointScriptureLower = slide("\(pointScriptureCategory) (Lower Third)", [
            text("Point", "Main point goes here", x: 120, y: 835, w: 1680, h: 80, size: 46, bold: true, align: .left),
            text("Verse", "For God so loved the world…", x: 120, y: 920, w: 1680, h: 80, size: 30, align: .left),
            text("Reference", "John 3:16 ESV", x: 120, y: 1005, w: 1680, h: 40, size: 24, bold: true, accent: true, align: .left),
        ] + bar(), folder: thirds)

        let ties = [(pointCategory, pointLower), (scriptureCategory, scriptureLower),
                    (pointScriptureCategory, pointScriptureLower)]
        return Theme(
            id: id, name: style.name, fontFamily: style.font, fontSize: 72, textColorHex: style.textColor,
            backgroundColorHex: "#000000FF",
            slides: [point, scripture, pointScripture, pointLower, scriptureLower, pointScriptureLower],
            streamDesigns: ties.map { StreamDesign(category: $0.0, mode: .design, themeId: id, slideId: $0.1.id) })
    }

    /// The prompt to paste into Claude Design for a new series' artwork.
    public static func claudeDesignPrompt(series: String) -> String {
        """
        Design the slide artwork for a church sermon series called "\(series)". I need two images, both 1920×1080, with NO words on them (my presentation app adds the text):

        1. Background — used behind three full-screen slide types: a sermon point (one large line), a scripture passage (a paragraph of verse text plus its reference), and a point with its supporting verse. Keep the middle calm and dark enough for large white text.
        2. Lower third — a transparent PNG with only a bar or shape across the bottom (roughly the bottom 260 pixels) for text to sit on over a camera shot of the pastor. Everything else fully transparent.

        Also tell me a heading font and a body font (common Mac fonts), a text color and an accent color as hex codes.
        Export 1 as JPG and 2 as PNG.
        """
    }
}
