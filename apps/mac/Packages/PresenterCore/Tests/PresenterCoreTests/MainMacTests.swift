import Foundation
@testable import PresenterCore
import Testing

struct MainMacTests {
    @Test func rolesFollowTheLinkAndTheLibrarysChoice() {
        #expect(MainMac.role(linked: false, runsHere: true, mainMacId: "studio", thisMac: "laptop") == .onItsOwn)
        #expect(MainMac.role(linked: true, runsHere: false, mainMacId: "studio", thisMac: "studio") == .main)
        #expect(MainMac.role(linked: true, runsHere: true, mainMacId: "studio", thisMac: "laptop") == .editor)
        // A library from before roles: Run on this Mac still decides.
        #expect(MainMac.role(linked: true, runsHere: true, mainMacId: nil, thisMac: "studio") == .main)
        #expect(MainMac.role(linked: true, runsHere: false, mainMacId: "", thisMac: "laptop") == .editor)
    }

    @Test func aMacOnItsOwnIsLeftAlone() {
        #expect(MainMac.step(linked: false, runsHere: true, mainMacId: "studio", lastSeen: nil, thisMac: "laptop") == .none)
    }

    @Test func onLaunchTheLibrarysChoiceIsTaken() {
        // Two Macs both had Run on this Mac on; the library says the studio.
        #expect(MainMac.step(linked: true, runsHere: true, mainMacId: "studio", lastSeen: nil, thisMac: "laptop") == .setRunsHere(false))
        #expect(MainMac.step(linked: true, runsHere: false, mainMacId: "studio", lastSeen: nil, thisMac: "studio") == .setRunsHere(true))
        // None chosen yet: the Mac that runs the service claims it.
        #expect(MainMac.step(linked: true, runsHere: true, mainMacId: nil, lastSeen: nil, thisMac: "studio") == .claim)
        #expect(MainMac.step(linked: true, runsHere: false, mainMacId: nil, lastSeen: nil, thisMac: "laptop") == .none)
    }

    @Test func turningRunOnThisMacOnClaimsAndTheOldMainStepsDown() {
        // On the laptop: switched on while the studio is main.
        #expect(MainMac.step(linked: true, runsHere: true, mainMacId: "studio", lastSeen: .some("studio"), thisMac: "laptop") == .claim)
        // On the studio, once the laptop's claim arrives.
        #expect(MainMac.step(linked: true, runsHere: true, mainMacId: "laptop", lastSeen: .some("studio"), thisMac: "studio") == .setRunsHere(false))
        // On the laptop, once its own claim shows: nothing more to do.
        #expect(MainMac.step(linked: true, runsHere: true, mainMacId: "laptop", lastSeen: .some("studio"), thisMac: "laptop") == .none)
    }

    @Test func turningItOffOnTheMainMacReleases() {
        #expect(MainMac.step(linked: true, runsHere: false, mainMacId: "studio", lastSeen: .some("studio"), thisMac: "studio") == .release)
        // An editor that's off stays off.
        #expect(MainMac.step(linked: true, runsHere: false, mainMacId: "studio", lastSeen: .some("studio"), thisMac: "laptop") == .none)
    }
}
