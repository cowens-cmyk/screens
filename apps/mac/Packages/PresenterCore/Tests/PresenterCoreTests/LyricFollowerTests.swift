import Foundation
import Testing
@testable import PresenterCore

/// Lyric follow, fed synthetic transcripts. The song is written for these
/// tests (never real lyrics), with the shapes real songs have: a title
/// slide, two-slide sections, a chorus repeated in the arrangement, a bridge
/// that repeats its own line, and a blank to end on.
private enum Song {
    static let title = "Harbor Light"
    static let verse1a = "Morning light breaks over quiet hills\nEvery shadow running from the dawn"
    static let verse1b = "Lanterns fade as rivers find their way\nCalling out the name we lean upon"
    static let chorus1 = "Steady You are steady\nAnchor when the waters rise"
    static let chorus2 = "Faithful You are faithful\nHolding every star across the skies"
    static let verse2a = "Winter fields remember spring is near\nSeeds beneath the frost already know"
    static let verse2b = "Every promise kept from age to age\nEvery ember waiting still to glow"
    static let bridge1 = "We will sing it louder\nWe will sing it louder"
    static let bridge2 = "Nothing in the dark can drown it out\nNothing in the dark can drown it out"

    /// 0 title, 1–2 verse 1, 3–4 chorus, 5–6 verse 2, 7–8 chorus, 9–10
    /// bridge, 11–12 chorus, 13 blank.
    static let arranged = [
        title, verse1a, verse1b, chorus1, chorus2, verse2a, verse2b, chorus1, chorus2,
        bridge1, bridge2, chorus1, chorus2, "",
    ]
    /// The same song with no chorus after the bridge: 0–1 verse, 2–3 chorus,
    /// 4–5 bridge, 6 blank.
    static let short = [verse1a, verse1b, chorus1, chorus2, bridge1, bridge2, ""]
}

/// Plays the part of LiveAssist and the recogniser: each line arrives as
/// growing partial results, then a final one, and every decision at or over
/// the threshold puts that slide live.
private struct Singing {
    struct Advance {
        var from: Int
        var to: Int
        var reason: LyricFollower.Decision.Reason
        /// The line being sung when it happened, and how many of its words were heard.
        var line: String
        var wordsHeard: Int
    }

    var follower: LyricFollower
    var threshold = 0.7
    var trail: [Int]
    var advances: [Advance] = []
    /// Every decision seen, fired or not.
    var decisions: [LyricFollower.Decision] = []

    init(_ slides: [String] = Song.arranged, live: Int) {
        follower = LyricFollower(slideTexts: slides, live: live)
        trail = [live]
    }

    var live: Int { follower.live }

    /// Words of an utterance the recogniser hasn't settled yet.
    var open: [Substring] = []

    /// Sings each line as its own utterance; with `finals` off, the text
    /// carries on one long utterance the recogniser never settles.
    mutating func sing(_ text: String, finals: Bool = true) {
        let lines = finals ? text.split(separator: "\n").map(String.init) : [text.replacingOccurrences(of: "\n", with: " ")]
        for line in lines {
            let words = line.split(separator: " ")
            for word in words {
                open.append(word)
                follower.hear(open.joined(separator: " "), isFinal: false)
                check(line, open.count)
            }
            if finals { settle() }
        }
    }

    mutating func settle() {
        guard !open.isEmpty else { return }
        follower.hear(open.joined(separator: " "), isFinal: true)
        check(open.joined(separator: " "), open.count)
        open = []
    }

    private mutating func check(_ line: String, _ words: Int) {
        guard let decision = follower.decision else { return }
        decisions.append(decision)
        guard decision.confidence >= threshold else { return }
        advances.append(Advance(from: live, to: decision.slideIndex, reason: decision.reason, line: line, wordsHeard: words))
        follower.liveChanged(to: decision.slideIndex)
        trail.append(decision.slideIndex)
    }
}

@Suite struct LyricFollowerTests {

    @Test func followsTheWholeArrangementAsItIsSung() {
        var singing = Singing(live: 0)
        for slide in Song.arranged.dropFirst() where !slide.isEmpty { singing.sing(slide) }
        #expect(singing.trail == Array(0...12), "every slide in order, each once")
        // The blank at the end is the operator's call: suggested, never taken.
        #expect(singing.live == 12)
        #expect(singing.follower.suggestion?.slideIndex == 13)
        #expect((singing.follower.suggestion?.confidence ?? 1) < 0.5)
    }

    @Test func theNextSlideGoesUpOnTheLastWordOfTheSlide() {
        var singing = Singing(live: 0)
        for slide in Song.arranged.dropFirst() where !slide.isEmpty { singing.sing(slide) }
        // The title is never sung: the verse's first words move past it.
        let first = try! #require(singing.advances.first)
        #expect(first.to == 1 && first.reason == .nextSlideStarted && first.wordsHeard <= 3)
        for advance in singing.advances.dropFirst() {
            let lastLine = String(Song.arranged[advance.from].split(separator: "\n").last!)
            let length = lastLine.split(separator: " ").count
            #expect(advance.reason == .currentSlideFinished, "slide \(advance.from) → \(advance.to)")
            #expect(advance.line == lastLine && advance.wordsHeard >= length - 1,
                    "not before the last line's last words (slide \(advance.from), \(advance.wordsHeard)/\(length))")
        }
    }

    @Test func oneLongUtteranceFollowsTheSameWay() {
        var singing = Singing(live: 1)
        for slide in Song.arranged[1...8] { singing.sing(slide, finals: false) }
        #expect(singing.trail == Array(1...9), "and on into the bridge as chorus 8 ends")
    }

    @Test func partialResultsAreNotCountedTwice() {
        var partials = LyricFollower(slideTexts: Song.arranged, live: 1)
        for count in 1...7 {
            let words = "morning light breaks over quiet hills every".split(separator: " ").prefix(count)
            partials.hear(words.joined(separator: " "), isFinal: false)
        }
        partials.hear("morning light breaks over quiet hills every", isFinal: true)
        var once = LyricFollower(slideTexts: Song.arranged, live: 1)
        once.hear("morning light breaks over quiet hills every", isFinal: true)
        #expect(partials.position == once.position)
        #expect(partials.position == LyricFollower.Position(slideIndex: 1, word: 7, wordCount: 12))
        #expect(partials.decision == once.decision)
    }

    @Test func aNewUtteranceWithoutAFinalStillCounts() {
        var follower = LyricFollower(slideTexts: Song.arranged, live: 3)
        follower.hear("steady you are steady", isFinal: false)
        follower.hear("anchor when the waters", isFinal: false)
        #expect(follower.position == LyricFollower.Position(slideIndex: 3, word: 8, wordCount: 9))
    }

    @Test func aRevisedPartialReplacesTheOneBefore() {
        var follower = LyricFollower(slideTexts: Song.arranged, live: 3)
        follower.hear("steady you are ready", isFinal: false)
        follower.hear("steady you are steady anchor", isFinal: false)
        #expect(follower.position == LyricFollower.Position(slideIndex: 3, word: 5, wordCount: 9))
    }

    @Test func theNextSlideStartingAdvancesWhenTheEndWasMissed() {
        var singing = Singing(live: 1)
        singing.sing("Morning light breaks over quiet hills")
        #expect(singing.trail == [1])
        // The second line never came through; the next slide's opening does.
        singing.sing("Lanterns fade as rivers")
        #expect(singing.trail == [1, 2])
        #expect(singing.advances.first?.reason == .nextSlideStarted)
        #expect((singing.advances.first?.wordsHeard ?? 99) <= 3)
    }

    @Test func misheardWordsStillFollow() {
        var singing = Singing(live: 2)
        // Dropped, swapped and sound-alike words, as a recogniser hears singing.
        singing.sing("lantern fades is rivers fine there way\ncalling out a name we leaning upon")
        singing.sing("steady you are steady\nanker when the water rise")
        #expect(singing.trail == [2, 3, 4])
    }

    @Test func adLibsDontMoveThePlace() {
        var singing = Singing(live: 3)
        singing.sing("Steady You are steady")
        singing.sing("oh oh yeah yeah oh")
        singing.sing("yeah")
        #expect(singing.trail == [3])
        #expect(singing.follower.position?.slideIndex == 3)
        #expect(singing.follower.position?.word == 4)
        singing.sing("Anchor when the waters rise")
        #expect(singing.trail == [3, 4])
    }

    @Test func talkingBetweenSongsMovesNothing() {
        var singing = Singing(live: 4)
        singing.sing("good morning church it is so good to be with you this morning")
        singing.sing("let us stand and sing together you are welcome here")
        #expect(singing.trail == [4])
        #expect(singing.decisions.allSatisfy { $0.confidence < 0.7 })
    }

    @Test func theRepeatedChorusIsTheOneAfterThisVerse() {
        var singing = Singing(live: 6)
        singing.sing(Song.verse2b)
        singing.sing(Song.chorus1)
        #expect(singing.trail == [6, 7, 8], "chorus 7, not the first chorus at 3 or the last at 11")
    }

    @Test func chorusAgainJumpsBackToTheChorus() {
        var singing = Singing(Song.short, live: 5)
        singing.sing(Song.bridge2)
        #expect(singing.trail == [5], "the blank after the bridge is only suggested")
        #expect(singing.follower.suggestion?.slideIndex == 6)
        singing.sing("Steady You are")
        #expect(singing.trail == [5], "three words aren't enough to jump")
        singing.sing("steady\nAnchor when the waters rise")
        #expect(singing.trail.prefix(2) == [5, 2])
        #expect(singing.advances.first?.reason == .jump)
        singing.sing(Song.chorus2)
        #expect(singing.trail == [5, 2, 3, 4])
    }

    @Test func aRepeatedLastLineDoesntFlipBack() {
        var singing = Singing(live: 1)
        singing.sing(Song.verse1a)
        #expect(singing.trail == [1, 2])
        // The leader sings the tag again after the slide has moved on.
        singing.sing("every shadow running from the dawn")
        singing.sing("running from the dawn")
        #expect(singing.trail == [1, 2])
        singing.sing(Song.verse1b)
        #expect(singing.trail == [1, 2, 3])
    }

    @Test func singingTheSlideBeforeFromItsTopGoesBack() {
        var singing = Singing(live: 4)
        // The operator moved on too soon; the band is still on the first chorus slide.
        singing.sing("Steady You are steady")
        #expect(singing.trail == [4])
        singing.sing("Anchor when")
        #expect(singing.trail == [4, 3])
    }

    @Test func aRepeatedLineInsideASlideWaitsForTheSecond() {
        var singing = Singing(live: 10)
        singing.sing("Nothing in the dark can drown it out")
        #expect(singing.trail == [10], "the first time through is only halfway")
        singing.sing("Nothing in the dark can drown it out")
        #expect(singing.trail == [10, 11])
    }

    @Test func theOperatorsMoveDiscardsWhatCameBefore() {
        var follower = LyricFollower(slideTexts: Song.arranged, live: 1)
        follower.hear("morning light breaks over quiet", isFinal: false)
        follower.liveChanged(to: 3)
        follower.hear("morning light breaks over quiet hills every shadow", isFinal: false)
        #expect(follower.decision == nil)
        #expect(follower.suggestion == nil)
        follower.hear("morning light breaks over quiet hills every shadow steady you are steady", isFinal: true)
        #expect(follower.position?.slideIndex == 3)
    }

    @Test func belowTheThresholdItOnlySuggests() {
        var singing = Singing(live: 1)
        singing.threshold = 1.1
        singing.sing(Song.verse1a)
        #expect(singing.trail == [1])
        #expect(singing.follower.suggestion?.slideIndex == 2)
        #expect(singing.follower.suggestion?.reason == .currentSlideFinished)
        singing.sing("Lanterns fade as")
        #expect(singing.follower.suggestion?.slideIndex == 2)
        #expect(singing.follower.suggestion?.reason == .nextSlideStarted)
        // The operator takes it.
        singing.follower.liveChanged(to: 2)
        #expect(singing.follower.suggestion == nil)
    }

    @Test func aBlankLiveSlideWaitsForSinging() {
        var singing = Singing(Song.short, live: 6)
        singing.sing("oh oh")
        #expect(singing.trail == [6])
    }

    @Test func commonWordsAloneDontJump() {
        var follower = LyricFollower(slideTexts: Song.arranged, live: 5)
        follower.hear("you are the we will it out", isFinal: true)
        #expect(follower.decision == nil || follower.decision!.confidence < 0.7)
    }

    @Test func theSameWordsGiveTheSameDecisions() {
        func run() -> [Int] {
            var singing = Singing(live: 0)
            for slide in Song.arranged.dropFirst() where !slide.isEmpty { singing.sing(slide) }
            singing.sing("steady you are steady anchor")
            return singing.trail + singing.decisions.map { Int($0.confidence * 1000) }
        }
        #expect(run() == run())
    }

    @Test func wordsAreNormalised() {
        #expect(LyricFollower.words("You’re  STEADY—(x2)\nI'll rise (Repeat)") == ["youre", "steady", "ill", "rise"])
        #expect(LyricFollower.words("Café naïve") == ["cafe", "naive"])
        #expect(LyricFollower.likeness("there", "their") > 0.5)
        #expect(LyricFollower.likeness("waters", "water") > 0.5)
        #expect(LyricFollower.likeness("you", "the") == 0)
    }

    @Test func aLongSongStaysQuick() {
        // 16 slides of made-up words, sung twice through as long utterances.
        let syllables = ["ka", "lo", "mi", "ren", "tas", "vo", "bel", "dun", "sor", "fi", "gra", "nel", "pu", "zet"]
        func made(_ slide: Int, _ word: Int) -> String {
            let first: String = syllables[(slide * 5 + word) % 14]
            let second: String = syllables[(slide * 3 + word * 7 + 1) % 14]
            let third: String = syllables[(slide + word * 11 + 2) % 14]
            return first + second + third
        }
        let slides: [String] = (0 ..< 16).map { slide in
            (0 ..< 10).map { made(slide, $0) }.joined(separator: " ")
        }
        var singing = Singing(slides, live: 0)
        let start = Date()
        for _ in 0 ..< 2 {
            for slide in slides { singing.sing(slide, finals: false) }
            singing.settle()
        }
        #expect(Date().timeIntervalSince(start) < 20)
        #expect(singing.trail.prefix(16) == ArraySlice(Array(0 ..< 16)))
    }
}
