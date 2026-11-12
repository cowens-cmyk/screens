import Testing
@testable import DeckLinkKit

@Suite struct DisplayModeMatchTests {
    private func mode(
        _ name: String, _ width: Int = 1920, _ height: Int = 1080,
        duration: Int64, scale: Int64, progressive: Bool = true
    ) -> DeckLinkDisplayMode {
        DeckLinkDisplayMode(
            name: name, modeID: UInt32(name.hashValue & 0xFFFF) + 1,
            width: width, height: height,
            frameDuration: duration, timeScale: scale, progressive: progressive)
    }

    @Test func fractionalSiblingBeatsExactRate() {

        let modes = [
            mode("1080p29.97", duration: 1001, scale: 30000),
            mode("1080p30", duration: 1000, scale: 30000),
        ]
        for ordering in [modes, Array(modes.reversed())] {
            let match = DeckLinkDisplayMode.bestMatch(
                width: 1920, height: 1080, framesPerSecond: 30, in: ordering)
            #expect(match?.name == "1080p29.97")
        }
    }

    @Test func fractionalSiblingFillsInWhenExactIsAbsent() {
        let modes = [
            mode("1080p25", duration: 1000, scale: 25000),
            mode("1080p29.97", duration: 1001, scale: 30000),
        ]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match?.name == "1080p29.97")
    }

    @Test func progressiveBeatsInterlacedAtTheSameRate() {
        let modes = [
            mode("1080i29.97", duration: 1001, scale: 30000, progressive: false),
            mode("1080p29.97", duration: 1001, scale: 30000),
        ]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match?.name == "1080p29.97")
    }

    @Test func geometryMismatchYieldsNothing() {
        let modes = [mode("720p30", 1280, 720, duration: 1000, scale: 30000)]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match == nil)
    }

    @Test func distantRatesNeverMatch() {

        let modes = [mode("1080p25", duration: 1000, scale: 25000)]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match == nil)
    }

    @Test func aSixtyFrameScreenTakesTheSixtyModeWhenThePortHasOne() {
        let modes = [
            mode("1080p29.97", duration: 1001, scale: 30000),
            mode("1080p59.94", duration: 1001, scale: 60000),
        ]
        let match = DeckLinkDisplayMode.bestMatchAtOrBelow(
            width: 1920, height: 1080, framesPerSecond: 60, in: modes)
        #expect(match?.name == "1080p59.94")
    }

    @Test func aPortWithoutSixtySendsTheFastestRateItHas() {
        let modes = [
            mode("1080p25", duration: 1000, scale: 25000),
            mode("1080p29.97", duration: 1001, scale: 30000),
            mode("2160p59.94", 3840, 2160, duration: 1001, scale: 60000),
        ]
        let match = DeckLinkDisplayMode.bestMatchAtOrBelow(
            width: 1920, height: 1080, framesPerSecond: 60, in: modes)
        #expect(match?.name == "1080p29.97")
        #expect(DeckLinkDisplayMode.bestMatchAtOrBelow(
            width: 1280, height: 720, framesPerSecond: 60, in: modes) == nil)
    }

    @Test func theCardsInterlacedSettingDoesNotOverrideAProgressiveScreen() {
        // What an 8K Pro lists, with Desktop Video Setup left on 1080i59.94.
        let interlaced = mode("1080i59.94", duration: 1001, scale: 30000, progressive: false)
        let modes = [
            interlaced,
            mode("1080p29.97", duration: 1001, scale: 30000),
            mode("1080p59.94", duration: 1001, scale: 60000),
            mode("1080p60", duration: 1000, scale: 60000),
        ]
        let sixty = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 60, configured: interlaced.modeID, in: modes)
        #expect(sixty?.name == "1080p59.94")
        // A screen set to 30 goes out progressive too.
        let thirty = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 30, configured: interlaced.modeID, in: modes)
        #expect(thirty?.name == "1080p29.97")
    }

    @Test func theCardsSettingPicksBetweenModesThatFit() {
        let exact = mode("1080p60", duration: 1000, scale: 60000)
        let modes = [mode("1080p59.94", duration: 1001, scale: 60000), exact]
        let match = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 60, configured: exact.modeID, in: modes)
        #expect(match?.name == "1080p60")
    }

    @Test func theCardsSettingIsTheLastResort() {
        // A port with nothing at the screen's rate or under it, at its size.
        let only = mode("1080i59.94", duration: 1001, scale: 30000, progressive: false)
        let match = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 24, configured: only.modeID, in: [only])
        #expect(match?.name == "1080i59.94")
        #expect(DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 24, configured: nil, in: [only]) == nil)
    }

    @Test func withNothingAtTheScreensRateTheCardsSettingGoesOutAsBefore() {
        // Keying that 1080p59.94 can't do on this port: the modes left are
        // these, and the card is set to 1080i59.94, what the switcher takes.
        let interlaced = mode("1080i59.94", duration: 1001, scale: 30000, progressive: false)
        let modes = [interlaced, mode("1080p29.97", duration: 1001, scale: 30000)]
        let match = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 60, configured: interlaced.modeID, in: modes)
        #expect(match?.name == "1080i59.94")
        // With no setting to go by, the fastest rate under the screen's.
        let unset = DeckLinkDisplayMode.automatic(
            width: 1920, height: 1080, framesPerSecond: 60, configured: nil, in: modes)
        #expect(unset?.name == "1080p29.97")
    }
}
