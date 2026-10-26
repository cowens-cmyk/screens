import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public struct CueAlert: Sendable, Equatable {
    public var id: String
    public var message: String
    public var behavior: AlertBehavior
    public var target: AlertTarget

    public var layer: LayerKind?

    public var theme: Theme?

    /// When it was sent: the stage bar flashes once as it appears, so the
    /// person on stage notices it.
    public var firedAt: Date

    /// When it leaves the stage by itself (Settings › Show Setup › Stage
    /// messages). Nil: until cleared. Every stage screen stops drawing it at
    /// this moment, whenever the controls get round to clearing it.
    public var expiresAt: Date?

    public init(
        id: String = UUID().uuidString,
        message: String,
        behavior: AlertBehavior,
        target: AlertTarget = .confidence,
        theme: Theme? = nil,
        layer: LayerKind? = nil,
        firedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.firedAt = firedAt
        self.expiresAt = expiresAt
        self.message = message
        self.behavior = behavior
        self.target = target
        self.theme = theme
        self.layer = layer
    }

    public var showsOnConfidence: Bool { target != .audience }

    public var showsOnAudience: Bool { target != .confidence }
}

public struct TimerWarning: Codable, Sendable, Equatable, Identifiable {
    public var remainingSeconds: TimeInterval

    public var colorHex: String

    public var id: String { "\(remainingSeconds)-\(colorHex)" }

    public init(remainingSeconds: TimeInterval, colorHex: String) {
        self.remainingSeconds = remainingSeconds
        self.colorHex = colorHex
    }

    public static let amberHex = "#FFB826FF"
    public static let redHex = "#FF4739FF"

    /// Ink for a countdown that has run past zero. It outranks every warning
    /// level and the text's own colour, so "over time" always reads the same.
    public static let overtimeHex = "#FF3B30FF"
    public static let defaults = [
        TimerWarning(remainingSeconds: 30, colorHex: amberHex),
        TimerWarning(remainingSeconds: 0, colorHex: redHex),
    ]
}

public struct TimerSnapshot: Sendable, Equatable, Identifiable {
    public enum Mode: Sendable, Equatable {

        case countdown

        case countdownToTime

        case countUp
    }

    public enum Urgency: Sendable, Equatable {
        case normal
        case warning
        case overrun
    }

    public func remaining(at date: Date) -> TimeInterval? {
        switch mode {
        case .countdown, .countdownToTime:
            return value(at: date)
        case .countUp:
            guard durationSeconds > 0 else { return nil }
            return durationSeconds - elapsed(at: date)
        }
    }

    public var isIdle: Bool {
        !isRunning && banked == 0 && durationSeconds == 0 && (mode != .countdownToTime || targetTime == nil)
    }

    /// Whether the timer is past its zero: a countdown counting on into
    /// negative time, or a count-up beyond its limit.
    public func isOvertime(at date: Date) -> Bool {
        guard !isIdle, let remaining = remaining(at: date) else { return false }
        return remaining < 0
    }

    /// The colour the time should read in: overtime red first, then the
    /// active warning level, else nil (the caller's normal colour).
    public func inkHex(at date: Date) -> String? {
        if isOvertime(at: date) { return TimerWarning.overtimeHex }
        return activeWarning(at: date)?.colorHex
    }

    public func activeWarning(at date: Date) -> TimerWarning? {
        guard !isIdle, let remaining = remaining(at: date) else { return nil }
        return warnings
            .filter { $0.remainingSeconds >= remaining }
            .min { $0.remainingSeconds < $1.remainingSeconds }
    }

    public func urgency(at date: Date) -> Urgency {
        if isOvertime(at: date) { return .overrun }
        guard let warning = activeWarning(at: date) else { return .normal }
        return warning.remainingSeconds <= 0 ? .overrun : .warning
    }

    public static let warningThreshold: TimeInterval = 30

    public var id: String
    public var name: String
    public var mode: Mode
    public var isRunning: Bool

    public var runningSince: Date?

    public var banked: TimeInterval

    public var durationSeconds: TimeInterval

    public var targetTime: Date?

    public var armedAt: Date?

    public var warnings: [TimerWarning]

    /// nil or true: a countdown keeps running past zero into negative time.
    /// false: it holds at 0:00. Optional so timers saved before the option
    /// existed keep counting.
    public var keepsCountingAfterZero: Bool?

    public var countsPastZero: Bool { keepsCountingAfterZero != false }

    public init(
        id: String = UUID().uuidString,
        name: String,
        mode: Mode,
        isRunning: Bool = false,
        runningSince: Date? = nil,
        banked: TimeInterval = 0,
        durationSeconds: TimeInterval = 0,
        targetTime: Date? = nil,
        armedAt: Date? = nil,
        warnings: [TimerWarning] = TimerWarning.defaults,
        keepsCountingAfterZero: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isRunning = isRunning
        self.runningSince = runningSince
        self.banked = banked
        self.durationSeconds = durationSeconds
        self.targetTime = targetTime
        self.armedAt = armedAt
        self.warnings = warnings
        self.keepsCountingAfterZero = keepsCountingAfterZero
    }

    public var isLive: Bool {
        isRunning || mode == .countdownToTime
    }

    public func elapsed(at date: Date) -> TimeInterval {
        banked + (isRunning ? max(0, date.timeIntervalSince(runningSince ?? date)) : 0)
    }

    /// Seconds to show. Countdowns go negative past zero (the display then
    /// counts up with a leading minus) unless the timer is set to hold at zero.
    public func value(at date: Date) -> TimeInterval {
        let raw: TimeInterval
        switch mode {
        case .countUp: return elapsed(at: date)
        case .countdown: raw = durationSeconds - elapsed(at: date)
        case .countdownToTime: raw = (targetTime ?? date).timeIntervalSince(date)
        }
        return countsPastZero ? raw : max(0, raw)
    }

    public func displayString(at date: Date) -> String {
        Self.timecode(displayValue(at: date))
    }

    public func displayValue(at date: Date) -> TimeInterval {
        value(at: date).rounded(.towardZero)
    }

    public func displayString(at date: Date, format: TimerTextFormat?, pattern: String? = nil) -> String {
        Self.text(value(at: date), format: format, pattern: pattern)
    }

    public static func text(_ seconds: TimeInterval, format: TimerTextFormat?, pattern: String?) -> String {
        if let pattern, !pattern.isEmpty {
            return TimerPattern.text(seconds, pattern: pattern)
        } else {
            return text(seconds, format: format ?? .digits)
        }
    }

    public static func text(_ seconds: TimeInterval, format: TimerTextFormat) -> String {
        switch format {
        case .digits: return timecode(seconds)
        case .abbreviated: return units(seconds, labels: ("d", "h", "m", "s"), spaced: false)
        case .words: return units(seconds, labels: ("day", "hour", "minute", "second"), spaced: true)
        }
    }

    private static func units(
        _ seconds: TimeInterval, labels: (String, String, String, String), spaced: Bool
    ) -> String {
        let total = Int(seconds.rounded(.towardZero))
        let magnitude = abs(total)
        let parts: [(Int, String)] = [
            (magnitude / 86400, labels.0), ((magnitude / 3600) % 24, labels.1),
            ((magnitude / 60) % 60, labels.2), (magnitude % 60, labels.3),
        ]
        var started = false
        var words: [String] = []
        for (index, (count, label)) in parts.enumerated() {
            let last = index == parts.count - 1
            guard started || count > 0 || last else { continue }
            started = true
            let unit = spaced ? " \(label)\(count == 1 ? "" : "s")" : label
            words.append("\(count)\(unit)")
        }
        let sign = total < 0 ? "-" : ""
        return sign + words.joined(separator: " ")
    }

    public func progress(at date: Date) -> Double? {
        switch mode {
        case .countUp, .countdown:
            guard durationSeconds > 0 else { return nil }
            return min(1, max(0, elapsed(at: date) / durationSeconds))
        case .countdownToTime:
            guard let armedAt, let targetTime else { return nil }
            let span = targetTime.timeIntervalSince(armedAt)
            guard span > 0 else { return 1 }
            return min(1, max(0, date.timeIntervalSince(armedAt) / span))
        }
    }

    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.towardZero))
        let magnitude = abs(total)
        let sign = seconds < 0 && magnitude > 0 ? "-" : ""
        if magnitude >= 3600 {
            return String(
                format: "%@%d:%02d:%02d",
                sign, magnitude / 3600, (magnitude / 60) % 60, magnitude % 60
            )
        }
        return String(format: "%@%d:%02d", sign, magnitude / 60, magnitude % 60)
    }
}

public struct VideoCountdown: Sendable, Equatable {
    public var name: String
    public var duration: Double

    public var position: Double
    public var anchoredAt: Date
    public var isPlaying: Bool
    /// The layer it plays on, so the stage can show that layer's picture.
    public var layer: LayerKind

    public init(
        name: String, duration: Double, position: Double,
        anchoredAt: Date, isPlaying: Bool, layer: LayerKind = .videos
    ) {
        self.name = name
        self.duration = duration
        self.position = position
        self.anchoredAt = anchoredAt
        self.isPlaying = isPlaying
        self.layer = layer
    }

    public func remaining(at date: Date) -> Double {
        let advance = isPlaying ? max(0, date.timeIntervalSince(anchoredAt)) : 0
        return max(0, duration - (position + advance))
    }
}

public struct ConfidenceInfo: Sendable, Equatable {

    public struct SlideText: Sendable, Equatable {
        public var body: String

        public var chords: [ChordPlacement]

        public var musicKey: String?
        public var displayKey: String?

        public var stepIndex: Int?

        public var stepCount: Int?

        public var objectTexts: [ObjectText]?

        public var notes: String?

        public struct ObjectText: Sendable, Equatable {
            public var name: String
            public var text: String

            public init(name: String, text: String) {
                self.name = name
                self.text = text
            }
        }

        public init(
            body: String,
            chords: [ChordPlacement] = [],
            musicKey: String? = nil,
            displayKey: String? = nil,
            stepIndex: Int? = nil,
            stepCount: Int? = nil,
            objectTexts: [ObjectText]? = nil,
            notes: String? = nil
        ) {
            self.notes = notes
            self.body = body
            self.chords = chords
            self.musicKey = musicKey
            self.displayKey = displayKey
            self.stepIndex = stepIndex
            self.stepCount = stepCount
            self.objectTexts = objectTexts
        }
    }

    public struct SlidePosition: Sendable, Equatable {
        public var index: Int
        public var total: Int

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    public var current: SlideText?
    public var next: SlideText?

    public var nextStep: SlideText?

    public var last: SlideText?
    public var alert: CueAlert?

    public var alertVisible: Bool
    public var timers: [TimerSnapshot]

    public var videoCountdown: VideoCountdown?

    public var videoCountdowns: [String: VideoCountdown]

    /// The message on the stage now: one meant for the stage that hasn't run
    /// past its time. A flashing alert's off beats are `alertVisible`.
    public func stageAlert(at date: Date) -> CueAlert? {
        guard let alert, alert.showsOnConfidence,
              !StageMessageTiming.hasExpired(alert.expiresAt, at: date)
        else { return nil }
        return alert
    }

    public func videoCountdown(forLayer layer: String?) -> VideoCountdown? {
        guard let layer, !layer.isEmpty else { return videoCountdown }
        return videoCountdowns[layer]
    }

    public var slidePosition: SlidePosition?

    public var currentItemName: String?

    public var currentGroupName: String?
    public var nextItemName: String?

    public var currentPresentationName: String?

    public var nextServiceTitle: String?

    public var audioCountdown: VideoCountdown?

    public var activeLiveInputIds: [String]

    public var connectedLiveInputIds: [String]

    public var captureActive: Bool

    public init(
        current: SlideText? = nil,
        next: SlideText? = nil,
        last: SlideText? = nil,
        alert: CueAlert? = nil,
        alertVisible: Bool = true,
        timers: [TimerSnapshot] = [],
        videoCountdown: VideoCountdown? = nil,
        videoCountdowns: [String: VideoCountdown] = [:],
        slidePosition: SlidePosition? = nil,
        currentItemName: String? = nil,
        currentGroupName: String? = nil,
        nextItemName: String? = nil,
        currentPresentationName: String? = nil,
        nextServiceTitle: String? = nil,
        audioCountdown: VideoCountdown? = nil,
        activeLiveInputIds: [String] = [],
        connectedLiveInputIds: [String] = [],
        captureActive: Bool = false
    ) {
        self.current = current
        self.next = next
        self.last = last
        self.alert = alert
        self.alertVisible = alertVisible
        self.timers = timers
        self.videoCountdown = videoCountdown
        self.videoCountdowns = videoCountdowns
        self.slidePosition = slidePosition
        self.currentItemName = currentItemName
        self.currentGroupName = currentGroupName
        self.nextItemName = nextItemName
        self.currentPresentationName = currentPresentationName
        self.nextServiceTitle = nextServiceTitle
        self.audioCountdown = audioCountdown
        self.activeLiveInputIds = activeLiveInputIds
        self.connectedLiveInputIds = connectedLiveInputIds
        self.captureActive = captureActive
    }
}

public enum ConfidenceSceneBuilder {

    public static let amber = SceneColor(red: 1.0, green: 0.72, blue: 0.15)
    public static let stageRed = SceneColor(red: 0.84, green: 0.13, blue: 0.13)

    public static let builtInLayout: ConfidenceLayout = {
        var layout = ConfidenceLayout.defaultTemplate(name: "Built-in Layout")
        layout.id = "built-in"
        return layout
    }()

    public static func scene(info: ConfidenceInfo, at date: Date) -> RenderScene {
        scene(layout: builtInLayout, info: info, at: date)
    }

    public static func scene(
        layout: ConfidenceLayout,
        info: ConfidenceInfo,
        at date: Date
    ) -> RenderScene {
        scene(layout: layout, info: info, at: date, messageStyle: nil, layer: { _ in .slide })
    }

    /// `messageStyle` decides where a stage message goes instead of the
    /// layout's own shape; `layer` puts each object on a scene layer (the
    /// Video layout draws what is under its video box below the picture).
    static func scene(
        layout: ConfidenceLayout,
        info: ConfidenceInfo,
        at date: Date,
        messageStyle: StageMessageStyle?,
        layer: (SlideObject) -> LayerKind
    ) -> RenderScene {
        let canvasSize = CGSize(
            width: layout.canvasWidth.map(Double.init) ?? SlideSceneBuilder.canvasSize.width,
            height: layout.canvasHeight.map(Double.init) ?? SlideSceneBuilder.canvasSize.height
        )
        var scene = RenderScene(canvasSize: canvasSize)
        let resolved = LinkedText.resolvedObjects(layout.objects, info: info, at: date)

        let objects = resolved.filter {
            VisibilityRules.isShown($0, among: resolved, info: info, at: date)
        }
        let alert = info.stageAlert(at: date)
        let style = alert.map { _ in messageStyle ?? StageMessagePlacement.style(for: layout) }

        // What the layout itself shows: faded out under the Message stage's
        // takeover, and without the clock and key the Worship band replaces.
        var layoutOpacity = 1.0
        var replaced: Set<String> = []
        switch style {
        case .takeover:
            if let alert {
                layoutOpacity = 1 - StageMessageTiming.presence(
                    firedAt: alert.firedAt, expiresAt: alert.expiresAt, at: date)
            }
        case .band(_, let ids):
            replaced = Set(ids)
        case .linkedObject, .banner, nil:
            break
        }
        if layoutOpacity > 0 {
            let wiring = SlideSceneBuilder.maskWiring(for: objects)
            for object in objects where !replaced.contains(object.id) {
                for var item in SlideSceneBuilder.renderItems(
                    for: object, theme: nil, in: canvasSize,
                    baseID: "confidence-\(layout.id)-\(object.id)",
                    maskedBy: wiring.maskedBy[object.id],
                    matteGroup: wiring.mattes.contains(object.id) ? object.id : nil
                ) {
                    item.opacity *= layoutOpacity
                    scene.addItem(item, to: layer(object))
                }
            }
        }

        guard let alert, let style else { return scene }
        switch style {
        case .linkedObject:
            // The layout's own Stage Message box already shows it.
            break
        case .banner:
            guard info.alertVisible else { break }
            for item in AlertSceneBuilder.bannerItems(
                for: alert, canvasSize: canvasSize, info: info, at: date, size: .stage
            ) {
                scene.addItem(item, to: .alerts)
            }
        case .band(let band, _):
            for item in AlertSceneBuilder.bandItems(
                for: alert, in: band, canvasSize: canvasSize, info: info, at: date
            ) {
                scene.addItem(item, to: .alerts)
            }
        case .takeover(let ids):
            let presence = StageMessageTiming.presence(
                firedAt: alert.firedAt, expiresAt: alert.expiresAt, at: date)
            guard presence > 0 else { break }
            let frames = StageMessagePlacement.takeoverFrames(canvas: canvasSize, slots: ids.count)
            let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, slot) in zip(ids, frames.slots) {
                // One the layout hides right now (a visibility rule) stays hidden.
                guard let object = byID[id] else { continue }
                for var item in SlideSceneBuilder.renderItems(
                    for: stripObject(object, in: slot), theme: nil, in: canvasSize,
                    baseID: "confidence-\(layout.id)-\(object.id)-strip"
                ) {
                    item.opacity *= presence
                    scene.addItem(item, to: .slide)
                }
            }
            if info.alertVisible {
                for var item in AlertSceneBuilder.takeoverItems(
                    for: alert, in: frames.message, canvasSize: canvasSize, info: info, at: date
                ) {
                    item.opacity *= presence
                    scene.addItem(item, to: .alerts)
                }
            }
        }
        return scene
    }

    /// A time from the layout, moved into its place in the strip: its own
    /// colours, font and overtime ink, sized to the strip.
    static func stripObject(_ object: SlideObject, in slot: CGRect) -> SlideObject {
        var object = object
        object.x = slot.minX
        object.y = slot.minY
        object.width = slot.width
        object.height = slot.height
        object.rotationDegrees = nil
        var style = object.textStyle ?? TextStyle()
        style.fontSize = slot.height * 0.8
        style.autoShrink = true
        style.minFontSize = slot.height * 0.3
        style.horizontalAlignment = .center
        style.verticalAlignment = .middle
        object.textStyle = style
        return object
    }

    static func primaryTimer(_ timers: [TimerSnapshot]) -> TimerSnapshot? {
        timers.first(where: \.isLive) ?? timers.first
    }

    public static func lyricText(for slide: Slide) -> String {
        lyricObjects(of: slide)
            .map(\.text)
            .joined(separator: "\n")
    }

    static func lyricObjects(of slide: Slide) -> [SlideObject] {
        slide.objects.filter {
            $0.objectKind == .text && (!$0.text.isEmpty || $0.chords?.isEmpty == false)
        }
    }

    public static func hasLyricContent(_ slide: Slide) -> Bool {
        !lyricObjects(of: slide).isEmpty
    }

    public static func lyricChords(for slide: Slide) -> [ChordPlacement] {
        var chords: [ChordPlacement] = []
        var lineOffset = 0
        for object in lyricObjects(of: slide) {
            for chord in object.chords ?? [] {
                chords.append(ChordPlacement(
                    line: chord.line + lineOffset, column: chord.column, symbol: chord.symbol
                ))
            }
            lineOffset += object.text.components(separatedBy: "\n").count
        }
        return chords
    }

    public static func slideText(for slide: Slide, in presentation: Presentation?) -> ConfidenceInfo.SlideText {

        let objectTexts = slide.objects.compactMap { object -> ConfidenceInfo.SlideText.ObjectText? in
            guard !object.name.isEmpty, !object.text.isEmpty else { return nil }
            return .init(name: object.name, text: object.text)
        }
        return ConfidenceInfo.SlideText(
            body: lyricText(for: slide),
            chords: lyricChords(for: slide),
            musicKey: presentation?.musicKey,
            displayKey: presentation?.displayKey,
            objectTexts: objectTexts.isEmpty ? nil : objectTexts,
            notes: slide.notes
        )
    }

    public static func nextSlide(in upcoming: [Slide], skippingBlanks: Bool) -> Slide? {
        skippingBlanks
            ? upcoming.first(where: hasLyricContent)
            : upcoming.first
    }

    static func clockString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", twelve, parts.minute ?? 0)
    }
}

public enum AlertSceneBuilder {

    public static func alertsThemeSlide(in theme: Theme?) -> Slide? {
        theme?.slides?.first { $0.name.caseInsensitiveCompare("Alerts") == .orderedSame }
    }

    public static func audienceItems(
        for alert: CueAlert, canvasSize: CGSize,
        info: ConfidenceInfo? = nil, at date: Date = Date()
    ) -> [RenderItem] {
        guard let theme = alert.theme,
              var template = alertsThemeSlide(in: theme)
        else { return bannerItems(for: alert, canvasSize: canvasSize, info: info, at: date) }

        if let info {
            template.objects = LinkedText.resolvedObjects(template.objects, info: info, at: date)
        }

        let messageText = info.map {
            LinkedText.resolvedAlertMessage(alert.message, info: $0, at: date)
        } ?? alert.message
        let message = SlideObject(
            id: "alert-message", objectKind: .text, name: "Message", text: messageText
        )
        let objects = [message]
        let placeholders = SlideSceneBuilder.placeholderAssignments(for: objects, in: template)
        let stack = SlideSceneBuilder.composedStack(for: objects, in: template)

        let wiring = SlideSceneBuilder.maskWiring(for: stack.map(\.object))

        let steps = AnimationSequence.sceneSteps(objects: stack.map(\.object), order: template.animationOrder)
        return stack.flatMap { entry in
            SlideSceneBuilder.renderItems(
                for: entry.object, theme: theme,
                placeholder: entry.fromTheme ? nil : placeholders[entry.object.id],
                baseID: "alert-\(alert.id)-\(entry.id)",
                maskedBy: wiring.maskedBy[entry.object.id],
                matteGroup: wiring.mattes.contains(entry.object.id) ? entry.object.id : nil,
                animationSteps: steps[entry.object.id] ?? []
            )
        }
    }

    /// How tall the top bar is: the audience screen's fallback stays modest;
    /// the stage's is a fifth of the screen so it reads from the platform.
    public enum BannerSize: Sendable {
        case audience
        case stage
    }

    public static func bannerItems(
        for alert: CueAlert, canvasSize: CGSize,
        info: ConfidenceInfo? = nil, at date: Date = Date(),
        size: BannerSize = .audience
    ) -> [RenderItem] {
        let message = info.map {
            LinkedText.resolvedAlertMessage(alert.message, info: $0, at: date)
        } ?? alert.message
        // A red bar across the top, over whatever the layout shows. For its
        // first half second it's white, so it reads as a single flash.
        let band: CGRect
        let fontSize: Double
        switch size {
        case .audience:
            band = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height * (150.0 / 1080.0))
            fontSize = canvasSize.height * (72.0 / 1080.0)
        case .stage:
            band = StageMessagePlacement.bannerFrame(canvas: canvasSize)
            fontSize = canvasSize.height * (120.0 / 1080.0)
        }
        let flashing = date.timeIntervalSince(alert.firedAt) < 0.5
        let inset = canvasSize.width * (40.0 / 1920.0)
        return [
            RenderItem(
                id: "alert-band-\(alert.id)",
                frame: band,
                content: .shape(ShapeStyle(
                    kind: .rectangle,
                    fill: .solid(flashing ? .white : ConfidenceSceneBuilder.stageRed)
                ))
            ),
            RenderItem(
                id: "alert-text-\(alert.id)",
                frame: band.insetBy(dx: inset, dy: 0),
                content: .text(StyledText(
                    string: message,
                    fontSize: fontSize,
                    color: flashing ? ConfidenceSceneBuilder.stageRed : .white,
                    alignment: .center,
                    tabularFigures: false,
                    autoShrink: true,
                    minFontSize: canvasSize.height * (24.0 / 1080.0)
                ))
            ),
        ]
    }

    /// The Worship stage's message: a red band where the clock and song key
    /// were, white type, blinking white a few times as it appears so it is
    /// noticed, then holding steady so it can be read. The lyrics are not
    /// touched.
    public static func bandItems(
        for alert: CueAlert, in band: CGRect, canvasSize: CGSize,
        info: ConfidenceInfo, at date: Date
    ) -> [RenderItem] {
        // A flashing alert's off beat leaves the band empty, so it blinks
        // without the clock and key popping back in.
        guard info.alertVisible else { return [] }
        let message = LinkedText.resolvedAlertMessage(alert.message, info: info, at: date)
        let lit = StageMessageTiming.bandIsLit(firedAt: alert.firedAt, at: date)
        let inset = canvasSize.width * (30.0 / 1920.0)
        return [
            RenderItem(
                id: "stage-band-\(alert.id)",
                frame: band,
                content: .shape(ShapeStyle(
                    kind: .rectangle,
                    fill: .solid(lit ? .white : ConfidenceSceneBuilder.stageRed)
                ))
            ),
            RenderItem(
                id: "stage-band-text-\(alert.id)",
                frame: band.insetBy(dx: inset, dy: 0),
                content: .text(StyledText(
                    string: message,
                    fontSize: band.height * 0.72,
                    color: lit ? ConfidenceSceneBuilder.stageRed : .white,
                    alignment: .center,
                    autoShrink: true,
                    minFontSize: max(12, band.height * 0.28)
                ))
            ),
        ]
    }

    /// The Message stage's message: as large as it fits across the main
    /// part of the screen, white, inside a thin red edge that flashes white
    /// as it arrives.
    public static func takeoverItems(
        for alert: CueAlert, in area: CGRect, canvasSize: CGSize,
        info: ConfidenceInfo, at date: Date
    ) -> [RenderItem] {
        let message = LinkedText.resolvedAlertMessage(alert.message, info: info, at: date)
        let flashing = date.timeIntervalSince(alert.firedAt) < 0.5
        let unit = canvasSize.height / 1080
        let inset = canvasSize.width * 0.03
        return [
            RenderItem(
                id: "stage-takeover-edge-\(alert.id)",
                frame: area,
                content: .shape(ShapeStyle(
                    kind: .roundedRectangle(cornerRadius: 28 * unit),
                    fill: .solid(SceneColor(red: 0.16, green: 0.02, blue: 0.02)),
                    stroke: SceneStroke(
                        color: flashing ? .white : ConfidenceSceneBuilder.stageRed, width: 8 * unit)
                ))
            ),
            RenderItem(
                id: "stage-takeover-text-\(alert.id)",
                frame: area.insetBy(dx: inset, dy: inset / 2),
                content: .text(StyledText(
                    string: message,
                    fontSize: 220 * unit,
                    color: .white,
                    alignment: .center,
                    autoShrink: true,
                    minFontSize: 48 * unit,
                    balancedWrap: true
                ))
            ),
        ]
    }
}
