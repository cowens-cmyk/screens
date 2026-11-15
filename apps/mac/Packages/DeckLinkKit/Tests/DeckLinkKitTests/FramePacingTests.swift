import DeckLinkKit
import Testing

/// The card asks for a frame every period; the app's frames come on its own
/// timer and over XPC, a little early or late. Each of the app's frames
/// should go out once, in order.
@Test func framesOnTimeGoOutOnceEach() {
    let (shown, counts) = DeckLinkPaceCounts.simulate(String(repeating: "qc", count: 6))
    #expect(shown == [1, 2, 3, 4, 5, 6])
    #expect(counts.fresh == 6 && counts.stutters == 0 && counts.dropped == 0)
}

@Test func aFrameThatComesLateAfterTheCardAskedIsStillShownNotSkipped() {
    // Frame 3 lands just after the card's third request, then frame 4 just
    // before the fourth: the old "newest wins" copy showed 2, 2, 4 and lost
    // 3. Now the card shows 2 once more and every frame after in turn,
    // one frame later than before.
    let (shown, counts) = DeckLinkPaceCounts.simulate("qc" + "qc" + "c" + "q" + "qc" + "qc" + "qc" + "c")
    #expect(shown == [1, 2, 2, 3, 4, 5, 6])
    #expect(counts.stutters == 1, "the one late frame")
    #expect(counts.dropped == 0)
}

@Test func jitterBothWaysIsAbsorbedOnceAFrameIsWaiting() {
    // A frame late, then two close together, over and over: each still
    // goes out once and in order.
    let pattern = String(repeating: "qcqqcc", count: 5)
    let (shown, counts) = DeckLinkPaceCounts.simulate(pattern)
    #expect(shown == Array(1...shown.count))
    #expect(counts.stutters == 0 && counts.dropped == 0)
}

@Test func anAppRunningAheadOfTheCardLosesTheOldestFrame() {
    // A 60 fps screen on a 59.94 port: the frames waiting are capped, so the
    // picture is never more than two frames behind.
    let (shown, counts) = DeckLinkPaceCounts.simulate("qqqqc" + "c" + "c")
    #expect(shown == [3, 4, 4])
    #expect(counts.dropped == 2)
    #expect(counts.stutters == 0, "a held picture once the frames stop is a still, not a stutter")
}

@Test func aStillPictureHeldIsNotAStutter() {
    let (shown, counts) = DeckLinkPaceCounts.simulate("qc" + String(repeating: "c", count: 30) + "qc")
    #expect(shown.first == 1 && shown.last == 2)
    #expect(counts.stutters == 0)
}

@Test func beforeAnyFrameTheCardShowsBlack() {
    let (shown, _) = DeckLinkPaceCounts.simulate("cc")
    #expect(shown == [0, 0])
}
