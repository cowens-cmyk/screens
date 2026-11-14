import PresenterCore
import QuartzCore

enum MeteredView: Int, CaseIterable {
    case shell
    case librarySidebar
    case slideEditor
    case slideObjectInspector
    case animationTimelinePanel
    case serviceContinuous
    // The plan page's grids and tiles: how many bodies a pass re-runs is
    // what a click or a scroll costs there. Tiles in the hundreds a second
    // say the page re-evaluates far more than the one or two that changed.
    case slideGridBody
    case slideTile
    case slideThumbnail

    var name: String {
        switch self {
        case .shell: "ShellView"
        case .librarySidebar: "LibrarySidebar"
        case .slideEditor: "SlideEditorView"
        case .slideObjectInspector: "SlideObjectInspector"
        case .animationTimelinePanel: "AnimationTimelinePanel"
        case .serviceContinuous: "ServiceContinuousView"
        case .slideGridBody: "SlideGridBody"
        case .slideTile: "SlideTile"
        case .slideThumbnail: "SlideThumbnailView"
        }
    }

    var limit: Int {
        switch self {
        case .shell, .librarySidebar, .slideObjectInspector, .animationTimelinePanel, .serviceContinuous: 20
        case .slideEditor: 20
        // A storm line only when far past one pass over a whole plan a second.
        case .slideGridBody: 120
        case .slideTile, .slideThumbnail: 1500
        }
    }
}

enum BodyMeter {

    static func tick(_ view: MeteredView) {
        let now = CACurrentMediaTime()
        if let storm = DiagnosticsStore.shared.bodyMeter.withLock({ $0.tick(view.rawValue, now: now) }) {
            let name = MeteredView(rawValue: storm.view)?.name ?? "?"
            DiagnosticsStore.shared.note(
                "perf.bodyStorm",
                detail: PerfLineLimiter.annotate(
                    "view=\(name) \(storm.perSecond)/s for \(storm.seconds) s", dropped: storm.dropped))
        }
    }
}
