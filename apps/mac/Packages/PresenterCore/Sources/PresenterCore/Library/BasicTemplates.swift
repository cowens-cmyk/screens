import Foundation

/// What a fresh library starts with: three themes — Worship, Scripture and
/// Points — each with a full-screen design for the room and a matching
/// lower third for the livestream, already tied together, plus the Worship
/// and Message stage layouts.
public enum BasicTemplates {
    public static let worshipThemeID = "screens.theme.worship"
    public static let scriptureThemeID = "screens.theme.scripture"
    public static let pointsThemeID = "screens.theme.points"
    public static let worshipStageID = "screens.stage.worship"
    public static let messageStageID = "screens.stage.message"

    static let font = "Helvetica Neue"
    static let bold = "HelveticaNeue-Bold"
    static let ink = "#FFFFFFFF"
    static let accent = "#FFB21EFF"
    static let backdrop = "#0B1020FF"
    static let bar = "#000000B8"
    static let lowerThirds = "Lower Thirds"

    public static func themes() -> [Theme] {
        [worship(), scripture(), points()]
    }

    public static func stageLayouts() -> [ConfidenceLayout] {
        var worship = ConfidenceLayoutTemplate.worship.make(name: "Worship")
        worship.id = worshipStageID
        var message = ConfidenceLayoutTemplate.sermon.make(name: "Message")
        message.id = messageStageID
        return [worship, message]
    }

    // MARK: Themes

    static func worship() -> Theme {
        let full = slide("worship.full", "Lyrics", [
            text("worship.full.text", "Lyrics", "Amazing grace how sweet the sound\nThat saved a wretch like me",
                 x: 160, y: 190, w: 1600, h: 700, size: 84, font: bold),
        ])
        let lower = slide("worship.lower", "Lyrics (Lower Third)", folder: lowerThirds, [
            text("worship.lower.text", "Lyrics", "Amazing grace how sweet the sound\nThat saved a wretch like me",
                 x: 120, y: 860, w: 1680, h: 170, size: 46, font: bold),
            barShape("worship.lower.bar", y: 840, h: 210),
        ])
        return theme(worshipThemeID, "Worship", [full, lower], tie: [("Lyrics", lower.id)])
    }

    static func scripture() -> Theme {
        let full = slide("scripture.full", "Bible", [
            text("scripture.full.verse", "Verse", "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.",
                 x: 220, y: 230, w: 1480, h: 540, size: 60, font: font, align: .left),
            text("scripture.full.ref", "Reference", "John 3:16 ESV",
                 x: 220, y: 800, w: 1480, h: 70, size: 36, font: bold, color: accent, align: .left),
        ])
        let lower = slide("scripture.lower", "Bible (Lower Third)", folder: lowerThirds, [
            text("scripture.lower.verse", "Verse", "For God so loved the world, that he gave his only Son…",
                 x: 120, y: 830, w: 1680, h: 150, size: 38, font: font, align: .left),
            text("scripture.lower.ref", "Reference", "John 3:16 ESV",
                 x: 120, y: 985, w: 1680, h: 50, size: 28, font: bold, color: accent, align: .left),
            barShape("scripture.lower.bar", y: 810, h: 250),
        ])
        return theme(scriptureThemeID, "Scripture", [full, lower], tie: [("Bible", lower.id)])
    }

    static func points() -> Theme {
        let full = slide("points.full", "Sermon Points", [
            text("points.full.text", "Point", "Grace changes everything",
                 x: 160, y: 300, w: 1600, h: 480, size: 96, font: bold),
        ])
        let lower = slide("points.lower", "Sermon Points (Lower Third)", folder: lowerThirds, [
            text("points.lower.text", "Point", "Grace changes everything",
                 x: 120, y: 870, w: 1680, h: 140, size: 54, font: bold),
            barShape("points.lower.bar", y: 840, h: 210),
        ])
        return theme(pointsThemeID, "Points", [full, lower], tie: [("Sermon Points", lower.id)])
    }

    // MARK: Building blocks

    static func theme(_ id: String, _ name: String, _ slides: [Slide], tie: [(String, String)]) -> Theme {
        Theme(
            id: id, name: name, fontFamily: font, fontSize: 72, textColorHex: ink,
            backgroundColorHex: backdrop, slides: slides,
            streamDesigns: tie.map { StreamDesign(category: $0.0, mode: .design, themeId: id, slideId: $0.1) })
    }

    static func slide(_ id: String, _ name: String, folder: String? = nil, _ objects: [SlideObject]) -> Slide {
        Slide(id: id, name: name, objects: objects, folder: folder)
    }

    static func text(
        _ id: String, _ name: String, _ sample: String,
        x: Double, y: Double, w: Double, h: Double, size: Double, font: String,
        color: String = ink, align: TextHorizontalAlignment = .center
    ) -> SlideObject {
        SlideObject(
            id: id, objectKind: .text, name: name, text: sample, x: x, y: y, width: w, height: h,
            textStyle: TextStyle(
                fontName: font, fontSize: size, colorHex: color,
                horizontalAlignment: align, verticalAlignment: .middle,
                autoShrink: true, minFontSize: size * 0.5))
    }

    static func barShape(_ id: String, y: Double, h: Double) -> SlideObject {
        SlideObject(
            id: id, objectKind: .shape, name: "Bar", text: "", x: 0, y: y, width: 1920, height: h,
            shapeKind: .rectangle, fill: ObjectFill(fillKind: .solid, colorHex: bar))
    }
}
