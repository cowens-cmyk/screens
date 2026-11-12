import Foundation

/// Which Mac runs the service. Macs linked to the church library share it
/// through the hub; one of them is the **Main Mac** (the Mac Studio): it
/// plays the scheduled countdowns, restarts the pre-service slides, follows
/// the phone remote and does the library's housekeeping. The others are
/// **Editors**: they edit the same plans and slides but never run the
/// service. A Mac that isn't linked runs **On its own** with its own
/// library and is its own main Mac, as before.
///
/// The church library holds the Main Mac's id (`mainMacId` in the
/// church-wide settings), so there is only ever one: making a Mac main
/// steps the old one down on its next sync. On each Mac the choice is kept
/// in "Run on this Mac" (ServiceStation.runsService), which everything that
/// runs the service already reads; this works out what it should be.
public enum MainMac {

    public enum Role: String, Equatable, Sendable {
        case main
        case editor
        case onItsOwn

        public var title: String {
            switch self {
            case .main: "Main Mac"
            case .editor: "Editor"
            case .onItsOwn: "On its own"
            }
        }
    }

    /// This Mac's role. Linked with no Main Mac chosen yet (a library from
    /// before roles), "Run on this Mac" still decides, as it did.
    public static func role(linked: Bool, runsHere: Bool, mainMacId: String?, thisMac: String) -> Role {
        guard linked else { return .onItsOwn }
        guard let mainMacId, !mainMacId.isEmpty else { return runsHere ? .main : .editor }
        return mainMacId == thisMac ? .main : .editor
    }

    /// What to do so this Mac and the church library agree.
    public enum Step: Equatable, Sendable {
        case none
        /// Turn "Run on this Mac" on or off here: the library's choice
        /// changed (another Mac was made main, or this one was).
        case setRunsHere(Bool)
        /// Write this Mac as the Main Mac: "Run on this Mac" was turned on
        /// here.
        case claim
        /// Clear the Main Mac: it was this one and "Run on this Mac" was
        /// turned off here.
        case release
    }

    /// The step for this pass.
    ///
    /// - Parameters:
    ///   - linked: this Mac shares the church library.
    ///   - runsHere: "Run on this Mac" here now.
    ///   - mainMacId: the library's Main Mac now (nil: none chosen).
    ///   - lastSeen: the library's Main Mac on the last pass; `.none` on the
    ///     first pass after launch (nothing seen yet).
    ///   - thisMac: this Mac's id.
    ///
    /// A change in the library wins over this Mac's switch, so when two Macs
    /// claim at once both settle on whichever claim the library kept. On the
    /// first pass the library's choice is taken as it stands; with none
    /// chosen, a Mac that runs the service claims it.
    public static func step(
        linked: Bool, runsHere: Bool, mainMacId: String?, lastSeen: String??, thisMac: String
    ) -> Step {
        guard linked else { return .none }
        let main = mainMacId.flatMap { $0.isEmpty ? nil : $0 }
        let firstPass = lastSeen == nil
        let changed = firstPass || lastSeen! != main
        if changed, let main {
            let shouldRun = main == thisMac
            return shouldRun == runsHere ? .none : .setRunsHere(shouldRun)
        }
        if runsHere, main != thisMac { return .claim }
        if !runsHere, main == thisMac { return .release }
        return .none
    }
}
