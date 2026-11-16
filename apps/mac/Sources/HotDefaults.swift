import Foundation
import Observation
import PresenterCore

/// The settings the Present page reads, kept in step with UserDefaults.
/// `@AppStorage` re-runs its view on every write to UserDefaults, whatever
/// the key: moving the slides on to the next item writes the stage mode,
/// and the timers and scheduler write theirs, so the page, every slide grid
/// on it and the plan list were rebuilt each time (SwiftUI's change report
/// named the page's four grid settings, unchanged). This notifies only when
/// one of its own values changes.
@MainActor @Observable final class HotDefaults {
    static let shared = HotDefaults()

    private(set) var roundedCorners = true
    private(set) var hideScopedBackgrounds = false
    private(set) var legibleText = false
    private(set) var slidesAcross = SlidesAcross.fallback

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        read()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { HotDefaults.shared.read() }
            } else {
                Task { @MainActor in HotDefaults.shared.read() }
            }
        }
    }

    private func read() {
        let defaults = UserDefaults.standard
        let rounded = defaults.object(forKey: "slideGrid.roundedCorners") as? Bool ?? true
        if rounded != roundedCorners { roundedCorners = rounded }
        let hide = defaults.object(forKey: "slideGrid.hideScopedBackgrounds") as? Bool ?? false
        if hide != hideScopedBackgrounds { hideScopedBackgrounds = hide }
        let legible = defaults.object(forKey: "slideGrid.legibleText") as? Bool ?? false
        if legible != legibleText { legibleText = legible }
        let across = defaults.object(forKey: SlidesAcross.key) as? Int ?? SlidesAcross.fallback
        if across != slidesAcross { slidesAcross = across }
    }

    /// Writes the app mode for a view that only ever sets it: holding it as
    /// `@AppStorage` re-ran that view on every UserDefaults write.
    static func setAppMode(_ mode: AppMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
    }

    static var appModeRaw: String? { UserDefaults.standard.string(forKey: "appMode") }
}
