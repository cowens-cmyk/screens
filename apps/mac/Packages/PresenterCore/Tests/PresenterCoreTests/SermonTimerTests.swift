import Foundation
import Testing

@testable import PresenterCore

private func message(seconds: Double?) -> Presentation {
    var deck = Presentation(id: "m", name: "Message", presentationKind: .deck, themeId: "", slides: [])
    deck.sermonTimerSeconds = seconds
    return deck
}

private func video(loops: Bool = false, endAction: MediaEndAction? = nil, autoAdvance: AutoAdvance? = nil) -> MediaItem {
    MediaItem(
        id: "v", name: "Announcements", mediaKind: .video, classification: .background,
        fileHash: "h", fileName: "a.mov", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: loops,
        autoAdvance: autoAdvance, endAction: endAction)
}

@Test func theSermonRunsFortyMinutesUnlessTheMessageSaysOtherwise() {
    #expect(SermonTimer.defaultSeconds == 40 * 60)
    #expect(SermonTimer.seconds(for: nil) == 2400)
    #expect(SermonTimer.seconds(for: message(seconds: nil)) == 2400)
    #expect(SermonTimer.seconds(for: message(seconds: 0)) == 2400, "a zero length is no length")
    #expect(SermonTimer.seconds(for: message(seconds: 1800)) == 1800)
    #expect(SermonTimer.minutes(for: message(seconds: 45 * 60)) == 45)
}

@Test func typedMinutesStayInReason() {
    #expect(SermonTimer.seconds(minutes: 42) == 42 * 60)
    #expect(SermonTimer.seconds(minutes: 0) == 60)
    #expect(SermonTimer.seconds(minutes: 1000) == 300 * 60)
}

@Test func aNudgeMovesOnlyTheLength() {
    #expect(SermonTimer.adjusted(duration: 2400, byMinutes: 1) == 2460)
    #expect(SermonTimer.adjusted(duration: 2400, byMinutes: -1) == 2340)
    #expect(SermonTimer.adjusted(duration: 30, byMinutes: -1) == 0)
}

@Test func theSermonTimerIsFoundByItsIdThenItsName() {
    struct Countdown { var id: String; var name: String }
    let legacy = [Countdown(id: "a", name: "Walk-in"), Countdown(id: "b", name: "sermon")]
    #expect(SermonTimer.find(in: legacy, id: \.id, name: \.name)?.id == "b")
    let both = legacy + [Countdown(id: SermonTimer.id, name: "Message")]
    #expect(SermonTimer.find(in: both, id: \.id, name: \.name)?.id == SermonTimer.id)
    #expect(SermonTimer.find(in: [Countdown(id: "a", name: "Walk-in")], id: \.id, name: \.name) == nil)
}

@Test func aVideoGoesToTheNextItemByDefault() {
    #expect(video().resolvedEndAction == .next)
    #expect(video().planAdvance == AutoAdvance(delaySeconds: 0, afterPlayback: true))
    for action in MediaEndAction.allCases {
        #expect(video(endAction: action).resolvedEndAction == action)
    }
    #expect(video(endAction: .hold).planAdvance == nil, "holding never advances")
    #expect(video(loops: true).resolvedEndAction == nil, "a looping video never ends")
    let ownAdvance = AutoAdvance(delaySeconds: 5)
    #expect(video(autoAdvance: ownAdvance).resolvedEndAction == nil)
    #expect(video(autoAdvance: ownAdvance).planAdvance == ownAdvance, "its own auto-advance stands")
    var still = video()
    still.mediaKind = .image
    #expect(still.resolvedEndAction == nil)
}

@Test func theCountdownAlwaysMovesThePlanOn() {
    let next = AutoAdvance(delaySeconds: 0, afterPlayback: true)
    #expect(video(loops: true).planAdvance(asCountdown: true) == next, "played once whatever the video says")
    #expect(video(endAction: .hold).planAdvance(asCountdown: true) == next)
    #expect(video(endAction: .stop).planAdvance(asCountdown: true) == next)
    let ownAdvance = AutoAdvance(delaySeconds: 5)
    #expect(video(autoAdvance: ownAdvance).planAdvance(asCountdown: true) == ownAdvance)
    #expect(video(loops: true).planAdvance(asCountdown: false) == nil, "an ordinary looping video never moves on")
    var still = video()
    still.mediaKind = .image
    #expect(still.planAdvance(asCountdown: true) == nil)
}

@Test func aTimerLeftFromTheServiceBeforeStartsAgain() {
    func restarts(elapsedMinutes: Double, duration: Double = 2400) -> Bool {
        let elapsed = elapsedMinutes * 60
        return SermonTimer.restartsWhenMessageGoesLive(elapsed: elapsed, remaining: duration - elapsed, duration: duration)
    }
    #expect(!restarts(elapsedMinutes: 10), "back to the message in the same service")
    #expect(!restarts(elapsedMinutes: 44))
    #expect(restarts(elapsedMinutes: 46), "over 45 minutes, and more than five past zero")
    #expect(restarts(elapsedMinutes: 90), "the first service's timer at the second service")
    #expect(!restarts(elapsedMinutes: 50, duration: 3600), "a longer message keeps going within its length")
    #expect(restarts(elapsedMinutes: 66, duration: 3600))
    // A nudged-short timer more than five minutes past zero starts again.
    #expect(SermonTimer.restartsWhenMessageGoesLive(elapsed: 30 * 60, remaining: -6 * 60, duration: 24 * 60))
    #expect(!SermonTimer.restartsWhenMessageGoesLive(elapsed: 30 * 60, remaining: -4 * 60, duration: 26 * 60))
}
