import Foundation

public enum ConfidenceLayoutTemplate: String, CaseIterable, Sendable {
    case blank
    /// The built-in layout a stage screen falls back to.
    case classic
    case worship
    case sermon
    /// What the stage shows while a video plays.
    case video
    /// Before the service and after it ends: a big countdown to the next
    /// service's start.
    case preService

    /// The built-in timers Service Tracking makes from the day's service
    /// times. The Before Service layout shows Until Service; any layout can
    /// show either.
    public static let untilCountdownTimerID = "service_tracking.untilCountdown.remaining"
    public static let untilServiceTimerID = "service_tracking.untilService.remaining"

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .classic: "Classic"
        case .worship: "Worship"
        case .sermon: "Sermon"
        case .video: "Video"
        case .preService: "Before Service"
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
        case .preService: Self.preService(name: name)
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

    /// The Worship words, in the orange the church's ProPresenter stage used.
    static let worshipOrange = "#F0921EFF"
    static let worshipNextGray = "#A0A0A0FF"
    /// The bottom bar's boxes, and a section block's colour when its section
    /// has none of its own.
    static let worshipSlate = "#333A44FF"

    /// Built as the church's ProPresenter stage was, so the musicians read it
    /// the same way. Down the left, a block in the current section's colour
    /// beside the words with its name turned on its side, and one in the next
    /// slide's section colour beside the next lines; that one goes away when
    /// there is no next slide. The words being sung are large, bold and
    /// orange, top-left, so the first line always starts in the same place,
    /// with the chords (Nashville numbers) over them. The next slide's first
    /// lines are grey under them, with their chords too, as the current
    /// slide has them. Along the bottom, three slate boxes: the clock with
    /// seconds, the song, and its key, where a stage message replaces them.
    /// `nextChords: false` is the design before the next lines had chords,
    /// kept only to recognise untouched copies of it.
    static func worship(name: String, nextChords: Bool = true) -> ConfidenceLayout {
        // The column's two blocks: beside the words, and beside the next lines.
        let column: (x: Double, width: Double) = (30, 110)
        let currentBlock: (y: Double, height: Double) = (40, 460)
        let nextBlock: (y: Double, height: Double) = (505, 435)
        let words: (x: Double, width: Double) = (170, 1720)

        let section = sideways("Section", .currentGroup, column: column, block: currentBlock)
        let nextSection = sideways("Next Section", .nextGroup, column: column, block: nextBlock)
        // A block shows only while there is a section name to put in it.
        let sectionBlock = groupBlock("Section Block", .current, column: column, block: currentBlock,
                                      label: section)
        let nextSectionBlock = groupBlock("Next Section Block", .next, column: column, block: nextBlock,
                                          label: nextSection)

        var current = linked("Current Slide", .currentSlide,
                             x: words.x, y: 70, width: words.width, height: 430,
                             size: 112, color: worshipOrange, alignment: .left, shrink: true, minSize: 60,
                             chords: true)
        current.textStyle?.fontName = "HelveticaNeue-Bold"
        current.textStyle?.verticalAlignment = .top
        // The lines as the song has them: a line gets smaller before it
        // breaks, and only breaks (evenly) once it is as small as it goes.
        current.textStyle?.keepLinesWhole = true
        current.textStyle?.balancedWrap = true
        current.textStyle?.chordNotation = .numbers
        // White, since gold chords over orange words were hard to tell apart.
        current.textStyle?.chordColorHex = white
        // The next lines carry their chords like the words being sung, so
        // the band can see the change coming. They are drawn at the same
        // proportion of the (smaller) text, and the box shrinks them to fit.
        var next = linked("Next Slide", .nextSlide,
                          x: words.x, y: 520, width: words.width, height: 350,
                          size: 80, color: worshipNextGray, alignment: .left, shrink: true, minSize: 44,
                          chords: nextChords, maxLines: 3)
        next.textStyle?.fontName = "HelveticaNeue-Bold"
        next.textStyle?.verticalAlignment = .top
        next.textStyle?.keepLinesWhole = true
        next.textStyle?.balancedWrap = true
        next.textStyle?.chordNotation = .numbers
        next.textStyle?.chordColorHex = nextChords ? white : captionGray

        // The bottom bar: three boxes, the words centred in each.
        let bar: (y: Double, height: Double) = (945, 110)
        let pad = 20.0
        let boxes: [(name: String, x: Double, width: Double)] = [
            ("Clock Box", 30, 560), ("Song Box", 610, 700), ("Key Box", 1330, 560),
        ]
        let slates = boxes.map { slate($0.name, x: $0.x, y: bar.y, width: $0.width, height: bar.height) }
        func inside(_ box: Int) -> (x: Double, width: Double) {
            (boxes[box].x + pad, boxes[box].width - pad * 2)
        }
        var clock = linked("Clock", .clock, x: inside(0).x, y: bar.y, width: inside(0).width,
                           height: bar.height, size: 72, color: white, tabular: true,
                           shrink: true, minSize: 40, clockFormat: "h:mm:ssa")
        clock.textStyle?.fontName = "HelveticaNeue-Bold"
        var song = linked("Song", .currentPresentation, x: inside(1).x, y: bar.y, width: inside(1).width,
                          height: bar.height, size: 52, color: white, shrink: true, minSize: 28)
        song.textStyle?.fontName = "HelveticaNeue-Bold"
        var key = linked("Song Key", .songKey, x: inside(2).x, y: bar.y, width: inside(2).width,
                         height: bar.height, size: 60, color: white, shrink: true, minSize: 32)
        key.textStyle?.fontName = "HelveticaNeue-Bold"
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [sectionBlock, section, nextSectionBlock, nextSection, current, next]
                + slates + [clock, song, key]
        )
    }

    /// A section name turned to read bottom to top, centred in its block.
    /// The box is laid out unturned (as wide as the block is tall) and turns
    /// about its centre.
    private static func sideways(
        _ objectName: String, _ source: TextSourceKind,
        column: (x: Double, width: Double), block: (y: Double, height: Double)
    ) -> SlideObject {
        let length = block.height - 20
        let thickness = column.width - 20
        var label = linked(objectName, source,
                           x: column.x + column.width / 2 - length / 2,
                           y: block.y + block.height / 2 - thickness / 2,
                           width: length, height: thickness,
                           size: 54, color: white, shrink: true, minSize: 24)
        label.rotationDegrees = -90
        label.textStyle?.fontName = "HelveticaNeue-Bold"
        label.textStyle?.tracking = 4
        label.textStyle?.textTransform = .uppercase
        return label
    }

    /// A block filled with the current or next slide's section colour, shown
    /// only while `label` has a name in it.
    private static func groupBlock(
        _ objectName: String, _ which: StageGroupColor,
        column: (x: Double, width: Double), block: (y: Double, height: Double),
        label: SlideObject
    ) -> SlideObject {
        var object = slate(objectName, x: column.x, y: block.y, width: column.width, height: block.height)
        object.groupColorFill = which
        object.visibilityConditions = [
            VisibilityCondition(conditionKind: .objectText, state: .hasText, objectId: label.id),
        ]
        return object
    }

    /// A dark slate box behind the bottom bar's words.
    private static func slate(
        _ objectName: String, x: Double, y: Double, width: Double, height: Double
    ) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .shape, name: objectName, text: "")
        object.shapeKind = .roundedRectangle
        object.cornerRadius = 10
        object.x = x
        object.y = y
        object.width = width
        object.height = height
        object.fill = ObjectFill(fillKind: .solid, colorHex: worshipSlate)
        return object
    }

    /// The Worship layout as it was made until November 2026: white words
    /// right of a small section name, NEXT beside the next lines, and the
    /// clock, song and key over a hairline. Kept only to recognise untouched
    /// copies of it.
    ///
    /// `centered` is the design as 0.19.0 made it, the section name over
    /// centred words; kept for the same reason.
    static func previousWorship(name: String, centered: Bool = false) -> ConfidenceLayout {
        // The words start right of a column wide enough for "PRE CHORUS 2".
        let words: (x: Double, width: Double) = centered ? (80, 1760) : (420, 1440)
        let align: TextHorizontalAlignment = centered ? .center : .left
        var section = centered
            ? linked("Section", .currentGroup, x: 80, y: 30, width: 1760, height: 62,
                     size: 40, color: worshipAccent, shrink: true, minSize: 24)
            : linked("Section", .currentGroup, x: 60, y: 92, width: 340, height: 62,
                     size: 40, color: worshipAccent, alignment: .left, shrink: true, minSize: 22)
        section.textStyle?.fontName = "HelveticaNeue-Bold"
        section.textStyle?.tracking = 6
        section.textStyle?.textTransform = .uppercase
        var current = linked("Current Slide", .currentSlide,
                             x: words.x, y: centered ? 100 : 60, width: words.width, height: centered ? 570 : 610,
                             size: 112, color: white, alignment: align, shrink: true, minSize: 64, chords: true)
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
                          x: words.x, y: 740, width: words.width, height: 180,
                          size: 64, color: nextGray, alignment: align, shrink: true, minSize: 40,
                          maxLines: 2)
        next.textStyle?.fontName = "HelveticaNeue-Medium"
        next.textStyle?.verticalAlignment = .top
        next.textStyle?.keepLinesWhole = true
        next.textStyle?.balancedWrap = true
        next.textStyle?.chordNotation = .numbers
        next.textStyle?.chordColorHex = captionGray
        var nextLabel = centered
            ? caption("NEXT", x: 80, y: 694, width: 1760, height: 40, size: 28)
            : caption("NEXT", x: 60, y: 752, width: 340, height: 40, size: 28)
        if !centered { nextLabel.textStyle?.horizontalAlignment = .left }
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

    /// A saved Worship layout still exactly as an earlier template made it
    /// gets the new design's objects; one anybody has touched is left alone.
    public static func upgradedWorshipObjects(for layout: ConfidenceLayout) -> [SlideObject]? {
        let earlier = [
            worship(name: layout.name, nextChords: false),
            legacyWorship(name: layout.name),
            previousWorship(name: layout.name, centered: true),
            previousWorship(name: layout.name),
        ]
        guard earlier.contains(where: { isUntouched(layout, comparedWith: $0) }) else { return nil }
        return worship(name: layout.name).objects
    }

    /// A saved stage layout whose current slide shows chords but whose next
    /// slide does not gets them on the next slide too, in the current
    /// slide's notation and colour; nil when there is nothing to change.
    /// Only a next-slide box that never had Chords switched either way
    /// (the setting unset) is touched, so one someone turned off stays off.
    /// A box showing one named object's text has no chords to show.
    public static func showingNextSlideChords(for layout: ConfidenceLayout) -> [SlideObject]? {
        func isWholeSlide(_ object: SlideObject, _ source: TextSourceKind) -> Bool {
            object.objectKind == .text && object.textLink?.source == source
                && (object.textLink?.sourceObjectName ?? "").isEmpty
        }
        guard let current = layout.objects.first(where: {
            isWholeSlide($0, .currentSlide) && $0.textStyle?.showChords == true
        }) else { return nil }
        var changed = false
        let objects = layout.objects.map { object -> SlideObject in
            guard isWholeSlide(object, .nextSlide), object.textStyle?.showChords == nil else { return object }
            var object = object
            var style = object.textStyle ?? TextStyle()
            style.showChords = true
            if style.chordNotation == nil { style.chordNotation = current.textStyle?.chordNotation }
            // The old Worship template's grey chord colour is the stand-in
            // for "not chosen"; the words being sung have the real one.
            if style.chordColorHex == nil || style.chordColorHex == captionGray {
                style.chordColorHex = current.textStyle?.chordColorHex
            }
            object.textStyle = style
            changed = true
            return object
        }
        return changed ? objects : nil
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

    /// Before the service, and after it ends: one big countdown to the next
    /// service's start and nothing else. With no service to count to (none
    /// left today) the clock takes its place, so the screen never reads
    /// "starts in 0:00" for a service that isn't coming. Which of the two
    /// shows follows the Until Service timer: it runs while a service is
    /// ahead (and holds at 0:00 for a few minutes after the start, see
    /// ServiceStartClock) and is stopped when there is none.
    static func preService(name: String) -> ConfidenceLayout {
        func shown(_ object: SlideObject, whenTimer state: VisibilityConditionState) -> SlideObject {
            var object = object
            object.visibilityConditions = [
                VisibilityCondition(conditionKind: .timer, state: state, timerId: untilServiceTimerID)
            ]
            return object
        }
        var timer = linked("Until Service", .timer, x: 60, y: 250, width: 1800, height: 700,
                           size: 560, color: messageGreen, tabular: true, shrink: true, minSize: 120)
        timer.textLink?.timerId = untilServiceTimerID
        timer.textLink?.usesWarningColor = false
        timer.textStyle?.fontName = "HelveticaNeue-Bold"
        var clock = linked("Clock", .clock, x: 60, y: 250, width: 1800, height: 700,
                           size: 420, color: white, tabular: true, shrink: true, minSize: 120,
                           clockFormat: "h:mm")
        clock.textStyle?.fontName = "HelveticaNeue-Bold"
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                shown(label("SERVICE STARTS IN", y: 170), whenTimer: .isRunning),
                shown(timer, whenTimer: .isRunning),
                shown(label("TIME", y: 170), whenTimer: .isNotRunning),
                shown(clock, whenTimer: .isNotRunning),
            ]
        )
    }

    /// The Before Service layout as it was made until November 2026: how
    /// long until the countdown starts, until the service, and the clock.
    /// Kept only to recognise untouched copies of it.
    static func legacyPreService(name: String) -> ConfidenceLayout {
        func timer(_ objectName: String, _ id: String, y: Double, height: Double, size: Double, color: String) -> SlideObject {
            var timer = linked(objectName, .timer, x: 60, y: y, width: 1800, height: height,
                               size: size, color: color, tabular: true, shrink: true, minSize: 80)
            timer.textLink?.timerId = id
            timer.textLink?.usesWarningColor = false
            timer.textStyle?.fontName = "HelveticaNeue-Bold"
            return timer
        }
        var clock = linked("Clock", .clock, x: 60, y: 930, width: 1800, height: 120,
                           size: 100, color: white, tabular: true, shrink: true, minSize: 40,
                           clockFormat: "h:mm")
        clock.textStyle?.fontName = "HelveticaNeue-Medium"
        return ConfidenceLayout(
            id: UUID().uuidString,
            name: name,
            objects: [
                label("COUNTDOWN STARTS IN", y: 64),
                timer("Until Countdown", untilCountdownTimerID, y: 120, height: 430, size: 380, color: messageGreen),
                rule(y: 580),
                label("SERVICE STARTS IN", y: 610),
                timer("Until Service", untilServiceTimerID, y: 660, height: 230, size: 200, color: white),
                clock,
            ]
        )
    }

    /// A saved Before Service layout that is still exactly what the old
    /// template made (object ids aside) gets the new design's objects. One
    /// anybody has touched, even slightly, is left alone: nil.
    public static func upgradedPreServiceObjects(for layout: ConfidenceLayout) -> [SlideObject]? {
        guard isUntouched(layout, comparedWith: legacyPreService(name: layout.name)) else { return nil }
        return preService(name: layout.name).objects
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

    /// The objects with their ids blanked, and an object a visibility
    /// condition points at named by its place in the list instead, since
    /// every copy of a template gets fresh ids.
    private static func withoutIDs(_ objects: [SlideObject]) -> [SlideObject] {
        let place = Dictionary(objects.enumerated().map { ($1.id, "\($0)") }, uniquingKeysWith: { first, _ in first })
        return objects.map { object in
            var object = object
            object.id = ""
            object.visibilityConditions = object.visibilityConditions?.map { condition in
                var condition = condition
                condition.objectId = condition.objectId.flatMap { place[$0] ?? $0 }
                return condition
            }
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
