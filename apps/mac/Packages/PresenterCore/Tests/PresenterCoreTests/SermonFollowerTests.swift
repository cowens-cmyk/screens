import Foundation
import Testing
@testable import PresenterCore

struct SermonFollowerTests {

    private let deck = [
        "Joseph's Dreams Genesis 37",
        "God gives dreams that are bigger than our circumstances",
        "Genesis 37:5 Now Joseph had a dream, and when he told it to his brothers they hated him even more",
        "Jealousy blinds us to what God is doing",
        "The pit is not the end of the story",
        "", // a photo with nothing read off it
    ]

    @Test func readingTheNextPointPutsItUp() {
        var follower = SermonFollower(slideTexts: deck, live: 0)
        follower.hear("so here's the first thing I want you to see this morning")
        #expect(follower.decision == nil)
        follower.hear("God gives dreams that are bigger than our circumstances")
        #expect(follower.decision?.slideIndex == 1)
        #expect(follower.decision?.reason == "next")
    }

    @Test func talkingAroundThePointOnScreenStaysPut() {
        var follower = SermonFollower(slideTexts: deck, live: 1)
        follower.hear("think about that, bigger dreams than your circumstances, God gives dreams")
        #expect(follower.decision == nil)
    }

    @Test func aJumpNeedsMoreThanOnePhrase() {
        var follower = SermonFollower(slideTexts: deck, live: 1)
        follower.hear("the pit is not the end of the story")
        #expect(follower.decision == nil, "a jump of three waits for a second phrase")
        #expect(follower.suggestion?.slideIndex == 4)
        follower.hear("the pit is not the end of the story friends, the pit is not the end")
        #expect(follower.decision?.slideIndex == 4)
        #expect(follower.decision?.reason == "jump")
    }

    @Test func wordsOnEverySlideDontDecide() {
        let graphics = ["Joseph Series Week 1", "Joseph Series Forgiveness", "Joseph Series Week 3"]
        var follower = SermonFollower(slideTexts: graphics, live: 0)
        follower.hear("in this Joseph series we keep coming back to Joseph")
        #expect(follower.decision == nil)
        follower.hear("and that brings us to forgiveness, real forgiveness")
        // One word that sets it apart is a suggestion, not enough to put it up.
        #expect(follower.suggestion?.slideIndex == 1)
        #expect(follower.decision == nil)
        follower.hear("Joseph series forgiveness")
        #expect(follower.decision?.slideIndex == 1)
    }

    @Test func aSlideWithNoWordsIsNeverMatched() {
        var follower = SermonFollower(slideTexts: ["", ""], live: 0)
        follower.hear("anything at all")
        #expect(follower.suggestion == nil)
        #expect(follower.decision == nil)
    }

    @Test func movingTheSlideStartsListeningAfresh() {
        var follower = SermonFollower(slideTexts: deck, live: 0)
        follower.hear("God gives dreams that are bigger than our circumstances")
        #expect(follower.decision?.slideIndex == 1)
        follower.liveChanged(to: 1)
        #expect(follower.decision == nil)
        follower.hear("so")
        #expect(follower.decision == nil, "the words that led here are forgotten")
    }

    @Test func beforeAnySlideTheFirstIsNext() {
        var follower = SermonFollower(slideTexts: deck, live: nil)
        follower.hear("this morning we're in Joseph's dreams, Genesis 37")
        #expect(follower.decision?.slideIndex == 0)
    }

    @Test func stemsMeetTheirWords() {
        #expect(SermonFollower.words("Dreams dreaming DREAMED") == ["dream", "dream", "dream"])
        #expect(SermonFollower.words("the and of") == [])
    }
}
