import Foundation
import Observation
import PresenterCore

/// Which screen is which in the room: the audience screens, the livestream
/// (keyed over the camera) and the stage display. The show view's monitors
/// follow these, and the livestream switch routes the stream screen.
@MainActor
@Observable
final class ShowSetup {
    static let shared = ShowSetup()

    enum StreamMode: String, CaseIterable, Identifiable {
        /// Slides whose theme has a livestream lower third show in it;
        /// everything else leaves the camera clear.
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
        case worship, message, mirror
        var id: String { rawValue }
        var title: String {
            switch self {
            case .worship: "Worship"
            case .message: "Message"
            case .mirror: "Audience Screen"
            }
        }
    }

    var stageMode: StageMode {
        didSet {
            UserDefaults.standard.set(stageMode.rawValue, forKey: "show.stageMode")
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
                modeBeforeAudience = stageMode
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
    var streamMode: StreamMode {
        didSet {
            UserDefaults.standard.set(streamMode.rawValue, forKey: "show.streamMode")
            onStreamModeChosen?()
            changed()
        }
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
        streamMode = defaults.string(forKey: "show.streamMode").flatMap(StreamMode.init(rawValue:)) ?? .auto
        stageMode = defaults.string(forKey: "show.stageMode").flatMap(StageMode.init(rawValue:)) ?? .worship
        stageFollowsItems = defaults.object(forKey: "show.stageFollowsItems") as? Bool ?? true
        stageShowsVideos = defaults.object(forKey: "show.stageShowsVideos") as? Bool ?? true
        stageMessageDuration = StageMessageDuration(
            stored: defaults.object(forKey: "show.stageMessageSeconds") as? Int)
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func changed() { onChange?() }
}
