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
    // The plan list (a pass builds every row) and the media bin (a pass
    // sorts and filters the whole library).
    case runOrderList
    // The window's root: a pass here re-runs the top bar, both panels and
    // every button in the window. A pick or a fire shouldn't cause one.
    case planShell
    case mediaBin

    var name: String {
        switch self {
        case .shell: "ShellView"
        case .librarySidebar: "LibrarySidebar"
        case .slideEditor: "SlideEditorView"
        case .slideObjectInspector: "SlideObjectInspector"
        case .animationTimelinePanel: "AnimationTimelinePanel"
        case .serviceContinuous: "ServiceContinuousPage"
        case .slideGridBody: "SlideGridBody"
        case .slideTile: "SlideTile"
        case .slideThumbnail: "SlideThumbnailView"
        case .runOrderList: "RunOrderList"
        case .planShell: "PlanShell"
        case .mediaBin: "MediaLibraryView"
        }
    }

    var limit: Int {
        switch self {
        case .shell, .librarySidebar, .slideObjectInspector, .animationTimelinePanel, .serviceContinuous: 20
        case .slideEditor: 20
        // A storm line only when far past one pass over a whole plan a second.
        case .slideGridBody: 120
        case .slideTile, .slideThumbnail: 1500
        case .runOrderList, .mediaBin, .planShell: 20
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
