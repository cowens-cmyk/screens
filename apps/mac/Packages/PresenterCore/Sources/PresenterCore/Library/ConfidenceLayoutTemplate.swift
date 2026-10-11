import Foundation

public enum ConfidenceLayoutTemplate: String, CaseIterable, Sendable {
    case blank
    case classic
    case currentAndNext
    case timers
    case currentOverNext
    case currentOverNextChords
    case worship
    case sermon

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .classic: "Classic"
        case .currentAndNext: "Current + Next"
        case .timers: "Timers"
        case .currentOverNext: "Current Over Next"
        case .currentOverNextChords: "Current Over Next + Chords"
        case .worship: "Worship"
        case .sermon: "Sermon"
        }
    }

    public var starterName: String {
        self == .blank ? "Untitled Layout" : title
    }

    public static let workspaceStarters: [ConfidenceLayoutTemplate] = [
        .worship, .sermon, .currentAndNext, .timers, .currentOverNext, .currentOverNextChords,
    ]

    public func make(name: String) -> ConfidenceLayout {
        switch self {
        case .blank: ConfidenceLayout(id: UUID().uuidString, name: name, objects: [])
        case .classic: Self.classic(name: name)
        case .currentAndNext: Self.currentAndNext(name: name)
        case .timers: Self.timers(name: name)
        case .currentOverNext: Self.currentOverNext(name: name)
        case .currentOverNextChords: Self.currentOverNextChords(name: name)
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

    static func currentAndNext(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                box("Current Box", x: 60, y: 60, width: 880, height: 680),
                linked("Current Slide", .currentSlide,
                       x: 100, y: 100, width: 800, height: 600,
                       size: 88, alignment: .left, shrink: true),
                caption("CURRENT SLIDE", x: 60, width: 880, boxBottom: 740),
                box("Next Box", x: 980, y: 60, width: 880, height: 680, color: amber),
                linked("Next Slide", .nextSlide,
                       x: 1020, y: 100, width: 800, height: 600,
                       size: 88, color: amber, alignment: .left, shrink: true),
                caption("NEXT SLIDE", x: 980, width: 880, boxBottom: 740, color: amber),
                box("Timer Box", x: 60, y: 800, width: 880, height: 220),
                linked("Timer", .timer, x: 100, y: 820, width: 800, height: 160,
                       size: 120, color: green, tabular: true, shrink: true),
                caption("TIME REMAINING", x: 60, width: 880, boxBottom: 1020),
                box("Clock Box", x: 980, y: 800, width: 880, height: 220),
                linked("Clock", .clock, x: 1020, y: 820, width: 800, height: 160,
                       size: 120, color: dimmed, tabular: true, shrink: true,
                       clockFormat: "h:mm a"),
                caption("CLOCK", x: 980, width: 880, boxBottom: 1020),
            ]
        )
    }

    static func timers(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                box("Timer Box", x: 460, y: 70, width: 1000, height: 280),
                linked("Timer", .timer, x: 500, y: 110, width: 920, height: 200,
                       size: 160, color: green, tabular: true, shrink: true),
                caption("TIME REMAINING", x: 460, width: 1000, boxBottom: 350),
                box("Video Box", x: 460, y: 400, width: 1000, height: 280),
                linked("Video Countdown", .videoCountdown,
                       x: 500, y: 440, width: 920, height: 200,
                       size: 160, color: green, tabular: true, shrink: true),
                caption("VIDEO COUNTDOWN", x: 460, width: 1000, boxBottom: 680),
                box("Clock Box", x: 460, y: 730, width: 1000, height: 280),
                linked("Clock", .clock, x: 500, y: 770, width: 920, height: 200,
                       size: 160, color: green, tabular: true, shrink: true,
                       clockFormat: "h:mm a"),
                caption("CLOCK", x: 460, width: 1000, boxBottom: 1010),
            ]
        )
    }

    static func currentOverNext(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                linked("Clock", .clock, x: 660, y: 28, width: 600, height: 64,
                       size: 48, color: dimmed, tabular: true, clockFormat: "h:mm a"),
                box("Current Box", x: 60, y: 116, width: 1800, height: 550),
                linked("Current Slide", .currentSlide,
                       x: 100, y: 156, width: 1720, height: 470,
                       size: 110, shrink: true),
                caption("CURRENT SLIDE", x: 60, width: 1800, boxBottom: 666),
                box("Next Box", x: 60, y: 726, width: 1800, height: 294, color: amber),
                linked("Next Slide", .nextSlide,
                       x: 100, y: 756, width: 1720, height: 234,
                       size: 76, color: amber, shrink: true),
                caption("NEXT SLIDE", x: 60, width: 1800, boxBottom: 1020, color: amber),
            ]
        )
    }

    static func currentOverNextChords(name: String) -> ConfidenceLayout {
        ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                linked("Clock", .clock, x: 660, y: 28, width: 600, height: 64,
                       size: 48, color: dimmed, tabular: true, clockFormat: "h:mm a"),
                box("Current Box", x: 60, y: 116, width: 1800, height: 590),
                linked("Current Slide", .currentSlide,
                       x: 100, y: 156, width: 1720, height: 510,
                       size: 96, alignment: .left, shrink: true, chords: true),
                caption("CURRENT SLIDE", x: 60, width: 1800, boxBottom: 706),
                box("Next Box", x: 60, y: 766, width: 1800, height: 254, color: amber),
                linked("Next Slide", .nextSlide,
                       x: 100, y: 796, width: 1720, height: 194,
                       size: 72, alignment: .left, chords: true, maxLines: 1),
                caption("NEXT SLIDE", x: 60, width: 1800, boxBottom: 1020, color: amber),
            ]
        )
    }

    static func linked(
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
