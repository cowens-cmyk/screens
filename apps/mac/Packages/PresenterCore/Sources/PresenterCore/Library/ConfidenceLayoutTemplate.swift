import Foundation

public enum ConfidenceLayoutTemplate: String, CaseIterable, Sendable {
    case blank
    /// The built-in layout a stage screen falls back to.
    case classic
    case worship
    case sermon

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .classic: "Classic"
        case .worship: "Worship"
        case .sermon: "Sermon"
        }
    }

    public var starterName: String {
        self == .blank ? "Untitled Layout" : title
    }

    public func make(name: String) -> ConfidenceLayout {
        switch self {
        case .blank: ConfidenceLayout(id: UUID().uuidString, name: name, objects: [])
        case .classic: Self.classic(name: name)
        case .worship: Self.worship(name: name)
        case .sermon: Self.sermon(name: name)
        }
    }

    static let amber = "#FFB826FF"
    static let dimmed = "#B8B8B8FF"

    static let green = "#7ED957FF"
    static let yellow = "#FFE500FF"
    static let white = "#FFFFFFFF"

    /// Current lyrics in yellow with Nashville numbers above the words, the
    /// next slide in white, and the clock and song key along the bottom.
    static func worship(name: String) -> ConfidenceLayout {
        var current = linked("Current Slide", .currentSlide,
                             x: 60, y: 40, width: 1800, height: 600,
                             size: 104, color: yellow, shrink: true, minSize: 48, chords: true)
        current.textStyle?.chordNotation = .numbers
        current.textStyle?.chordColorHex = white
        var next = linked("Next Slide", .nextSlide,
                          x: 60, y: 680, width: 1800, height: 260,
                          size: 72, color: white, shrink: true, minSize: 36, chords: true)
        next.textStyle?.chordNotation = .numbers
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                current,
                divider(y: 660),
                next,
                linked("Clock", .clock, x: 60, y: 960, width: 600, height: 100,
                       size: 72, color: white, alignment: .left, tabular: true, clockFormat: "h:mm a"),
                linked("Song Key", .songKey, x: 1260, y: 960, width: 600, height: 100,
                       size: 72, color: yellow, alignment: .right),
            ]
        )
    }

    /// A big sermon countdown, the clock, the current slide and its notes.
    static func sermon(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                box("Timer Box", x: 60, y: 40, width: 1100, height: 330),
                linked("Sermon Timer", .timer, x: 100, y: 70, width: 1020, height: 270,
                       size: 240, color: green, tabular: true, shrink: true, minSize: 80),
                caption("SERMON TIME REMAINING", x: 60, width: 1100, boxBottom: 370),
                box("Clock Box", x: 1200, y: 40, width: 660, height: 330),
                linked("Clock", .clock, x: 1230, y: 70, width: 600, height: 270,
                       size: 140, color: dimmed, tabular: true, shrink: true, clockFormat: "h:mm"),
                caption("CLOCK", x: 1200, width: 660, boxBottom: 370),
                linked("Current Slide", .currentSlide, x: 60, y: 420, width: 1100, height: 600,
                       size: 72, alignment: .left, shrink: true, minSize: 30),
                linked("Notes", .slideNotes, x: 1200, y: 420, width: 660, height: 600,
                       size: 44, color: yellow, alignment: .left, shrink: true, minSize: 20),
            ]
        )
    }

    private static func divider(y: Double) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Divider", text: "")
        object.shapeKind = .rectangle
        object.x = 60
        object.y = y
        object.width = 1800
        object.height = 3
        object.fill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFF55")
        return object
    }

    static func classic(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [

                box("Timer Box", x: 60, y: 40, width: 480, height: 140),
                linked("Timer", .timer, x: 80, y: 56, width: 440, height: 108,
                       size: 84, color: green, tabular: true, shrink: true,
                       minSize: 80),
                caption("TIME REMAINING", x: 60, width: 480, boxBottom: 180),
                box("Video Box", x: 720, y: 40, width: 480, height: 140),

                linked("Video Remaining", .videoCountdown,
                       x: 740, y: 56, width: 440, height: 108,
                       size: 84, color: green, tabular: true, shrink: true),
                caption("VIDEO COUNTDOWN", x: 720, width: 480, boxBottom: 180),
                box("Clock Box", x: 1380, y: 40, width: 480, height: 140),
                linked("Clock", .clock, x: 1400, y: 56, width: 440, height: 108,
                       size: 84, color: dimmed, tabular: true, shrink: true,
                       minSize: 80, clockFormat: "h:mm a"),
                caption("CLOCK", x: 1380, width: 480, boxBottom: 180),
                box("Current Box", x: 60, y: 230, width: 1800, height: 540),
                linked("Current Slide", .currentSlide,
                       x: 100, y: 266, width: 1720, height: 468,
                       size: 110, shrink: true),
                caption("CURRENT SLIDE", x: 60, width: 1800, boxBottom: 770),
                box("Next Box", x: 60, y: 826, width: 1800, height: 194, color: amber),
                linked("Next Slide", .nextSlide,
                       x: 100, y: 848, width: 1720, height: 150,
                       size: 64, color: amber, shrink: true),
                caption("NEXT SLIDE", x: 60, width: 1800, boxBottom: 1020, color: amber),
            ]
        )
    }

    public static func linked(
        _ objectName: String, _ source: TextSourceKind,
        x: Double, y: Double, width: Double, height: Double,
        size: Double, color: String? = nil,
        alignment: TextHorizontalAlignment = .center,
        tabular: Bool = false, shrink: Bool = false, minSize: Double = 20,
        clockFormat: String? = nil,
        chords: Bool = false, maxLines: Int? = nil
    ) -> SlideObject {
        var object = SlideObject(
            id: UUID().uuidString, objectKind: .text,
            name: objectName, text: ""
        )
        object.x = x
        object.y = y
        object.width = width
        object.height = height
        var link = TextLink(source: source, clockFormat: clockFormat)
        link.maxLines = maxLines
        object.textLink = link
        object.textStyle = TextStyle(
            fontSize: size,
            colorHex: color,
            horizontalAlignment: alignment,
            verticalAlignment: .middle,
            tabularFigures: tabular ? true : nil,
            autoShrink: shrink ? true : nil,
            minFontSize: shrink ? minSize : nil,
            showChords: chords ? true : nil
        )
        return object
    }

    private static func box(
        _ objectName: String,
        x: Double, y: Double, width: Double, height: Double,
        color: String = "#FFFFFFFF"
    ) -> SlideObject {
        var object = SlideObject(
            id: UUID().uuidString, objectKind: .shape,
            name: objectName, text: ""
        )
        object.shapeKind = .roundedRectangle
        object.cornerRadius = 24
        object.x = x
        object.y = y
        object.width = width
        object.height = height
        object.fill = ObjectFill(fillKind: .none)
        object.stroke = ObjectStroke(colorHex: color, width: 3)
        return object
    }

    private static func caption(
        _ text: String,
        x: Double, width: Double, boxBottom: Double,
        color: String = "#FFFFFFFF"
    ) -> SlideObject {
        var object = SlideObject(
            id: UUID().uuidString, objectKind: .text,
            name: "Caption", text: text
        )
        object.x = x
        object.y = boxBottom - 18
        object.width = width
        object.height = 36
        object.textStyle = TextStyle(
            fontName: "HelveticaNeue-Bold",
            fontSize: 26,
            colorHex: color,
            tracking: 3,
            horizontalAlignment: .center,
            verticalAlignment: .middle,
            lineFill: TextLineFill(
                fill: ObjectFill(fillKind: .solid, colorHex: "#000000FF"),
                widthMode: .lineWidth,
                horizontalPadding: 22
            )
        )
        return object
    }
}

public extension ConfidenceLayout {

    static func defaultTemplate(name: String) -> ConfidenceLayout {
        ConfidenceLayoutTemplate.classic.make(name: name)
    }
}
