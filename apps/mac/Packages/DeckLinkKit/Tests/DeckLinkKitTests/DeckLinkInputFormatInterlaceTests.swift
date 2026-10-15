import Testing

@testable import DeckLinkKit

private func format(_ dominance: UInt32) -> DeckLinkInputFormat {
    DeckLinkInputFormat(
        width: 1920, height: 1080, frameDuration: 1001, timeScale: 30000,
        fieldDominance: dominance, pixelFormat: 0)
}

@Test func bothFieldOrdersReportInterlaced() {
    #expect(format(DeckLinkInputFormat.lowerFirst).isInterlaced)
    #expect(format(DeckLinkInputFormat.upperFirst).isInterlaced)
}

@Test func progressiveSegmentedAndUnknownAreNotInterlaced() {
    #expect(!format(DeckLinkInputFormat.progressive).isInterlaced)
    #expect(!format(DeckLinkInputFormat.segmented).isInterlaced)
    #expect(!format(0).isInterlaced)
}
