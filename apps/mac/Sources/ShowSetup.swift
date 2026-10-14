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

    /// What the stage display shows. A playing video takes it over (preview
    /// and time left) until the video ends, whatever the mode.
    enum StageMode: String, CaseIterable, Identifiable {
        case worship, message, mirror
        var id: String { rawValue }
        var title: String {
            switch self {
            case .worship: "Worship"
            case .message: "Message"
            case .mirror: "Mirror"
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

    var audienceTarget: String { didSet { save(audienceTarget, "show.audienceTarget") } }
    var streamTarget: String { didSet { save(streamTarget, "show.streamTarget"); changed() } }
    var stageTarget: String { didSet { save(stageTarget, "show.stageTarget") } }
    var streamMode: StreamMode {
        didSet {
            UserDefaults.standard.set(streamMode.rawValue, forKey: "show.streamMode")
            changed()
        }
    }

    /// Called when the stream routing needs recomputing.
    var onChange: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        audienceTarget = defaults.string(forKey: "show.audienceTarget") ?? ""
        streamTarget = defaults.string(forKey: "show.streamTarget") ?? ""
        stageTarget = defaults.string(forKey: "show.stageTarget") ?? ""
        streamMode = defaults.string(forKey: "show.streamMode").flatMap(StreamMode.init(rawValue:)) ?? .auto
        stageMode = defaults.string(forKey: "show.stageMode").flatMap(StageMode.init(rawValue:)) ?? .worship
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func changed() { onChange?() }
}
