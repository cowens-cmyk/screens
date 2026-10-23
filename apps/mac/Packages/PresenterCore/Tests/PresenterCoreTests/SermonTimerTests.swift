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
