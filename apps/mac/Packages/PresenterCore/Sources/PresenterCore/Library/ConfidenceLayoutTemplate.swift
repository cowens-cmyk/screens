import Foundation

public enum ConfidenceLayoutTemplate: String, CaseIterable, Sendable {
    case blank
    /// The built-in layout a stage screen falls back to.
    case classic
    case worship
    case sermon
    /// What the stage shows while a video plays.
    case video

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .classic: "Classic"
        case .worship: "Worship"
        case .sermon: "Sermon"
        case .video: "Video"
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
        case .video: Self.video(name: name)
        }
    }

    static let amber = "#FFB826FF"
    static let dimmed = "#B8B8B8FF"

    static let green = "#7ED957FF"
    static let yellow = "#FFE500FF"
    static let white = "#FFFFFFFF"

    /// The Worship accent: section name, chords and key. One colour, so
    /// nothing else on the screen competes with the words.
    static let worshipAccent = "#F5C04AFF"
    static let nextGray = "#A1A1A6FF"

    /// Built for reading from the platform. The words being sung, large,
    /// bold and white, start at the same place on every slide so the eye
    /// knows where to look; the section name sits small above them and the
    /// chords (Nashville numbers) are in the accent over the words. The next
    /// slide's first two lines are smaller and grey under a small NEXT,
    /// which goes away on the last slide. The clock, song and key run along
    /// the bottom, where a stage message replaces them.
    static func worship(name: String) -> ConfidenceLayout {
        var section = linked("Section", .currentGroup, x: 80, y: 30, width: 1760, height: 62,
                             size: 40, color: worshipAccent, shrink: true, minSize: 24)
        section.textStyle?.fontName = "HelveticaNeue-Bold"
        section.textStyle?.tracking = 6
        section.textStyle?.textTransform = .uppercase
        var current = linked("Current Slide", .currentSlide,
                             x: 80, y: 100, width: 1760, height: 570,
                             size: 112, color: white, shrink: true, minSize: 64, chords: true)
        current.textStyle?.fontName = "HelveticaNeue-Bold"
        current.textStyle?.verticalAlignment = .top
        // The lines as the song has them: a line gets smaller before it
        // breaks, and only breaks (evenly) once it is as small as it goes.
        current.textStyle?.keepLinesWhole = true
        current.textStyle?.balancedWrap = true
        current.textStyle?.chordNotation = .numbers
        current.textStyle?.chordColorHex = worshipAccent
        // The next lines are a glance ahead; chords there were too small to
        // read and crowded the words.
        var next = linked("Next Slide", .nextSlide,
                          x: 80, y: 740, width: 1760, height: 180,
                          size: 64, color: nextGray, shrink: true, minSize: 40,
                          maxLines: 2)
        next.textStyle?.fontName = "HelveticaNeue-Medium"
        next.textStyle?.verticalAlignment = .top
        next.textStyle?.keepLinesWhole = true
        next.textStyle?.balancedWrap = true
        next.textStyle?.chordNotation = .numbers
        next.textStyle?.chordColorHex = captionGray
        var nextLabel = caption("NEXT", x: 80, y: 694, width: 1760, height: 40, size: 28)
        // Only while there is a next slide to label.
        nextLabel.visibilityConditions = [
            VisibilityCondition(conditionKind: .objectText, state: .hasText, objectId: next.id),
        ]
        var clock = linked("Clock", .clock, x: 60, y: 960, width: 460, height: 92,
                           size: 60, color: white, alignment: .left, tabular: true,
                           shrink: true, minSize: 36, clockFormat: "h:mm")
        clock.textStyle?.fontName = "HelveticaNeue-Medium"
        var song = linked("Song", .currentPresentation, x: 540, y: 960, width: 840, height: 92,
                          size: 44, color: captionGray, shrink: true, minSize: 28)
        song.textStyle?.fontName = "HelveticaNeue-Medium"
        var key = linked("Song Key", .songKey, x: 1400, y: 960, width: 460, height: 92,
                         size: 60, color: worshipAccent, alignment: .right, shrink: true, minSize: 36)
        key.textStyle?.fontName = "HelveticaNeue-Bold"
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [section, current, nextLabel, next, hairline(y: 940), clock, song, key]
        )
    }

    /// A saved Worship layout still exactly as the old template made it
    /// gets the new design's objects; one anybody has touched is left alone.
    public static func upgradedWorshipObjects(for layout: ConfidenceLayout) -> [SlideObject]? {
        guard isUntouched(layout, comparedWith: legacyWorship(name: layout.name)) else { return nil }
        return worship(name: layout.name).objects
    }

    /// The name of the box in the Video layout where the video plays. The
    /// stage puts the picture inside it, fitted to the video's shape.
    public static let videoBoxName = "Video"

    /// While a video plays: the time it has left, large, in the Message
    /// timer's green and font, above the video itself. Along the bottom,
    /// smaller, the sermon timer (shown only during the Message) and the
    /// clock, in the same fonts and colours as on the Message layout.
    static func video(name: String) -> ConfidenceLayout {
        var remaining = linked("Video Remaining", .videoCountdown, x: 60, y: 10, width: 1800, height: 232,
                               size: 220, color: messageGreen, tabular: true, shrink: true, minSize: 80)
        remaining.textLink?.showsVideoName = false
        // Green to the end: red on the stage means the message is over time.
        remaining.textLink?.usesWarningColor = false
        remaining.textStyle?.fontName = "HelveticaNeue-Bold"
        var box = SlideObject(id: UUID().uuidString, objectKind: .shape, name: videoBoxName, text: "")
        box.shapeKind = .rectangle
        box.x = 360
        box.y = 252
        box.width = 1200
        box.height = 675
        box.fill = ObjectFill(fillKind: .solid, colorHex: "#141414FF")
        var timer = linked("Sermon Timer", .timer, x: 60, y: 936, width: 760, height: 134,
                           size: 110, color: messageGreen, alignment: .left, tabular: true,
                           shrink: true, minSize: 48)
        timer.textLink?.timerId = SermonTimer.id
        timer.textLink?.usesWarningColor = false
        timer.textStyle?.fontName = "HelveticaNeue-Bold"
        var clock = linked("Clock", .clock, x: 1100, y: 936, width: 760, height: 134,
                           size: 110, color: white, alignment: .right, tabular: true,
                           shrink: true, minSize: 48, clockFormat: "h:mm")
        clock.textStyle?.fontName = "HelveticaNeue-Medium"
        return ConfidenceLayout(id: UUID().uuidString, name: name, objects: [remaining, box, timer, clock])
    }

    /// The Worship layout as it was made until October 2026: yellow lyrics
    /// over the next slide in white. Kept only to recognise untouched copies.
    static func legacyWorship(name: String) -> ConfidenceLayout {
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

    /// The time left for the message, as big as the screen allows: green
    /// while there's time, red once it runs past 0:00 (it keeps counting,
    /// so the preacher sees how far over). The time of day sits under it in
    /// white. Each has a small caption so nobody mistakes one for the other.
    static func sermon(name: String) -> ConfidenceLayout {
        var timer = linked("Sermon Timer", .timer, x: 60, y: 120, width: 1800, height: 560,
                           size: 480, color: messageGreen, tabular: true, shrink: true, minSize: 120)
        timer.textLink?.timerId = SermonTimer.id
        // Green the whole way down, then red past zero: no amber step.
        timer.textLink?.usesWarningColor = false
        timer.textStyle?.fontName = "HelveticaNeue-Bold"
        var clock = linked("Clock", .clock, x: 60, y: 800, width: 1800, height: 220,
                           size: 190, color: white, tabular: true, shrink: true, minSize: 60,
                           clockFormat: "h:mm")
        clock.textStyle?.fontName = "HelveticaNeue-Medium"
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                label("MESSAGE", y: 64),
                timer,
                rule(y: 712),
                label("TIME", y: 742),
                clock,
            ]
        )
    }

    static let messageGreen = "#30D158FF"
    static let captionGray = "#8E8E93FF"

    /// A small, widely spaced caption across the screen.
    private static func label(_ text: String, y: Double) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .text, name: "Caption", text: text)
        object.x = 60
        object.y = y
        object.width = 1800
        object.height = 50
        object.textStyle = TextStyle(
            fontName: "HelveticaNeue-Bold",
            fontSize: 34,
            colorHex: captionGray,
            tracking: 8,
            horizontalAlignment: .center,
            verticalAlignment: .middle
        )
        return object
    }

    /// A small, widely spaced grey caption.
    private static func caption(
        _ text: String, x: Double, y: Double, width: Double, height: Double, size: Double
    ) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .text, name: "Caption", text: text)
        object.x = x
        object.y = y
        object.width = width
        object.height = height
        object.textStyle = TextStyle(
            fontName: "HelveticaNeue-Bold",
            fontSize: size,
            colorHex: captionGray,
            tracking: 6,
            horizontalAlignment: .center,
            verticalAlignment: .middle
        )
        return object
    }

    /// A faint line across the screen, above the clock and key.
    private static func hairline(y: Double) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Divider", text: "")
        object.shapeKind = .rectangle
        object.x = 60
        object.y = y
        object.width = 1800
        object.height = 2
        object.fill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFF26")
        return object
    }

    /// A short hairline between the timer and the clock.
    private static func rule(y: Double) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .shape, name: "Divider", text: "")
        object.shapeKind = .rectangle
        object.x = 810
        object.y = y
        object.width = 300
        object.height = 3
        object.fill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFF40")
        return object
    }

    /// A saved Message layout that is still exactly what the old template
    /// made (object ids aside) gets the new design's objects. One anybody has
    /// touched, even slightly, is left alone: nil.
    public static func upgradedSermonObjects(for layout: ConfidenceLayout) -> [SlideObject]? {
        guard isUntouched(layout, comparedWith: legacySermon(name: layout.name)) else { return nil }
        return sermon(name: layout.name).objects
    }

    private static func isUntouched(_ layout: ConfidenceLayout, comparedWith template: ConfidenceLayout) -> Bool {
        layout.canvasWidth == nil && layout.canvasHeight == nil && layout.multiView == nil
            && (layout.animationOrder?.isEmpty ?? true)
            && withoutIDs(layout.objects) == withoutIDs(template.objects)
    }

    private static func withoutIDs(_ objects: [SlideObject]) -> [SlideObject] {
        objects.map { object in
            var object = object
            object.id = ""
            return object
        }
    }

    /// The Message layout as it was made until October 2026: a sermon
    /// countdown and clock in outlined boxes over the current slide and its
    /// notes. Kept only to recognise untouched copies of it.
    static func legacySermon(name: String) -> ConfidenceLayout {
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
