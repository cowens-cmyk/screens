import Foundation
import PresenterCore
import Testing
@testable import SlideScene

struct PlanSlideIndexTests {
    private func deck(_ id: String, slides count: Int) -> Presentation {
        Presentation(
            id: id, name: id, presentationKind: .deck, themeId: "",
            slides: (0 ..< count).map { Slide(id: "\(id)-\($0)", name: "\($0)", objects: []) })
    }

    /// The walk the old per-fire code built: every item's arranged slides in
    /// run order, and a slide's place found by searching it.
    private func naive(_ items: [PlanSlideIndex.Item]) -> [(String, Int, String)] {
        items.flatMap { item in
            SlideSceneBuilder.arrangedSlides(for: item.presentation, arrangementId: item.arrangementId)
                .enumerated().map { (item.itemID, $0.offset, $0.element.id) }
        }
    }

    @Test func walksThePlanAsTheOldCodeDidAndFindsEveryPlace() {
        let items = [
            PlanSlideIndex.Item(itemID: "song-1", arrangementId: nil, presentation: deck("a", slides: 6)),
            PlanSlideIndex.Item(itemID: "message", arrangementId: nil, presentation: deck("m", slides: 150)),
            PlanSlideIndex.Item(itemID: "song-2", arrangementId: nil, presentation: deck("b", slides: 8)),
        ]
        let index = PlanSlideIndex(items: items)
        let expected = naive(items)
        #expect(index.entries.map { "\($0.itemID)|\($0.occurrence)|\($0.slide.id)" }
            == expected.map { "\($0.0)|\($0.1)|\($0.2)" })
        for (position, entry) in expected.enumerated() {
            #expect(index.position(itemID: entry.0, occurrence: entry.1) == position)
        }
        #expect(index.count(itemID: "message") == 150)
        #expect(index.position(itemID: "message", occurrence: 150) == nil)
        #expect(index.position(itemID: "nowhere", occurrence: 0) == nil)
    }

    @Test func anItemListedTwiceFindsItsFirstRunAndCountsBoth() {
        let song = deck("s", slides: 3)
        let index = PlanSlideIndex(items: [
            PlanSlideIndex.Item(itemID: "x", arrangementId: nil, presentation: song),
            PlanSlideIndex.Item(itemID: "x", arrangementId: nil, presentation: song),
        ])
        #expect(index.position(itemID: "x", occurrence: 1) == 1)
        #expect(index.count(itemID: "x") == 6)
    }

    /// The lookup a fire makes is a dictionary read, whatever the plan's size.
    @Test func aLookupInAThousandSlidePlanIsCheap() {
        let items = (0 ..< 10).map {
            PlanSlideIndex.Item(itemID: "item-\($0)", arrangementId: nil, presentation: deck("d\($0)", slides: 100))
        }
        let index = PlanSlideIndex(items: items)
        let start = ContinuousClock.now
        for n in 0 ..< 10_000 {
            _ = index.position(itemID: "item-\(n % 10)", occurrence: n % 100)
        }
        #expect(start.duration(to: .now) < .milliseconds(200), "10,000 lookups")
    }
}
