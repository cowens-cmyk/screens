import Foundation
import Observation
import PresenterCore
import SlideScene

/// Which screen is which in the room: the audience screens, the livestream
/// (keyed over the camera), the stage display and, where there are any,
/// the side TVs. The show view's monitors
/// follow these, and the livestream switch routes the stream screen.
@MainActor
@Observable
final class ShowSetup {
    static let shared = ShowSetup()

    /// What goes over the camera. Lower Third follows each presentation:
    /// its own choice, its slide's, its type's in Screens by Type, its
    /// theme's. Full Screen and Transparent take over the stream for the item
    /// that's live (picked here or by an action) and end when the next plan
    /// item goes live, so a song after a full-screen video gets its lower
    /// third again by itself.
    enum StreamMode: String, CaseIterable, Identifiable {
        /// Each presentation's own livestream look.
        case auto
        /// Whatever the room sees, edge to edge.
        case fullScreen
        /// Nothing over the camera.
        case off

        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Lower Third"
            case .fullScreen: "Full Screen"
            case .off: "Transparent"
            }
        }
    }

    /// What the stage display shows. A playing video takes it over (the Video
    /// layout: time left and the video) until it ends, whatever the mode,
    /// unless `stageShowsVideos` is off.
    enum StageMode: String, CaseIterable, Identifiable {
        case worship, message, preService, announcements, mirror
        var id: String { rawValue }
        var title: String {
            switch self {
            case .worship: "Worship"
            case .message: "Message"
            case .preService: "Before Service"
            case .announcements: "Announcements"
            case .mirror: "Audience Screen"
            }
        }
    }

    /// The pre-service slideshow and the announcements keep their stage
    /// layout through their own videos (a welcome loop, the logo): the
    /// stage doesn't switch to the Video layout for them. Set as their
    /// slides go up (ServiceControls); a plan's countdown, or any other
    /// video put up outside the announcements, clears it. Not saved.
    var stageHoldsThroughVideos = false

    var stageMode: StageMode {
        didSet {
            UserDefaults.standard.set(stageMode.rawValue, forKey: "show.stageMode")
            // Recorded here rather than in showsAudienceOnStage, so Audience
            // Screen picked anywhere (Settings › Stage, an action) still
            // knows the mode to go back to.
            if stageMode == .mirror, oldValue != .mirror {
                modeBeforeAudience = oldValue
                UserDefaults.standard.set(oldValue.rawValue, forKey: "show.stageModeBeforeAudience")
            }
            onStageChange?()
        }
    }
    var onStageChange: (() -> Void)?

    /// The mode to go back to when Show Audience Screen is turned off.
    @ObservationIgnored private var modeBeforeAudience: StageMode = .worship

    /// Whatever the audience screen shows, on the stage display too: one
    /// click on, one click back to the mode it was in.
    var showsAudienceOnStage: Bool {
        get { stageMode == .mirror }
        set {
            if newValue, stageMode != .mirror {
                stageMode = .mirror
            } else if !newValue, stageMode == .mirror {
                stageMode = modeBeforeAudience
            }
        }
    }

    /// The live presentation's own stage layout, which wins over the mode's.
    var stageLayoutOverride: String? { didSet { onStageChange?() } }
    /// The live presentation's own livestream theme, which wins over its
    /// slides' themes for the lower third.
    var streamThemeOverride: String? { didSet { changed() } }
    /// The stage follows what's live: Worship for songs, Message for the
    /// message. Turned off, the stage only changes when someone changes it.
    var stageFollowsItems: Bool {
        didSet { UserDefaults.standard.set(stageFollowsItems, forKey: "show.stageFollowsItems") }
    }

    /// While a video plays the stage switches to the Video layout (the time
    /// left above the video), then back. Off, the stage keeps its layout.
    /// Not a mode change, so the screens keep their picked layouts; the stage
    /// controller watches it.
    var stageShowsVideos: Bool {
        didSet { UserDefaults.standard.set(stageShowsVideos, forKey: "show.stageShowsVideos") }
    }

    /// How long a message sent to the stage stays up before the stage goes
    /// back to what it showed. Messages that also reach the audience screen
    /// are not timed.
    var stageMessageDuration: StageMessageDuration {
        didSet { UserDefaults.standard.set(stageMessageDuration.rawValue, forKey: "show.stageMessageSeconds") }
    }

    var audienceTarget: String { didSet { save(audienceTarget, "show.audienceTarget") } }
    var streamTarget: String { didSet { save(streamTarget, "show.streamTarget"); changed() } }
    var stageTarget: String { didSet { save(stageTarget, "show.stageTarget") } }
    var sideTVsTarget: String { didSet { save(sideTVsTarget, "show.sideTVsTarget"); sideTVsChanged() } }

    /// A fourth screen for TVs beside the main screen: the room's slides with
    /// a song's lyrics drawn larger. Off until a Mac is set up for it, so a
    /// Mac without side TVs draws nothing extra.
    var sideTVsOn: Bool {
        didSet {
            UserDefaults.standard.set(sideTVsOn, forKey: "show.sideTVs.on")
            sideTVsChanged()
        }
    }

    /// How many times the room's size the side TVs draw a song's lyrics.
    var sideTVsLyricScale: Double {
        didSet {
            let clamped = Self.clampedLyricScale(sideTVsLyricScale)
            if clamped != sideTVsLyricScale { sideTVsLyricScale = clamped; return }
            UserDefaults.standard.set(sideTVsLyricScale, forKey: "show.sideTVs.lyricScale")
            sideTVsChanged()
        }
    }

    static func clampedLyricScale(_ value: Double) -> Double {
        let range = SideScreenLyrics.scaleRange
        guard value.isFinite else { return SideScreenLyrics.defaultScale }
        return (min(max(value, range.lowerBound), range.upperBound) * 10).rounded() / 10
    }

    /// Called when the side TVs are turned on or off, moved or resized, so
    /// their scene and its routing are made again.
    var onSideTVsChange: (() -> Void)?
    var streamMode: StreamMode {
        didSet {
            if !returningToAuto { onStreamModeChosen?() }
            changed()
        }
    }

    @ObservationIgnored private var returningToAuto = false

    /// A new plan item went live: a Full Screen or Transparent picked for
    /// the one before ends, and the stream follows the presentations again.
    /// A video's hold on the stream is left alone; the slide going live
    /// decides that.
    func followPresentations() {
        guard streamMode != .auto else { return }
        returningToAuto = true
        defer { returningToAuto = false }
        streamMode = .auto
    }

    /// Called when the stream routing needs recomputing.
    var onChange: (() -> Void)?
    /// Called when someone (or an action) picks a livestream mode, which
    /// ends a playing video's hold on the stream.
    var onStreamModeChosen: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        audienceTarget = defaults.string(forKey: "show.audienceTarget") ?? ""
        streamTarget = defaults.string(forKey: "show.streamTarget") ?? ""
        stageTarget = defaults.string(forKey: "show.stageTarget") ?? ""
        sideTVsTarget = defaults.string(forKey: "show.sideTVsTarget") ?? ""
        sideTVsOn = defaults.bool(forKey: "show.sideTVs.on")
        sideTVsLyricScale = Self.clampedLyricScale(
            defaults.object(forKey: "show.sideTVs.lyricScale") as? Double ?? SideScreenLyrics.defaultScale)
        // Full Screen or Transparent was once kept from one run to the next
        // and then held every presentation after it; each run now starts
        // following the presentations.
        streamMode = .auto
        defaults.removeObject(forKey: "show.streamMode")
        stageMode = defaults.string(forKey: "show.stageMode").flatMap(StageMode.init(rawValue:)) ?? .worship
        modeBeforeAudience = defaults.string(forKey: "show.stageModeBeforeAudience")
            .flatMap(StageMode.init(rawValue:)).flatMap { $0 == .mirror ? nil : $0 } ?? .worship
        stageFollowsItems = defaults.object(forKey: "show.stageFollowsItems") as? Bool ?? true
        stageShowsVideos = defaults.object(forKey: "show.stageShowsVideos") as? Bool ?? true
        stageMessageDuration = StageMessageDuration(
            stored: defaults.object(forKey: "show.stageMessageSeconds") as? Int)
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func changed() { onChange?() }

    /// The side TVs' scene comes from the live slide and their routing from
    /// the stream router's table, so both are told.
    private func sideTVsChanged() {
        onSideTVsChange?()
        onChange?()
    }
}
