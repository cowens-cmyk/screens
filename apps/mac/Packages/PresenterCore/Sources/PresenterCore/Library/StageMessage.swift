import CoreGraphics
import Foundation

/// How long a message to the stage stays up. After it, the stage goes back to
/// exactly what it showed before; Clear still takes it down at once.
public enum StageMessageDuration: Int, CaseIterable, Sendable, Identifiable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60
    case untilCleared = 0

    /// Long enough to read twice, short enough that nobody has to remember
    /// to clear it during a song.
    public static let standard = thirty

    public var id: Int { rawValue }

    /// Seconds on stage; nil when it stays until someone clears it.
    public var seconds: TimeInterval? { rawValue > 0 ? TimeInterval(rawValue) : nil }

    public var title: String {
        self == .untilCleared ? "Until cleared" : "\(rawValue) seconds"
    }

    /// The stored setting, or the standard length when there is none or it
    /// is a value this build doesn't offer.
    public init(stored: Int?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .standard
    }
}

/// When a stage message comes and goes. Pure, so the render thread and the
/// controls agree on it from the same two dates.
public enum StageMessageTiming {

    /// The Message stage's cross-fade between its usual look and the message.
    public static let fadeSeconds: TimeInterval = 0.3

    /// The Worship band blinks this many times as it appears, then holds.
    public static let bandFlashes = 3
    /// One blink: lit (white) for the first half, red for the second.
    public static let bandFlashPeriod: TimeInterval = 0.7

    /// When a message sent at `firedAt` leaves the stage; nil while it stays
    /// until cleared.
    public static func expiry(firedAt: Date, duration: StageMessageDuration) -> Date? {
        duration.seconds.map { firedAt.addingTimeInterval($0) }
    }

    public static func hasExpired(_ expiresAt: Date?, at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    /// How much of the message is in: 0 → 1 over the first fade, back to 0
    /// over the last fade before it expires, 0 once it has.
    public static func presence(firedAt: Date, expiresAt: Date?, at date: Date) -> Double {
        let fadeIn = date.timeIntervalSince(firedAt) / fadeSeconds
        var presence = min(1, max(0, fadeIn))
        if let expiresAt {
            let fadeOut = expiresAt.timeIntervalSince(date) / fadeSeconds
            presence = min(presence, max(0, fadeOut))
        }
        return presence
    }

    /// Whether the Worship band is in the lit (white) half of one of its
    /// opening blinks.
    public static func bandIsLit(firedAt: Date, at date: Date) -> Bool {
        let elapsed = date.timeIntervalSince(firedAt)
        guard elapsed >= 0, elapsed < Double(bandFlashes) * bandFlashPeriod else { return false }
        return elapsed.truncatingRemainder(dividingBy: bandFlashPeriod) < bandFlashPeriod / 2
    }

    /// Whole seconds until it clears, rounded up; nil while it stays until
    /// cleared.
    public static func secondsLeft(expiresAt: Date?, at date: Date) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(date).rounded(.up)))
    }
}

/// Where a stage message goes on a stage layout, decided from what the layout
/// shows so the stage modes and any layout picked for a screen behave alike.
public enum StageMessageStyle: Equatable, Sendable {
    /// The layout has its own Stage Message box: the designer placed it.
    case linkedObject
    /// No lyrics, only times (the Message layout): the message fills the
    /// screen and these objects, in reading order, move to a strip along the
    /// bottom so the sermon timer and the clock stay in view.
    case takeover(timeObjectIDs: [String])
    /// Lyrics on screen (the Worship layout): the message replaces the clock
    /// and song key along the bottom, in this band, and the lyrics are left
    /// alone.
    case band(CGRect, replacedObjectIDs: [String])
    /// Anything else: a bar across the top.
    case banner
}

public enum StageMessagePlacement {

    static let lyricSources: Set<TextSourceKind> = [.currentSlide, .nextSlide, .lastSlide]
    static let timeSources: Set<TextSourceKind> = [.timer, .clock, .videoCountdown]
    static let bandSources: Set<TextSourceKind> = [.clock, .songKey]
    /// The most times the strip holds; beyond it they'd be too small to read.
    static let maxStripSlots = 4

    public static func canvasSize(of layout: ConfidenceLayout) -> CGSize {
        CGSize(width: Double(layout.canvasWidth ?? 1920), height: Double(layout.canvasHeight ?? 1080))
    }

    public static func style(for layout: ConfidenceLayout) -> StageMessageStyle {
        if layout.hasStageMessageObject { return .linkedObject }
        let shown = layout.objects.filter { $0.hidden != true }
        func linked(_ sources: Set<TextSourceKind>) -> [SlideObject] {
            shown.filter { object in object.textLink.map { sources.contains($0.source) } ?? false }
        }
        let lyrics = linked(lyricSources)
        let canvas = canvasSize(of: layout)
        if lyrics.isEmpty {
            let times = linked(timeSources).sorted {
                (frame(of: $0).minY, frame(of: $0).minX) < (frame(of: $1).minY, frame(of: $1).minX)
            }
            guard !times.isEmpty else { return .banner }
            return .takeover(timeObjectIDs: times.prefix(maxStripSlots).map(\.id))
        }
        // The clock and key band only counts when it sits along the bottom,
        // as the Worship layout has it; up top it would sit over the lyrics'
        // reading line.
        let replaced = linked(bandSources)
        guard !replaced.isEmpty,
              replaced.allSatisfy({ frame(of: $0).minY >= canvas.height * 2 / 3 })
        else { return .banner }
        let union = replaced.map(frame(of:)).reduce(CGRect.null) { $0.union($1) }
        // Across the screen and down to its edge, unless that would cover
        // lyrics or a timer: then only where the clock and key were.
        let protected = linked(lyricSources.union([.timer, .videoCountdown])).map(frame(of:))
        let wide = CGRect(x: 0, y: union.minY, width: canvas.width, height: canvas.height - union.minY)
        let band = protected.contains { $0.intersects(wide) } ? union : wide
        return .band(band, replacedObjectIDs: replaced.map(\.id))
    }

    static func frame(of object: SlideObject) -> CGRect {
        CGRect(x: object.x ?? 0, y: object.y ?? 0, width: object.width ?? 0, height: object.height ?? 0)
    }

    /// The Message stage with a message up: the message across most of the
    /// screen, and a strip along the bottom split into `slots` equal places
    /// for the times. They never overlap.
    public static func takeoverFrames(
        canvas: CGSize, slots: Int
    ) -> (message: CGRect, strip: CGRect, slots: [CGRect]) {
        let margin = canvas.width * 0.03
        let strip = CGRect(
            x: margin, y: canvas.height * 0.77,
            width: canvas.width - margin * 2, height: canvas.height * 0.20)
        let message = CGRect(
            x: margin, y: canvas.height * 0.04,
            width: canvas.width - margin * 2, height: canvas.height * 0.69)
        let count = max(0, slots)
        guard count > 0 else { return (message, strip, []) }
        let gap = canvas.width * 0.02
        let width = (strip.width - gap * Double(count - 1)) / Double(count)
        let frames = (0..<count).map { index in
            CGRect(x: strip.minX + Double(index) * (width + gap), y: strip.minY, width: width, height: strip.height)
        }
        return (message, strip, frames)
    }

    /// The bar across the top for the audience-screen mirror, a playing
    /// video and layouts with nowhere better: a fifth of the screen.
    public static func bannerFrame(canvas: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * (220.0 / 1080.0))
    }
}

public extension ConfidenceLayout {

    /// Whether the layout has its own box for the stage message.
    var hasStageMessageObject: Bool {
        objects.contains { $0.textLink?.source == .stageMessage }
    }
}
