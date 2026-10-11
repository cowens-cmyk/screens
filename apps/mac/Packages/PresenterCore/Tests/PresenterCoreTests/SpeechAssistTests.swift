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
