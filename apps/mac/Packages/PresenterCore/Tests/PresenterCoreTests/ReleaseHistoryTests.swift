import Testing
@testable import PresenterCore

@Suite struct ReleaseHistoryTests {
    @Test func earlierReleasesAreOlderPublishedOnesNewestFirst() {
        let releases: [ReleaseHistory.Listing] = [
            .init(tag: "v0.44.1"),
            .init(tag: "v0.44.0"),
            .init(tag: "v0.9.0"),
            .init(tag: "v0.43.1"),
            .init(tag: "v0.43.2", draft: true),
            .init(tag: "v0.43.3", prerelease: true),
            .init(tag: "v0.42.0", hasDMG: false),
            .init(tag: "0.43.1"),
        ]
        let earlier = ReleaseHistory.earlier(releases, than: "0.44.1")
        #expect(earlier.map(\.version) == ["0.44.0", "0.43.1", "0.9.0"])
        #expect(ReleaseHistory.earlier(releases, than: "0.44.1", limit: 1).map(\.version) == ["0.44.0"])
        #expect(ReleaseHistory.earlier(releases, than: "0.9.0").isEmpty)
    }
}
