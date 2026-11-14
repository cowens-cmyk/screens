import Testing
@testable import PresenterCore

/// Which DeckLink ports the background look asks for their modes.
struct DeckLinkModeAskingTests {
    @Test func aPortWithModesIsNotAskedAgain() {
        #expect(DeckLinkModeAsking.portsToAsk(present: [1, 2], seen: [1, 2], modeCounts: [1: 12, 2: 9], allModes: false) == [])
    }

    @Test func aNewOrReturningPortIsAsked() {
        #expect(DeckLinkModeAsking.portsToAsk(present: [1, 2], seen: [1], modeCounts: [1: 12, 2: 9], allModes: false) == [2])
    }

    @Test func aPortWhoseModesCameBackEmptyIsAskedOnEveryLook() {
        #expect(DeckLinkModeAsking.portsToAsk(present: [1, 2], seen: [1, 2], modeCounts: [1: 0, 2: 9], allModes: false) == [1])
        #expect(DeckLinkModeAsking.portsToAsk(present: [3], seen: [3], modeCounts: [:], allModes: false) == [3])
    }

    @Test func settingsAsksEveryPort() {
        #expect(DeckLinkModeAsking.portsToAsk(present: [1, 2], seen: [1, 2], modeCounts: [1: 12, 2: 9], allModes: true) == [1, 2])
    }

    @Test func anEmptyAnswerNeverWipesOutModes() {
        #expect(!DeckLinkModeAsking.keeps(answerCount: 0, knownCount: 12))
        #expect(DeckLinkModeAsking.keeps(answerCount: 0, knownCount: nil))
        #expect(DeckLinkModeAsking.keeps(answerCount: 0, knownCount: 0))
        #expect(DeckLinkModeAsking.keeps(answerCount: 10, knownCount: 12))
    }
}
