import Foundation

extension LyricFollower {
    /// Which input Live Assist has open, if any.
    public enum Input: Sendable { case worship, sermon }

    /// What turning Follow on does to the microphones.
    public enum MicStep: Equatable, Sendable {
        /// The worship input is open (or opening) already.
        case none
        case startWorship
        /// The sermon input is listening for scripture. Following never
        /// takes it over on its own: the operator chooses, and until then
        /// the Follow chip says the sermon mic is in use.
        case sermonMicInUse
    }

    /// `open` is the input listening or starting, nil when none is;
    /// `operatorChose` is a click on "use the worship mic".
    public static func micStep(open: Input?, operatorChose: Bool = false) -> MicStep {
        switch open {
        case .worship: .none
        case .sermon: operatorChose ? .startWorship : .sermonMicInUse
        case nil: .startWorship
        }
    }
}
