import Foundation
import Testing
@testable import PresenterCore

@Test func detectsSpokenReferences() {
    #expect(SpokenReference.references(in: "This morning turn to Genesis 32").map(\.display) == ["Genesis 32"])
    #expect(SpokenReference.references(in: "open up to John chapter three verse sixteen").map(\.display) == ["John 3:16"])
    #expect(SpokenReference.references(in: "first Corinthians thirteen four through seven").map(\.display) == ["1 Corinthians 13:4–7"])
    #expect(SpokenReference.references(in: "Psalm one hundred nineteen verse one oh").first?.chapter == 119)
    #expect(SpokenReference.references(in: "we sang a great song today").isEmpty)
    #expect(SpokenReference.references(in: "first John one nine").map(\.display) == ["1 John 1:9"])
}

@Test func followerAdvancesWhenNextSlideIsSung() {
    var follower = LyricFollower(slideTexts: [
        "Amazing grace how sweet the sound\nThat saved a wretch like me",
        "I once was lost but now am found\nWas blind but now I see",
        "Twas grace that taught my heart to fear\nAnd grace my fears relieved",
    ])
    follower.hear("that saved a wretch like me")
    let finished = follower.decision(current: 0)
    #expect(finished?.slideIndex == 1)
    follower.reset()
    follower.hear("I once was lost but")
    #expect(follower.decision(current: 0)?.reason == .nextSlideStarted)
    follower.reset()
    follower.hear("amazing grace how sweet")
    #expect(follower.decision(current: 0) == nil, "still singing the current slide")
}

@Test func followerJumpsToRepeatedChorus() {
    var follower = LyricFollower(slideTexts: [
        "verse one words here about the mountains",
        "chorus line you are holy holy forever",
        "verse two words about the valley below",
        "bridge section we lift our hands up high",
    ])
    follower.hear("you are holy holy forever")
    let decision = follower.decision(current: 3)
    #expect(decision?.slideIndex == 1 && decision?.reason == .jump)
}

// Recognizers run spoken numbers together ("John three sixteen" → "John 316",
// "John one one" → "John 11"); every reading must be a real chapter and verse.
@Test func runTogetherNumbersSplitIntoChapterAndVerse() {
    func heard(_ text: String) -> [String] { SpokenReference.references(in: text).map(\.display) }
    #expect(heard("turn with me to John 316") == ["John 3:16"])
    #expect(heard("John three sixteen") == ["John 3:16"])
    #expect(heard("Romans 828 says") == ["Romans 8:28"])
    #expect(heard("Psalm 11910") == ["Psalms 119:10"])
    #expect(heard("Psalm 2316") == ["Psalms 23:16"])
    #expect(heard("John 22") == ["John 2:2"], "John has 21 chapters, so 22 can only be 2:2")
}

@Test func aNumberThatIsBothAChapterAndAVerseIsAmbiguous() {
    let detection = SpokenReference.detections(in: "look at John 11").first
    #expect(detection?.reference.display == "John 11")
    #expect(detection?.alternatives.map(\.display) == ["John 1:1"])
    #expect(SpokenReference.detections(in: "John 3").first?.ambiguous == false, "one digit can't be split")
}

@Test func colonsAndPeriodsFromTheRecognizerAreRead() {
    func heard(_ text: String) -> [SpokenDetection] { SpokenReference.detections(in: text) }
    #expect(heard("John 1:1").map(\.reference.display) == ["John 1:1"])
    #expect(heard("John 1:1").first?.ambiguous == false)
    #expect(heard("John 1: 1 says").map(\.reference.display) == ["John 1:1"])
    #expect(heard("John 3.16").map(\.reference.display) == ["John 3:16"])
    #expect(heard("John 3:16-18").map(\.reference.display) == ["John 3:16–18"])
    #expect(heard("John 3:16 through 18").map(\.reference.display) == ["John 3:16–18"])
}

@Test func impossibleReferencesAreNeverShown() {
    #expect(SpokenReference.references(in: "John 99:1").isEmpty)
    #expect(SpokenReference.references(in: "Jude 30").isEmpty, "Jude has 25 verses")
    #expect(SpokenReference.references(in: "Jude 5").map(\.display) == ["Jude 1:5"])
    #expect(SpokenReference.references(in: "John 3:0").isEmpty)
}

@Test func bookNamesThatAreEverydayWordsNeedANumber() {
    #expect(SpokenReference.references(in: "mark my words").isEmpty)
    #expect(SpokenReference.references(in: "in the book of acts we see").isEmpty)
    #expect(SpokenReference.references(in: "it is 5 o'clock").isEmpty, "\"is\" isn't Isaiah out loud")
    #expect(SpokenReference.references(in: "Mark 4").map(\.display) == ["Mark 4"])
    #expect(SpokenReference.references(in: "first John one nine").map(\.display) == ["1 John 1:9"])
}
